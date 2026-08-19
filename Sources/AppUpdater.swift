import AppKit

/// Keeps Perch itself current from GitHub Releases.
///
/// The extension has always refreshed itself on launch; the app did not, so a
/// fix meant noticing a release existed and reinstalling by hand.
///
/// This downloads and then *runs* code, so the replacement is only installed if
/// it is signed by the same certificate as the copy already running. That check
/// is the whole safety story: a tampered or substituted DMG fails it and is
/// discarded, and the running app is left untouched.
enum AppUpdater {

    static let repository = "Calyndrae/Perch"

    enum Result {
        case upToDate(String)
        case installed(String)
        case available(String)          // found, but not installed automatically
        case failed(String)
        case rejected(String)           // signature did not match

        var describedForUser: String {
            switch self {
            case .upToDate(let v):  return "Perch \(v) is the latest version."
            case .installed(let v): return "Updated to \(v). Relaunch to use it."
            case .available(let v): return "Perch \(v) is available."
            case .failed(let why):  return "Couldn't check for updates: \(why)"
            case .rejected(let why): return "Update refused: \(why)"
            }
        }
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Numeric compare, so 0.10.0 is correctly newer than 0.9.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                .split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Check and install

    static func checkAndInstall(automatically install: Bool = true) async -> Result {
        do {
            guard let (version, assetURL) = try await latestRelease() else {
                return .failed("no release found")
            }
            guard isNewer(version, than: currentVersion) else { return .upToDate(currentVersion) }
            guard install else { return .available(version) }

            let dmg = try await download(assetURL)
            defer { try? FileManager.default.removeItem(at: dmg) }

            let mount = try attach(dmg)
            defer { detach(mount) }

            let candidate = mount.appendingPathComponent("Perch.app")
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                return .failed("the disk image had no Perch.app in it")
            }
            // Same certificate as the running copy, or it does not get installed.
            guard signatureMatchesRunningApp(candidate) else {
                return .rejected("the download is not signed by the same certificate "
                               + "as the copy you are running")
            }

            try replaceRunningApp(with: candidate)
            NSLog("%@", "[Perch] updated to \(version)")
            return .installed(version)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func latestRelease() async throws -> (String, URL)? {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let dmg = assets.first {
            (($0["name"] as? String) ?? "").hasSuffix(".dmg")
        }
        guard let urlString = dmg?["browser_download_url"] as? String,
              let url = URL(string: urlString), url.scheme == "https" else { return nil }
        return (tag, url)
    }

    private static func download(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-update-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private static func attach(_ dmg: URL) throws -> URL {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["attach", dmg.path, "-nobrowse", "-readonly", "-mountrandom", "/tmp"]
        let out = Pipe(); task.standardOutput = out; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").last(where: { $0.contains("/tmp/") }),
              let range = line.range(of: "/tmp/") else { throw Failure.mount }
        return URL(fileURLWithPath: String(line[range.lowerBound...])
            .trimmingCharacters(in: .whitespaces))
    }

    private static func detach(_ mount: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["detach", mount.path, "-quiet"]
        try? task.run(); task.waitUntilExit()
    }

    /// The downloaded app must satisfy the running app's designated requirement.
    private static func signatureMatchesRunningApp(_ candidate: URL) -> Bool {
        guard let requirement = designatedRequirement(of: Bundle.main.bundleURL),
              !requirement.isEmpty else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "-R=\(requirement)", candidate.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run(); task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func designatedRequirement(of app: URL) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-r", "-", app.path]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        try? task.run()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        task.waitUntilExit()
        guard let line = text.split(separator: "\n").first(where: { $0.contains("designated =>") })
        else { return nil }
        return line.replacingOccurrences(of: "designated => ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Swaps the bundle on disk. The running image stays mapped, so the current
    /// session keeps working until it is relaunched.
    private static func replaceRunningApp(with candidate: URL) throws {
        let fm = FileManager.default
        let destination = Bundle.main.bundleURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("Perch-update.app")

        try? fm.removeItem(at: staging)
        try fm.copyItem(at: candidate, to: staging)
        // Trash rather than delete, so a bad update is recoverable.
        try? fm.trashItem(at: destination, resultingItemURL: nil)
        try fm.moveItem(at: staging, to: destination)
    }

    enum Failure: LocalizedError {
        case http(Int), mount
        var errorDescription: String? {
            switch self {
            case .http(let c): return "GitHub returned HTTP \(c)"
            case .mount:       return "could not open the downloaded disk image"
            }
        }
    }
}
