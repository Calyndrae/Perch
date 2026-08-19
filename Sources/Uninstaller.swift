import AppKit

/// Removes everything Perch put on the machine.
///
/// Two rules shape this.
///
/// Everything goes to the **Trash**, never `removeItem`. An uninstaller is
/// exactly the wrong place to be irreversible: one mistaken click should be
/// recoverable, and the Trash is the recovery path macOS users already know.
///
/// The Chrome profile is **opt-in and off by default**. It is the only item
/// here that holds anything of the user's own — signed-in sessions, history,
/// cookies — and it dwarfs everything else on disk. Removing the app should
/// never quietly take a browser profile with it.
enum Uninstaller {

    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let url: URL
        let bytes: Int64
        var isProfile = false

        var readableSize: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    // MARK: - What is on disk

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Every native-messaging manifest we may have written, across each browser
    /// that was present at the time plus Perch's own profile.
    private static var manifestURLs: [URL] {
        var dirs: [URL] = [URL(fileURLWithPath: Perch.chromeProfilePath)]
        for browser in ["Google/Chrome", "Chromium", "Google/Chrome Beta", "Google/Chrome Canary"] {
            dirs.append(support.appendingPathComponent(browser, isDirectory: true))
        }
        return dirs.map {
            $0.appendingPathComponent("NativeMessagingHosts/\(Perch.nativeHostName).json")
        }
    }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                 options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// What removal would touch, with sizes, so the choice is informed.
    static func inventory() -> [Item] {
        let fm = FileManager.default
        var items: [Item] = []

        func add(_ label: String, _ url: URL, isProfile: Bool = false) {
            guard fm.fileExists(atPath: url.path) else { return }
            items.append(Item(label: label, url: url, bytes: size(of: url), isProfile: isProfile))
        }

        add("Perch.app", Bundle.main.bundleURL)
        add("Downloaded extension", ExtensionUpdater.cachedExtensionPath)
        add("Settings", URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Preferences/\(Perch.bundleID).plist"))
        for m in manifestURLs { add("Chrome connector", m) }
        add("Perch's Chrome profile — logins, history, cookies",
            URL(fileURLWithPath: Perch.chromeProfilePath), isProfile: true)
        return items
    }

    // MARK: - Removal

    enum Outcome {
        case done(trashed: Int, failed: [String])
        case chromeStillRunning
    }

    /// Moves each item to the Trash. Nothing is erased.
    ///
    /// Perch's Chrome has to be closed first: trashing a profile that Chrome
    /// still has open leaves it half-written and can corrupt what the user
    /// would otherwise be able to restore.
    static func uninstall(includeChromeProfile: Bool,
                          completion: @escaping (Outcome) -> Void) {
        let managed = WindowPicker.chromeInstances()
        if includeChromeProfile && !managed.isEmpty {
            managed.forEach { $0.terminate() }
            // Give it a moment, then check rather than assume.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if WindowPicker.chromeInstances().isEmpty {
                    perform(includeChromeProfile: includeChromeProfile, completion: completion)
                } else {
                    completion(.chromeStillRunning)
                }
            }
            return
        }
        perform(includeChromeProfile: includeChromeProfile, completion: completion)
    }

    private static func perform(includeChromeProfile: Bool,
                                completion: @escaping (Outcome) -> Void) {
        let fm = FileManager.default
        var trashed = 0
        var failed: [String] = []

        for item in inventory() where includeChromeProfile || !item.isProfile {
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                trashed += 1
            } catch {
                failed.append("\(item.label): \(error.localizedDescription)")
            }
        }

        // The support folder is only worth removing once nothing is left in it.
        let perchSupport = Perch.supportDirectory
        if let rest = try? fm.contentsOfDirectory(atPath: perchSupport.path), rest.isEmpty {
            try? fm.trashItem(at: perchSupport, resultingItemURL: nil)
        }

        UserDefaults.standard.removePersistentDomain(forName: Perch.bundleID)
        UserDefaults.standard.synchronize()

        NSLog("%@", "[Perch] uninstall: \(trashed) item(s) to Trash, \(failed.count) failed")
        completion(.done(trashed: trashed, failed: failed))
    }

    /// macOS keeps the Screen Recording grant in its own database, which no app
    /// may edit. Removing it is a manual step, so say so rather than pretend.
    static func openScreenRecordingSettings() {
        PermissionPrompter.openScreenRecordingSettings()
    }

    static func revealTrash() {
        NSWorkspace.shared.open(
            FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0])
    }
}
