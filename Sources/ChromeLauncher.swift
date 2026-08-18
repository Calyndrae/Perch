import AppKit
import Foundation

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
        let rc = posix_spawn(&pid, executable, &actions, nil, &cArgs, environ)
        close(toChrome[0]); close(fromChrome[1])

        guard rc == 0 else {
            close(toChrome[1]); close(fromChrome[0])
            throw LaunchError.spawnFailed(rc)
        }

        chromePID = pid
        writeFD = toChrome[1]
        readFD = fromChrome[0]
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

    private func receive(matching id: Int, timeout: TimeInterval = 20) async throws -> [String: Any]? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(readFD, &chunk, chunk.count)
            if n <= 0 {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            buffer.append(contentsOf: chunk[0..<n])

            // Drain every complete NUL-delimited message in the buffer.
            while let terminator = buffer.firstIndex(of: 0) {
                let messageData = buffer[buffer.startIndex..<terminator]
                buffer = buffer[buffer.index(after: terminator)...]
                if let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
                   obj["id"] as? Int == id {
                    return obj
                }
            }
        }
        return nil
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
