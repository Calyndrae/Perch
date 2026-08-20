import AppKit
import Foundation

/// Hands TCC responsibility to the spawned process instead of keeping it.
///
/// Looked up at runtime, deliberately. This is a private symbol, and binding it
/// with @_silgen_name makes it a hard link-time dependency: on any macOS where
/// it is absent or renamed, the process dies resolving it rather than carrying
/// on without it. A dlsym lookup degrades to nil instead, and the usage strings
/// in Info.plist cover the case where disclaiming is unavailable.
private typealias DisclaimFn =
    @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

private let spawnattrsSetDisclaim: DisclaimFn? = {
    // RTLD_DEFAULT — search every already-loaded image.
    let handle = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(handle, "responsibility_spawnattrs_setdisclaim") else {
        NSLog("%@", "[Perch] responsibility_spawnattrs_setdisclaim unavailable on this macOS; "
            + "relying on Info.plist usage strings instead")
        return nil
    }
    return unsafeBitCast(symbol, to: DisclaimFn.self)
}()

/// Launches Chrome with the extension already loaded, with no clicks from you.
///
/// Every other way of installing an extension from a native app is closed on
/// macOS, as of Chrome 151:
///
///   - external-extensions JSON with a local .crx — blocked since Chrome 44
///   - `--load-extension` — removed from branded Chrome in 137
///   - `ExtensionInstallForcelist` with a self-hosted update URL — refused
///     unless the machine is enterprise-managed ("policy can only install
///     extensions from the Chrome Web Store")
///
/// What remains is the Chromium-sanctioned replacement for `--load-extension`:
/// drive `Extensions.loadUnpacked` over the DevTools protocol.
///
/// We use `--remote-debugging-pipe` rather than `--remote-debugging-port`.
/// The port variant opens a localhost listener that *any* local process can
/// connect to and use to read your cookies and drive your browser. The pipe
/// variant talks over inherited file descriptors 3 and 4, so only this process
/// can ever speak to Chrome. Verified: no TCP listener is opened.
///
/// The cost of this route is that the extension lives only in Chrome sessions
/// we started — it does not survive a restart. `AppState` handles that by
/// offering to relaunch Chrome through Perch.
final class ChromeLauncher {
    private var chromePID: pid_t = 0
    /// When the managed Chrome started, so "it died after 2s" can be told apart
    /// from "it ran all afternoon and then quit".
    private var chromeStartedAt: Date?
    /// Set while Perch is closing Chrome on purpose, so a deliberate quit is
    /// never reported as a crash.
    private var expectingChromeExit = false
    /// One repair attempt per Perch session, never a loop.
    private var hasRetriedAfterRepair = false

    /// The last few things Perch asked Chrome to do, with timings.
    ///
    /// Chrome dying with EXC_BREAKPOINT means one of its own CHECKs failed, and
    /// the stack is stripped to a single `ChromeMain` symbol — so the report
    /// says a CHECK failed and nothing whatever about which one. That crash has
    /// not reproduced here across six attempts with Perch's exact flags, a
    /// reused profile, repeated loads and a third-party extension, so the
    /// remaining variable is the machine it happens on. Recording what Perch
    /// said last turns the next occurrence into evidence instead of another
    /// dead end.
    private var recentCalls: [(at: Date, method: String, detail: String)] = []
    private static let recentCallLimit = 25

    private func recordCall(_ method: String, _ params: [String: Any]) {
        // Only the fields that identify a call. Page content and script bodies
        // are deliberately left out — this ends up on a clipboard.
        var detail = ""
        if let path = params["path"] as? String {
            detail = (path as NSString).lastPathComponent
        } else if let target = params["targetId"] as? String {
            detail = String(target.prefix(8))
        }
        recentCalls.append((Date(), method, detail))
        if recentCalls.count > Self.recentCallLimit { recentCalls.removeFirst() }
        Self.appendToCDPLog(method, detail)
    }

    /// Written as it happens, not held in memory.
    ///
    /// When Chrome takes Perch's process down with it, or the user never opens
    /// Settings, an in-memory buffer is worth nothing. A file survives both and
    /// the debug script can read it.
    private static func appendToCDPLog(_ method: String, _ detail: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(method)\(detail.isEmpty ? "" : "  (\(detail))")\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = Perch.cdpLogPath
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Starts the log fresh for each Chrome, so it stays small and always
    /// describes the launch that is actually in question.
    private static func beginCDPLog(_ args: [String]) {
        let header = "=== Chrome launched \(ISO8601DateFormatter().string(from: Date())) ===\n"
                   + args.dropFirst().filter { $0.hasPrefix("--") }
                         .map { "  \($0.hasPrefix("--user-data-dir") ? "--user-data-dir=…" : $0)" }
                         .joined(separator: "\n") + "\n"
        try? header.data(using: .utf8)?.write(to: URL(fileURLWithPath: Perch.cdpLogPath))
    }

    /// What Perch last asked of Chrome, newest last.
    var recentCallLog: String {
        guard !recentCalls.isEmpty else { return "(nothing sent yet)" }
        let now = Date()
        return recentCalls.map { entry in
            let ago = now.timeIntervalSince(entry.at)
            return String(format: "  -%6.1fs  %@%@", ago, entry.method,
                          entry.detail.isEmpty ? "" : "  (\(entry.detail))")
        }.joined(separator: "\n")
    }
    private var writeFD: Int32 = -1
    private var readFD: Int32 = -1
    private var nextID = 0

    /// Persists across calls on purpose. A reply can arrive split over two
    /// reads, and once a page target is attached CDP streams events constantly
    /// — so a per-call buffer drops the tail of a message and desynchronises
    /// the stream, after which every subsequent request times out.
    private var readBuffer = Data()

    private(set) var loadedExtensionID: String?

    /// The freshest verified extension: the GitHub copy if we have one,
    /// otherwise the copy inside Perch.app.
    static var extensionPath: String? { ExtensionUpdater.currentExtensionPath }

    var isManagingChrome: Bool {
        chromePID != 0 && kill(chromePID, 0) == 0
    }

    // MARK: - Launch

    /// Starts Perch's own Chrome with the extension already loaded.
    ///
    /// Your everyday Chrome is left completely alone: because Perch uses a
    /// separate profile, the two run side by side and nothing needs quitting.
    ///
    /// `extraArguments` exists so tests can point at a throwaway profile.
    func relaunchChromeWithExtension(
        extraArguments: [String] = [],
        quitExisting: Bool = false
    ) async throws -> String {
        guard let extensionPath = Self.extensionPath,
              FileManager.default.fileExists(atPath: extensionPath + "/manifest.json") else {
            throw LaunchError.extensionMissingFromBundle
        }

        if quitExisting { try await quitChrome() }
        try spawnChrome(extraArguments: extraArguments)

        // Chrome needs to be up before it will answer CDP.
        do {
            try await waitForChrome()
        } catch let error as LaunchError {
            // Chrome died on the way up. Its disposable caches are the one part
            // of the profile that can be rebuilt for free, and a corrupt entry
            // there is survivable for an ordinary launch while being fatal for
            // ours — the log carried "Destroying invalid entry" immediately
            // before one of these deaths. So clear them and try once more.
            //
            // Once, and never for anything but a death at launch: a retry loop
            // against a browser that keeps dying is how Chrome got hammered
            // into the ground once already.
            guard case .chromeDiedAtLaunch = error, !hasRetriedAfterRepair else { throw error }
            hasRetriedAfterRepair = true
            let cleared = Self.clearDisposableCaches()
            NSLog("%@", "[Perch] Chrome died at launch; cleared \(cleared) and retrying once")
            try spawnChrome(extraArguments: extraArguments)
            do {
                try await waitForChrome()
            } catch {
                throw LaunchError.chromeDiedAtLaunch(
                    "Chrome quit at startup twice — once before clearing its caches "
                    + "(\(cleared)) and once after, so a corrupt cache isn't the cause.\n\n"
                    + Self.lastChromeLogTail()
                    + "\n\nWhat Perch had asked Chrome to do:\n" + recentCallLog)
            }
        }

        let id = try await loadUnpacked(path: extensionPath)
        loadedExtensionID = id
        NSLog("[Perch] loaded extension %@ into managed Chrome", id)

        // The user's own extensions go in afterwards. Perch's own is loaded
        // first and its failure is fatal, because nothing works without it;
        // these are each allowed to fail on their own, so one bad folder does
        // not cost you the browser.
        for path in UserExtensions.enabledPaths {
            do {
                let extra = try await loadUnpacked(path: path)
                NSLog("%@", "[Perch] loaded your extension \(extra) from \(path)")
            } catch {
                NSLog("%@", "[Perch] could not load \(path): \(error.localizedDescription)")
            }
        }
        return id
    }

    private func quitChrome() async throws {
        expectingChromeExit = true
        let running = WindowPicker.chromeInstances()
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }

        for _ in 0..<40 {                       // up to 10s
            if WindowPicker.chromeInstances().isEmpty { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LaunchError.chromeWouldNotQuit
    }

    private func spawnChrome(extraArguments: [String] = []) throws {
        var toChrome  = [Int32](repeating: 0, count: 2)   // we write, Chrome reads on fd 3
        var fromChrome = [Int32](repeating: 0, count: 2)  // Chrome writes on fd 4, we read
        guard pipe(&toChrome) == 0, pipe(&fromChrome) == 0 else {
            throw LaunchError.pipeFailed(errno)
        }

        // Move both pipe ends well clear of fds 3 and 4 before mapping anything
        // there. Two traps otherwise:
        //   - pipe() hands out low fds, so a plain close() of the ends we don't
        //     pass can close an fd a previous dup2 just installed.
        //   - dup2(fd, fd) is a no-op that does NOT clear FD_CLOEXEC, so an fd
        //     that already happens to be 3 or 4 would not survive exec.
        func relocate(_ fd: Int32) throws -> Int32 {
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 10)
            guard moved >= 0 else { throw LaunchError.pipeFailed(errno) }
            close(fd)
            return moved
        }

        let childRead = try relocate(toChrome[0])     // Chrome reads this as fd 3
        let childWrite = try relocate(fromChrome[1])  // Chrome writes this as fd 4
        toChrome[0] = childRead
        fromChrome[1] = childWrite

        // Our own ends must not leak into Chrome either.
        _ = fcntl(toChrome[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fromChrome[0], F_SETFD, FD_CLOEXEC)

        // Disclaim TCC responsibility for the child.
        //
        // posix_spawn otherwise makes US the "responsible process" for Chrome,
        // which means macOS checks PERCH's Info.plist when Chrome touches the
        // microphone, camera or a protected folder — finds no usage string, and
        // kills Chrome with EXC_CRASH (SIGABRT). Observed exactly that: Chrome
        // died the moment a page asked for the mic.
        //
        // Disclaiming makes Chrome answer for itself, so its own Info.plist and
        // its own permission prompts apply, as they would if you had opened
        // Chrome from the Dock.
        //
        // DISABLED. A bisect on macOS 15.6.1 cleared every flag Perch passes —
        // Chrome survived all of them from a shell — which left the spawn
        // itself, and disclaiming is the only part of it a shell cannot
        // reproduce. It is a private symbol with no guarantee of behaving the
        // same across releases, and the usage strings added to Info.plist cover
        // the TCC case through a supported route, so the private call buys
        // nothing that is worth a crash.
        //
        // Kept resolved rather than deleted so it can be switched back on for
        // testing if the crash turns out to be elsewhere.
        let useDisclaim = false

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        let disclaimed = useDisclaim ? (spawnattrsSetDisclaim?(&attrs, 1) ?? -1) : 0
        if disclaimed != 0 {
            // Not fatal any more: Perch stays TCC-responsible, and the usage
            // strings in its Info.plist are what stop macOS killing Chrome.
            NSLog("%@", "[Perch] could not disclaim TCC responsibility (\(disclaimed)); "
                + "falling back to Info.plist usage strings")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Chrome's pipe transport is hard-wired to fds 3 and 4. dup2 clears
        // FD_CLOEXEC on the target, so these two survive the exec.
        posix_spawn_file_actions_adddup2(&actions, childRead, 3)
        posix_spawn_file_actions_adddup2(&actions, childWrite, 4)

        let executable = Perch.chromeAppPath + "/Contents/MacOS/Google Chrome"
        // --user-data-dir is mandatory, not stylistic: Chrome 136+ ignores
        // --remote-debugging-pipe entirely on the default profile.
        var args = [
            executable,
            "--remote-debugging-pipe",
            "--no-first-run",
            "--no-default-browser-check",
            // Release Chrome swallows its own log output, including the FATAL
            // line a failed CHECK prints. Without this a crash leaves only an
            // unsymbolicated stack and nothing that names the cause.
            "--enable-logging=stderr",
            // Lets getDisplayMedia({preferCurrentTab:true}) resolve without the
            // picker. The extension rewrites every screen-share request to that
            // form, so a site is confined to its own tab and never gets the
            // chance to ask for a display.
            "--auto-accept-this-tab-capture",
        ]
        if !extraArguments.contains(where: { $0.hasPrefix("--user-data-dir") }) {
            args.append("--user-data-dir=\(Perch.chromeProfilePath)")
        }
        args += extraArguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        // Chrome's output goes to a file rather than /dev/null.
        //
        // It was discarded because Chrome's updater chatter buried Perch's own
        // logging — but when Chrome dies at launch, the reason it prints is the
        // only thing that explains why. A crash report shows SIGTRAP and an
        // unsymbolicated stack; the CHECK message that names the cause is on
        // stderr, and throwing it away made the failure undiagnosable.
        let logPath = Perch.chromeLogPath
        try? FileManager.default.createDirectory(
            at: Perch.supportDirectory, withIntermediateDirectories: true)
        // Truncate per launch so the file is about this run, not every run.
        posix_spawn_file_actions_addopen(&actions, 1, logPath,
                                         O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(&actions, 2, logPath,
                                         O_WRONLY | O_CREAT | O_APPEND, 0o644)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attrs, &cArgs, environ)
        close(toChrome[0]); close(fromChrome[1])

        guard rc == 0 else {
            close(toChrome[1]); close(fromChrome[0])
            throw LaunchError.spawnFailed(rc)
        }

        Self.beginCDPLog(args)
        chromePID = pid
        chromeStartedAt = Date()
        expectingChromeExit = false
        writeFD = toChrome[1]
        readFD = fromChrome[0]
        lastReloadAttempt = nil
        reloadAttempts = 0

        // Without O_NONBLOCK, read() parks the thread forever when Chrome has
        // nothing to say, so receive()'s deadline can never be evaluated and a
        // missed reply hangs instead of timing out.
        let flags = fcntl(readFD, F_GETFL, 0)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
    }

    /// Waits for the spawned process to be alive and its CDP pipe to answer,
    /// rather than polling the app list — which would be fooled by any other
    /// Chrome instance that happens to be running.
    private func waitForChrome() async throws {
        for _ in 0..<60 {                       // up to 15s
            // If Chrome has already exited, waiting the full 15s just turns a
            // crash into a confusing timeout. Say what actually happened, and
            // quote what Chrome printed on its way out.
            if chromePID != 0, kill(chromePID, 0) != 0, errno == ESRCH {
                throw LaunchError.chromeDiedAtLaunch(
                    Self.lastChromeLogTail()
                    + "\n\nWhat Perch had asked Chrome to do:\n" + recentCallLog)
            }
            guard chromePID != 0, kill(chromePID, 0) == 0 else {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            nextID += 1
            let probe = nextID
            if (try? send(["id": probe, "method": "Browser.getVersion"])) != nil,
               (try? await receive(matching: probe, timeout: 3)) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LaunchError.chromeDidNotStart
    }

    // MARK: - CDP over the pipe
    //
    // Framing is one JSON object per message, NUL-terminated.

    /// One CDP request, awaited to its matching reply.
    @discardableResult
    func call(_ method: String,
              _ params: [String: Any] = [:],
              sessionId: String? = nil) async throws -> [String: Any]? {
        nextID += 1
        let id = nextID
        var request: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { request["sessionId"] = sessionId }
        recordCall(method, params)
        try send(request)

        guard let reply = try await receive(matching: id) else {
            throw LaunchError.noResponse
        }
        if let error = reply["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw LaunchError.cdpError(message)
        }
        return reply
    }

    private func loadUnpacked(path: String) async throws -> String {
        let reply = try await call("Extensions.loadUnpacked", ["path": path])
        guard let result = reply?["result"] as? [String: Any],
              let extensionID = result["id"] as? String else {
            throw LaunchError.noResponse
        }
        return extensionID
    }

    private func send(_ object: [String: Any]) throws {
        guard writeFD >= 0 else { throw LaunchError.notConnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(writeFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw LaunchError.writeFailed(errno) }
                offset += n
            }
        }
    }

    private func receive(matching id: Int, timeout: TimeInterval = 15) async throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(readFD, &chunk, chunk.count)
            if n <= 0 {
                // EAGAIN just means "nothing yet" on a non-blocking fd.
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            readBuffer.append(contentsOf: chunk[0..<n])

            // Drain every complete NUL-delimited message in the buffer.
            while let terminator = readBuffer.firstIndex(of: 0) {
                let messageData = readBuffer[readBuffer.startIndex..<terminator]
                readBuffer = Data(readBuffer[readBuffer.index(after: terminator)...])
                if let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
                   obj["id"] as? Int == id {
                    return obj
                }
            }
        }
        return nil
    }

    // MARK: - Input forwarding
    //
    // CGEvent.postToPid does NOT reach Chrome — verified: a click posted to the
    // window's own pid is ignored even with Chrome frontmost, while the same
    // click via the global HID tap lands exactly. Chromium takes mouse input
    // from the window server's stream, not from per-process posted events.
    //
    // Since we already hold a CDP pipe to this Chrome, dispatching input over it
    // is better in every way: it needs no Accessibility permission, it never
    // pulls Chrome to the front, and it addresses the page directly so there is
    // no cursor to fight over. It reaches page content only, not the tab strip
    // or address bar — which is what the mirror is for anyway.

    private var pageSession: String?
    private var viewportOffset: CGPoint?
    private var viewportSize: CGSize?

    /// Attaches to the page that is actually showing in `windowFrame`, so
    /// clicks land in the tab you are looking at.
    ///
    /// Two steps, because neither alone is enough: `Browser.getWindowForTarget`
    /// identifies which Chrome window a tab belongs to, and `visibilityState`
    /// picks the active tab out of that window's several. The second step works
    /// precisely because Perch's extension no longer spoofs visibility.
    @discardableResult
    func attachToPage(showingIn windowFrame: CGRect) async throws -> Bool {
        let targets = try await call("Target.getTargets")
        let infos = ((targets?["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]]) ?? []
        let pages = infos.filter {
            ($0["type"] as? String) == "page"
            && !(($0["url"] as? String) ?? "").hasPrefix("devtools://")
        }

        var fallback: String?
        for page in pages {
            guard let id = page["targetId"] as? String else { continue }

            // Is this tab in the window we are mirroring?
            if !windowFrame.isEmpty {
                let win = try? await call("Browser.getWindowForTarget", ["targetId": id])
                if let bounds = ((win?["result"] as? [String: Any])?["bounds"] as? [String: Any]),
                   let left = bounds["left"] as? Double, let top = bounds["top"] as? Double {
                    let matches = abs(left - windowFrame.minX) < 8 && abs(top - windowFrame.minY) < 8
                    if !matches { continue }
                }
            }

            let attach = try await call("Target.attachToTarget", ["targetId": id, "flatten": true])
            guard let session = (attach?["result"] as? [String: Any])?["sessionId"] as? String
            else { continue }
            fallback = fallback ?? session

            let ev = try? await call("Runtime.evaluate",
                                     ["expression": "document.visibilityState",
                                      "returnByValue": true], sessionId: session)
            let state = ((ev?["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String
            if state == "visible" {
                pageSession = session
                try await refreshViewportGeometry()
                return true
            }
        }

        guard let session = fallback else { return false }
        pageSession = session
        try await refreshViewportGeometry()
        return true
    }

    /// The page viewport's position on screen, so mirror coordinates can be
    /// converted into the page-relative ones CDP expects.
    private func refreshViewportGeometry() async throws {
        guard let session = pageSession else { return }
        let js = """
        JSON.stringify({sx: window.screenX, sy: window.screenY,
                        iw: window.innerWidth, ih: window.innerHeight,
                        ow: window.outerWidth, oh: window.outerHeight})
        """
        let ev = try await call("Runtime.evaluate",
                                ["expression": js, "returnByValue": true], sessionId: session)
        guard let raw = ((ev?["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String,
              let data = raw.data(using: .utf8),
              let g = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return }

        // outer* stay in device-independent points; inner* are CSS pixels and
        // shrink as the page is zoomed in. Subtracting one from the other
        // directly would therefore read a zoomed page as having an enormous
        // tab strip. macOS Chrome draws no side borders, so the width pair
        // gives us the zoom factor for free, and at 100% this is arithmetically
        // identical to the plain subtraction it replaces.
        let ow = g["ow"] ?? 0, iw = g["iw"] ?? 0
        let oh = g["oh"] ?? 0, ih = g["ih"] ?? 0
        let zoom = (iw > 0 && ow > 0) ? ow / iw : 1
        let borders = (ow - iw * zoom) / 2                         // side chrome, usually 0
        let chromeHeight = max(0, oh - ih * zoom)                  // tab strip + omnibox
        viewportOffset = CGPoint(x: (g["sx"] ?? 0) + borders,
                                 y: (g["sy"] ?? 0) + chromeHeight)
        viewportSize = CGSize(width: iw * zoom, height: ih * zoom)
        NSLog("%@", "[Perch] viewport origin=\(viewportOffset!) size=\(viewportSize!) zoom=\(zoom)")
    }

    /// Where the page sits inside its window, as fractions of that window:
    /// everything that isn't tab strip, address bar or the "Sharing this tab"
    /// indicator.
    ///
    /// Fractions rather than screen coordinates, deliberately. Chrome's
    /// `window.screenX` and ScreenCaptureKit's `SCWindow.frame` do not always
    /// describe the same window in the same units — measured at 1081x878
    /// against 1200x975 for one window, a ~0.9 factor with an origin that
    /// transforms neither way. A fraction of the window is the same fraction
    /// whichever space you measure it in, so the caller applies it to the rect
    /// ScreenCaptureKit already gave it and nothing is ever converted.
    ///
    /// Re-read rather than cached: the sharing bar arrives the instant a site
    /// starts capturing and takes 56pt of page with it.
    func pageInsetFractions() async -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let session = pageSession else { return nil }
        let js = "JSON.stringify({iw: window.innerWidth, ih: window.innerHeight,"
               + " ow: window.outerWidth, oh: window.outerHeight})"
        let ev = try? await call("Runtime.evaluate",
                                 ["expression": js, "returnByValue": true], sessionId: session)
        guard let raw = ((ev?["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String,
              let data = raw.data(using: .utf8),
              let g = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let ow = g["ow"], let oh = g["oh"], let iw = g["iw"], let ih = g["ih"],
              ow > 0, oh > 0, iw > 0, ih > 0
        else { return nil }

        // outer* are device-independent points; inner* are CSS pixels and shrink
        // as the page is zoomed. Chrome draws no side borders on macOS, so the
        // width pair recovers the zoom factor and the height maths stays right
        // at any zoom. At 100% this reduces to (oh - ih) / oh.
        let zoom = ow / iw
        let pageW = min(ow, iw * zoom)
        let pageH = min(oh, ih * zoom)
        let top = max(0, oh - pageH)
        guard pageH / oh > 0.2 else { return nil }   // implausible; don't crop
        return (x: (ow - pageW) / 2 / ow, y: top / oh, w: pageW / ow, h: pageH / oh)
    }

    /// Converts a global screen point into page-viewport coordinates.
    /// Returns nil when the point is outside the page area (browser chrome).
    private func viewportPoint(for global: CGPoint) -> CGPoint? {
        guard let origin = viewportOffset, let size = viewportSize else { return nil }
        let p = CGPoint(x: global.x - origin.x, y: global.y - origin.y)
        guard p.x >= 0, p.y >= 0, p.x <= size.width, p.y <= size.height else { return nil }
        return p
    }

    func forwardClick(at global: CGPoint, clickCount: Int = 1) async {
        guard let session = pageSession, let p = viewportPoint(for: global) else { return }
        for type in ["mousePressed", "mouseReleased"] {
            do {
                // Doubles, not CGFloat: JSONSerialization is picky about types
                // it does not recognise as NSNumber.
                _ = try await call("Input.dispatchMouseEvent", [
                    "type": type,
                    "x": Double(p.x), "y": Double(p.y),
                    "button": "left",
                    "buttons": type == "mousePressed" ? 1 : 0,
                    "clickCount": clickCount,
                ], sessionId: session)
            } catch {
                NSLog("%@", "[Perch] click dispatch failed: \(error.localizedDescription)")
            }
        }
    }

    func forwardScroll(at global: CGPoint, deltaX: Double, deltaY: Double) async {
        guard let session = pageSession, let p = viewportPoint(for: global) else { return }
        do {
            _ = try await call("Input.dispatchMouseEvent", [
                "type": "mouseWheel",
                "x": Double(p.x), "y": Double(p.y),
                "deltaX": deltaX, "deltaY": deltaY,
            ], sessionId: session)
        } catch {
            NSLog("%@", "[Perch] scroll dispatch failed: \(error.localizedDescription)")
        }
    }

    /// Wakes the extension's service worker and tells it to reconnect.
    ///
    /// MV3 terminates an idle worker, which takes the native-messaging port —
    /// and the port was the only thing keeping the worker alive, so the two die
    /// together and nothing is left to restart either. chrome.alarms is the
    /// documented backstop but did not register reliably here, and a page load
    /// does not wake a worker when content scripts are declarative.
    ///
    /// Perch already holds the DevTools pipe, so it can simply reach in and
    /// restart the worker itself. Evaluating in a worker target is what revives
    /// it; calling connect() then re-establishes the port.
    /// Puts the extension back if it has been removed, and wakes it if it is
    /// merely asleep.
    ///
    /// Chrome will not let a non-enterprise machine force-install an off-store
    /// extension, so there is no "installed by your administrator" lock to be
    /// had. What there is: Perch holds the DevTools pipe, so it can notice the
    /// extension is gone and load it again. Removing it in chrome://extensions
    /// therefore lasts until Perch next looks, and never survives a restart.
    private var lastReloadAttempt: Date?
    private var reloadAttempts = 0

    @discardableResult
    func ensureExtensionLoaded() async -> Bool {
        // A worker that exists but is idle only needs waking.
        if await reviveExtension() { return true }

        // Absence of a worker does NOT mean the extension is gone: MV3 reclaims
        // idle workers constantly, so this is also true of one that is merely
        // asleep. Reloading on that signal alone re-ran loadUnpacked every few
        // seconds, which Chrome answered with "Duplicate script ID" and
        // eventually a SIGTRAP.
        //
        // So reloading is rate-limited and capped. If several attempts have not
        // restored the link, something else is wrong and hammering Chrome will
        // not fix it.
        let now = Date()
        if let last = lastReloadAttempt, now.timeIntervalSince(last) < 60 { return false }
        guard reloadAttempts < 3 else { return false }
        lastReloadAttempt = now
        reloadAttempts += 1

        guard let path = Self.extensionPath else { return false }
        do {
            let id = try await loadUnpacked(path: path)
            reloadAttempts = 0        // it worked; allow future recovery
            NSLog("%@", "[Perch] extension was missing; loaded it again (\(id))")
            for extra in UserExtensions.enabledPaths {
                _ = try? await loadUnpacked(path: extra)
            }
            return true
        } catch {
            NSLog("%@", "[Perch] could not reload the extension: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func reviveExtension() async -> Bool {
        guard let targets = try? await call("Target.getTargets"),
              let result = targets["result"] as? [String: Any],
              let infos = result["targetInfos"] as? [[String: Any]]
        else { return false }

        guard let worker = infos.first(where: {
            ($0["type"] as? String) == "service_worker"
            && (($0["url"] as? String) ?? "").contains(Perch.extensionID)
        }), let id = worker["targetId"] as? String else { return false }

        guard let attach = try? await call("Target.attachToTarget",
                                           ["targetId": id, "flatten": true]),
              let attachResult = attach["result"] as? [String: Any],
              let session = attachResult["sessionId"] as? String
        else { return false }

        _ = try? await call("Runtime.evaluate", [
            "expression": "try { if (!port) connect(); } catch (e) {} 1",
            "returnByValue": true,
        ], sessionId: session)
        return true
    }

    func shutdown() {
        expectingChromeExit = true
        if writeFD >= 0 { close(writeFD); writeFD = -1 }
        if readFD >= 0 { close(readFD); readFD = -1 }
        // Chrome is left running deliberately — quitting the user's browser
        // because Perch closed would be rude.
        chromePID = 0
    }

    /// Reports the managed Chrome having gone away, once, and says what for.
    ///
    /// Until now Chrome dying after a successful start was completely silent:
    /// the window list emptied, the gate flipped to "Perch hasn't started
    /// Chrome yet", and nothing anywhere said the browser had crashed — which
    /// is exactly the shape of the bug that has been open on the other Mac.
    /// Returns nil while Chrome is alive, and for a quit Perch asked for.
    func noticeUnexpectedChromeExit() -> String? {
        guard chromePID != 0 else { return nil }
        guard kill(chromePID, 0) != 0, errno == ESRCH else { return nil }

        let lifetime = chromeStartedAt.map { Date().timeIntervalSince($0) }
        chromePID = 0
        chromeStartedAt = nil
        guard !expectingChromeExit else { expectingChromeExit = false; return nil }

        var report = "The Chrome Perch started has quit"
        if let lifetime {
            report += lifetime < 60
                ? String(format: " after %.0f seconds", lifetime)
                : String(format: " after %.0f minutes", lifetime / 60)
        }
        report += ".\n\n"

        if let fatal = Self.fatalChromeLogLine() {
            report += "Chrome's own explanation:\n\(fatal)\n\n"
        } else if let crash = CrashReports.newestChromeCrash() {
            report += "A crash report was written:\n\(crash)\n\n"
        } else {
            report += "Nothing fatal was logged, so it may simply have been "
                    + "closed.\n\nLast output:\n\(Self.lastChromeLogTail())\n\n"
        }

        report += "What Perch last asked Chrome to do:\n\(recentCallLog)\n\n"
        report += "Press “Set Up Chrome Now” to start it again. "
                + "Settings → Diagnostics copies the full details."
        return report
    }

    /// Removes only what Chrome rebuilds by itself.
    ///
    /// Caches hold no logins, cookies, history or extensions — deliberately
    /// scoped that way, because Perch's profile is where the user actually
    /// signs in and losing that to a speculative repair would be far worse than
    /// the failure it was trying to fix.
    @discardableResult
    static func clearDisposableCaches() -> String {
        let profile = URL(fileURLWithPath: Perch.chromeProfilePath)
        let disposable = ["Default/Cache", "Default/Code Cache", "Default/GPUCache",
                          "Default/Service Worker/CacheStorage", "GrShaderCache",
                          "ShaderCache", "GPUCache"]
        var removed: [String] = []
        for relative in disposable {
            let url = profile.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(relative) }
        }
        return removed.isEmpty ? "no caches present" : removed.joined(separator: ", ")
    }

    /// The line where Chrome says it is giving up, if there is one. Chrome
    /// prints a great deal that looks alarming and means nothing, so this looks
    /// only for the markers that actually precede a termination.
    static func fatalChromeLogLine() -> String? {
        guard let text = try? String(contentsOfFile: Perch.chromeLogPath, encoding: .utf8)
        else { return nil }
        let markers = ["FATAL", "Check failed", "CHECK failed", "DCHECK",
                       "Aborted", "SIGTRAP", "SIGSEGV", "SIGABRT"]
        let hit = text.split(separator: "\n").last { line in
            markers.contains { line.contains($0) }
        }
        return hit.map(String.init)
    }

    /// The last few lines Chrome printed, for error messages and bug reports.
    static func lastChromeLogTail(_ lines: Int = 6) -> String {
        guard let text = try? String(contentsOfFile: Perch.chromeLogPath, encoding: .utf8)
        else { return "(nothing logged)" }
        let useful = text
            .split(separator: "\n")
            .filter { !$0.contains("GoogleUpdater") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return useful.suffix(lines).joined(separator: "\n")
    }

    enum LaunchError: LocalizedError {
        case chromeDiedAtLaunch(String)
        case extensionMissingFromBundle
        case chromeWouldNotQuit
        case chromeDidNotStart
        case pipeFailed(Int32)
        case spawnFailed(Int32)
        case writeFailed(Int32)
        case notConnected
        case noResponse
        case cdpError(String)

        var errorDescription: String? {
            switch self {
            case .chromeDiedAtLaunch(let tail):
                return "Chrome quit immediately after starting.\n\nWhat Chrome printed:\n\(tail)"
            case .extensionMissingFromBundle:
                return "Perch.app is missing its bundled extension. Rebuild with ./build.sh."
            case .chromeWouldNotQuit:
                return "Chrome didn’t quit. Close it yourself, then try again."
            case .chromeDidNotStart:
                return "Chrome started but never answered. If it opened on your "
                     + "normal profile, the debugging channel was refused — Perch "
                     + "must run Chrome on its own profile."
            case .pipeFailed(let e):  return "Could not open a pipe to Chrome (errno \(e))"
            case .spawnFailed(let e): return "Could not start Chrome (error \(e))"
            case .writeFailed(let e): return "Lost the connection to Chrome (errno \(e))"
            case .notConnected:       return "Not connected to Chrome."
            case .noResponse:         return "Chrome didn’t answer in time."
            case .cdpError(let m):    return "Chrome refused to load the extension: \(m)"
            }
        }
    }
}
