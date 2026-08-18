import CryptoKit
import Foundation

/// Keeps the Chrome extension current by fetching it from GitHub, so a fix can
/// ship without rebuilding the app.
///
/// Safety, because this downloads code that Chrome then runs on every page:
///
///   - HTTPS only; any other scheme is refused outright.
///   - The downloaded manifest's `key` is hashed and must derive exactly the
///     extension ID Perch was built against. A different key means a different
///     extension, and it is rejected rather than loaded. This is also what keeps
///     the native-messaging `allowed_origins` entry valid.
///   - Perch never executes any of it itself; it only hands Chrome a directory.
///   - The copy inside Perch.app is kept as a fallback, so a failed download,
///     an offline machine or a tampered payload degrades to the known-good
///     version instead of to nothing.
enum ExtensionUpdater {
    static let repository = "Calyndrae/Perch"
    static let branch = "main"

    static var archiveURL: URL {
        URL(string: "https://codeload.github.com/\(repository)/tar.gz/refs/heads/\(branch)")!
    }

    /// Where the downloaded copy lives once verified.
    static var cachedExtensionPath: URL {
        Perch.supportDirectory.appendingPathComponent("Extension", isDirectory: true)
    }

    /// The directory Chrome should load: the freshest verified copy available.
    static var currentExtensionPath: String? {
        let cached = cachedExtensionPath.appendingPathComponent("manifest.json").path
        if FileManager.default.fileExists(atPath: cached) {
            return cachedExtensionPath.path
        }
        return bundledExtensionPath
    }

    static var bundledExtensionPath: String? {
        guard let url = Bundle.main.resourceURL?
                .appendingPathComponent("Extension", isDirectory: true),
              FileManager.default.fileExists(
                atPath: url.appendingPathComponent("manifest.json").path)
        else { return nil }
        return url.path
    }

    static func installedVersion() -> String? {
        guard let path = currentExtensionPath,
              let data = FileManager.default.contents(
                atPath: path + "/manifest.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["version"] as? String
    }

    // MARK: - Update

    @discardableResult
    static func updateFromGitHub() async -> UpdateResult {
        guard archiveURL.scheme == "https" else { return .failed("Refusing a non-HTTPS source") }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            var request = URLRequest(url: archiveURL)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failed("GitHub returned HTTP \(code)")
            }

            let tarball = work.appendingPathComponent("source.tar.gz")
            try data.write(to: tarball)

            // GitHub wraps everything in one top-level directory, so strip it.
            let extracted = work.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try runTar(archive: tarball, into: extracted)

            let downloaded = extracted.appendingPathComponent("Extension", isDirectory: true)
            guard FileManager.default.fileExists(
                    atPath: downloaded.appendingPathComponent("manifest.json").path) else {
                return .failed("The download had no Extension/ directory")
            }

            // Integrity: this must be OUR extension, not merely an extension.
            guard let key = manifestKey(at: downloaded) else {
                return .failed("Downloaded manifest has no pinned key")
            }
            let derivedID = extensionID(fromBase64PublicKey: key)
            guard derivedID == Perch.extensionID else {
                return .rejected(
                    "Downloaded extension identifies as \(derivedID ?? "unknown"), "
                  + "not \(Perch.extensionID). Keeping the built-in copy.")
            }

            let newVersion = version(at: downloaded)
            if let current = installedVersion(), current == newVersion {
                return .alreadyCurrent(current)
            }

            // Atomic-ish swap so a crash mid-copy can't leave a half extension.
            let staging = Perch.supportDirectory
                .appendingPathComponent("Extension.new", idempotent: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(
                at: Perch.supportDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: downloaded, to: staging)

            try? FileManager.default.removeItem(at: cachedExtensionPath)
            try FileManager.default.moveItem(at: staging, to: cachedExtensionPath)

            NSLog("[Perch] extension updated from GitHub to %@", newVersion ?? "?")
            return .updated(newVersion ?? "?")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func runTar(archive: URL, into directory: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // --strip-components=1 drops GitHub's "Perch-main/" wrapper.
        task.arguments = ["-xzf", archive.path, "-C", directory.path, "--strip-components=1"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "Perch", code: Int(task.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Could not unpack the download",
            ])
        }
    }

    private static func manifestKey(at directory: URL) -> String? {
        guard let data = FileManager.default.contents(
                atPath: directory.appendingPathComponent("manifest.json").path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["key"] as? String
    }

    private static func version(at directory: URL) -> String? {
        guard let data = FileManager.default.contents(
                atPath: directory.appendingPathComponent("manifest.json").path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["version"] as? String
    }

    /// Chrome derives an extension's ID from the SHA-256 of its public key:
    /// the first 16 bytes, hex-encoded, with 0-9a-f mapped onto a-p.
    static func extensionID(fromBase64PublicKey key: String) -> String? {
        guard let der = Data(base64Encoded: key) else { return nil }
        let digest = SHA256.hash(data: der)
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let scalars = hex.unicodeScalars.map { scalar -> Character in
            let value = Character(scalar).hexDigitValue ?? 0
            return Character(UnicodeScalar(UInt8(97 + value)))
        }
        return String(scalars)
    }

    enum UpdateResult {
        case updated(String)
        case alreadyCurrent(String)
        case rejected(String)
        case failed(String)

        var isUsable: Bool {
            switch self {
            case .updated, .alreadyCurrent: return true
            case .rejected, .failed:        return false
            }
        }

        var describedForUser: String {
            switch self {
            case .updated(let v):        return "Updated the extension to \(v)."
            case .alreadyCurrent(let v): return "Extension is up to date (\(v))."
            case .rejected(let why):     return why
            case .failed(let why):       return "Couldn't check GitHub: \(why)"
            }
        }
    }
}

private extension URL {
    /// Small readability helper so the staging path reads clearly above.
    func appendingPathComponent(_ name: String, idempotent: Bool) -> URL {
        appendingPathComponent(name, isDirectory: true)
    }
}
