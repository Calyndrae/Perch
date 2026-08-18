import AppKit
import Foundation

/// Hands TCC responsibility to the spawned process instead of keeping it.
///
/// Not public API, but it is the documented-by-practice mechanism every
/// terminal emulator and launcher uses, and it is stable across macOS releases.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(
    _ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

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
        try await waitForChrome()

        let id = try await loadUnpacked(path: extensionPath)
        loadedExtensionID = id
        NSLog("[Perch] loaded extension %@ into managed Chrome", id)
        return id
    }

    private func quitChrome() async throws {
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
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        let disclaimed = responsibility_spawnattrs_setdisclaim(&attrs, 1)
        if disclaimed != 0 {
            NSLog("%@", "[Perch] could not disclaim TCC responsibility (\(disclaimed)); "
                + "Chrome may be killed when it asks for the microphone or camera")
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
        ]
        if !extraArguments.contains(where: { $0.hasPrefix("--user-data-dir") }) {
            args.append("--user-data-dir=\(Perch.chromeProfilePath)")
        }
        args += extraArguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        // Chrome is extremely chatty on stderr and would otherwise bury
        // Perch's own logging in its updater output.
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attrs, &cArgs, environ)
        close(toChrome[0]); close(fromChrome[1])

        guard rc == 0 else {
            close(toChrome[1]); close(fromChrome[0])
            throw LaunchError.spawnFailed(rc)
        }

        chromePID = pid
        writeFD = toChrome[1]
        readFD = fromChrome[0]

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

        let borders = ((g["ow"] ?? 0) - (g["iw"] ?? 0)) / 2       // side chrome, usually 0
        let chromeHeight = (g["oh"] ?? 0) - (g["ih"] ?? 0)         // tab strip + omnibox
        viewportOffset = CGPoint(x: (g["sx"] ?? 0) + borders,
                                 y: (g["sy"] ?? 0) + chromeHeight)
        viewportSize = CGSize(width: g["iw"] ?? 0, height: g["ih"] ?? 0)
        NSLog("%@", "[Perch] viewport origin=\(viewportOffset!) size=\(viewportSize!)")
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

    func shutdown() {
        if writeFD >= 0 { close(writeFD); writeFD = -1 }
        if readFD >= 0 { close(readFD); readFD = -1 }
        // Chrome is left running deliberately — quitting the user's browser
        // because Perch closed would be rude.
        chromePID = 0
    }

    enum LaunchError: LocalizedError {
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
