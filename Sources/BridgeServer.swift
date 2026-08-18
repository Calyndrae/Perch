import Foundation

/// Listens on a Unix domain socket for connections from `BridgeHost`, the
/// native-messaging helper that Chrome launches on behalf of the extension.
///
/// A live connection is our proof the extension is installed *and* enabled:
/// Chrome only spawns the host when `chrome.runtime.connectNative` succeeds,
/// and the extension holds that port open for its whole lifetime. When the
/// last connection drops, the extension is gone.
final class BridgeServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private let queue = DispatchQueue(label: "com.trixarh.perch.bridge")

    private(set) var lastContact: Date?

    /// Called on the main queue whenever extension presence changes.
    var onPresenceChange: ((Bool) -> Void)?

    var isExtensionPresent: Bool {
        queue.sync { !clientSources.isEmpty }
    }

    func start() throws {
        try FileManager.default.createDirectory(
            at: Perch.supportDirectory, withIntermediateDirectories: true)

        let path = Perch.bridgeSocketPath
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BridgeError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw BridgeError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bound == 0 else { throw BridgeError.bindFailed(errno) }
        guard listen(listenFD, 8) == 0 else { throw BridgeError.listenFailed(errno) }

        chmod(path, 0o600)  // this user only

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source

        NSLog("[Perch] bridge listening at %@", path)
    }

    /// Must run on `queue`.
    private func acceptPending() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        let wasEmpty = clientSources.isEmpty
        lastContact = Date()

        // We read only to notice EOF; the payload is a hello we keep for logs.
        let client = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        client.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = read(fd, &buf, buf.count)
            if n <= 0 {
                self.dropClient(fd)
            } else {
                self.lastContact = Date()
            }
        }
        client.setCancelHandler { close(fd) }
        clientSources[fd] = client
        client.resume()

        if wasEmpty {
            DispatchQueue.main.async { self.onPresenceChange?(true) }
        }
    }

    /// Must run on `queue`.
    private func dropClient(_ fd: Int32) {
        guard let source = clientSources.removeValue(forKey: fd) else { return }
        source.cancel()  // cancel handler closes the fd
        if clientSources.isEmpty {
            DispatchQueue.main.async { self.onPresenceChange?(false) }
        }
    }

    func stop() {
        queue.sync {
            for (fd, _) in clientSources { clientSources[fd]?.cancel() }
            clientSources.removeAll()
        }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Perch.bridgeSocketPath)
    }

    enum BridgeError: LocalizedError {
        case socketFailed(Int32), bindFailed(Int32), listenFailed(Int32), pathTooLong

        var errorDescription: String? {
            switch self {
            case .socketFailed(let e):  return "Could not create bridge socket (errno \(e))"
            case .bindFailed(let e):    return "Could not bind bridge socket (errno \(e))"
            case .listenFailed(let e):  return "Could not listen on bridge socket (errno \(e))"
            case .pathTooLong:          return "Bridge socket path is too long"
            }
        }
    }
}
