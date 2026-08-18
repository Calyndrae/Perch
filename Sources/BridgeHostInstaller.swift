import Foundation

/// Registers PerchBridge as a Chrome native-messaging host.
///
/// Done in-app on every launch rather than by a shell script, so that moving
/// Perch.app to a new folder fixes itself instead of silently breaking the
/// handshake — the manifest has to carry an absolute path to the binary.
enum BridgeHostInstaller {
    static func installIfNeeded() {
        guard let hostBinary = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("PerchBridge").path,
              FileManager.default.isExecutableFile(atPath: hostBinary) else {
            NSLog("[Perch] PerchBridge missing from bundle; handshake will fail")
            return
        }

        let manifest: [String: Any] = [
            "name": Perch.nativeHostName,
            "description": "Perch bridge — lets the Perch app and its extension find each other",
            "path": hostBinary,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Perch.extensionID)/"],
        ]

        guard let data = try? JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted]) else { return }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]

        // Chrome resolves user-level native-messaging manifests relative to the
        // *user data directory*, not to a fixed system path. Perch runs Chrome
        // on its own profile, so that profile needs its own copy — installing
        // only into the default location leaves connectNative failing with the
        // extension loaded and no clue why.
        var targets: [URL] = [URL(fileURLWithPath: Perch.chromeProfilePath)]
        for browser in ["Google/Chrome", "Chromium", "Google/Chrome Beta", "Google/Chrome Canary"] {
            let base = support.appendingPathComponent(browser, isDirectory: true)
            // Only register for browsers actually installed, so we don't litter.
            if FileManager.default.fileExists(atPath: base.path) { targets.append(base) }
        }

        for base in targets {
            let dir = base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = dir.appendingPathComponent("\(Perch.nativeHostName).json")

            // Skip the write when it is already correct — this runs every launch.
            if let existing = try? Data(contentsOf: file), existing == data { continue }

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try data.write(to: file, options: .atomic)
                NSLog("[Perch] registered native host at %@", file.path)
            } catch {
                NSLog("[Perch] could not register native host: %@", error.localizedDescription)
            }
        }
    }
}
