import Foundation

/// Chrome native-messaging host.
///
/// Chrome launches this process when the extension calls
/// `chrome.runtime.connectNative`. It does two jobs:
///
///   1. Tells the extension whether Perch.app is actually running, so the
///      extension can make itself inert when the app is absent.
///   2. Holds a Unix-socket connection open to Perch for as long as Chrome keeps
///      this process alive, which is how Perch knows the extension exists.
///
/// Native messaging framing: a 4-byte little-endian length, then that many
/// bytes of UTF-8 JSON, on stdin and stdout.
@main
struct BridgeHost {
    static func main() {
        let socketFD = connectToPerch()
        let appRunning = socketFD >= 0

        if appRunning {
            let hello = #"{"from":"bridge","event":"extension-connected"}"#
            _ = hello.withCString { write(socketFD, $0, strlen($0)) }
        }

        send(["ok": true, "appRunning": appRunning, "host": "perch-bridge", "version": 1])

        // Pump Chrome's messages until it closes the port. Every message gets a
        // fresh liveness answer, and the read loop is what keeps this process —
        // and therefore Perch's view of the extension — alive.
        while let message = receive() {
            let type = message["type"] as? String ?? "ping"
            if type == "tabswitch" {
                relay(["from": "bridge", "event": "tabswitch"], to: socketFD)
                send(["ok": true, "echo": type])
            } else if type == "ping" || type == "status" {
                let alive = appRunning && isSocketAlive(socketFD)
                var reply: [String: Any] = ["ok": true, "appRunning": alive, "echo": type,
                                            "autoFullscreen": autoFullscreenOnShare()]
                // Perch cannot raise a notification itself: macOS refuses
                // UNUserNotificationCenter to a locally signed, non-notarized
                // build. Chrome is notarized and its notifications land, so the
                // news travels out this way instead.
                if let pending = perchDefault("PerchPendingUpdateVersion") as? String {
                    reply["updateInstalled"] = pending
                }
                send(reply)
            } else {
                send(["ok": false, "error": "unknown message type: \(type)"])
            }
        }

        if socketFD >= 0 { close(socketFD) }
    }

    /// Read straight from Perch's own preferences rather than over the socket.
    ///
    /// The socket only carries extension -> app, and this process spends its
    /// life blocked reading Chrome's stdin, so there is no moment at which it
    /// could receive a pushed setting. Reading the plist on demand means a
    /// change in Settings reaches the extension the next time it asks, which is
    /// immediately before it would act on it.
    private static func autoFullscreenOnShare() -> Bool {
        (perchDefault("PerchAutoFullscreenOnShare") as? Bool) ?? true   // shipped default
    }

    private static func perchDefault(_ key: String) -> Any? {
        UserDefaults(suiteName: "com.trixarh.perch")?.object(forKey: key)
    }

    private static func relay(_ object: [String: Any], to fd: Int32) {
        guard fd >= 0,
              let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    // MARK: - Perch socket

    private static func connectToPerch() -> Int32 {
        let path = perchSocketPath()
        guard FileManager.default.fileExists(atPath: path) else { return -1 }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }

    private static func isSocketAlive(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var error: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0 else { return false }
        return error == 0
    }

    private static func perchSocketPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Perch/bridge.sock").path
    }

    // MARK: - Native messaging framing

    private static func receive() -> [String: Any]? {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        guard readExactly(&lengthBytes, 4) else { return nil }

        let length = UInt32(lengthBytes[0])
            | UInt32(lengthBytes[1]) << 8
            | UInt32(lengthBytes[2]) << 16
            | UInt32(lengthBytes[3]) << 24
        guard length > 0, length < 1_048_576 else { return nil }

        var payload = [UInt8](repeating: 0, count: Int(length))
        guard readExactly(&payload, Int(length)) else { return nil }

        return (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any]
    }

    private static func readExactly(_ buffer: inout [UInt8], _ count: Int) -> Bool {
        var read_ = 0
        while read_ < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(STDIN_FILENO, raw.baseAddress!.advanced(by: read_), count - read_)
            }
            if n <= 0 { return false }
            read_ += n
        }
        return true
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &length) { _ = write(STDOUT_FILENO, $0.baseAddress!, 4) }
        data.withUnsafeBytes { _ = write(STDOUT_FILENO, $0.baseAddress!, data.count) }
    }
}
