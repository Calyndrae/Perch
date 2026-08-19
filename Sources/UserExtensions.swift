import AppKit

/// Extensions you add yourself, loaded into Perch's Chrome alongside its own.
///
/// Perch's Chrome runs on a separate profile, so anything installed in your
/// everyday Chrome is absent from it. Without this, adding an ad blocker or a
/// password manager to the browser Perch opens meant going through
/// chrome://extensions by hand every session, because a CDP-loaded extension
/// does not survive a restart.
///
/// Chrome's `Extensions.loadUnpacked` only takes a **directory**, so packaged
/// formats are unwrapped on the way in and kept unpacked.
enum UserExtensions {

    struct Item: Identifiable {
        let id: String            // folder name on disk
        let name: String
        let version: String
        let url: URL
        var enabled: Bool
    }

    static var storeDirectory: URL {
        Perch.supportDirectory.appendingPathComponent("UserExtensions", isDirectory: true)
    }

    private static let disabledKey = "PerchDisabledUserExtensions"

    private static var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: disabledKey) }
    }

    // MARK: - Reading

    static func installed() -> [Item] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: storeDirectory, includingPropertiesForKeys: nil) else { return [] }

        return entries.compactMap { folder -> Item? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
                  let manifest = readManifest(at: folder) else { return nil }
            let id = folder.lastPathComponent
            return Item(
                id: id,
                name: (manifest["name"] as? String) ?? id,
                version: (manifest["version"] as? String) ?? "?",
                url: folder,
                enabled: !disabledIDs.contains(id))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Directories to hand Chrome, newest-first order irrelevant.
    static var enabledPaths: [String] {
        installed().filter(\.enabled).map(\.url.path)
    }

    private static func readManifest(at folder: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(
                atPath: folder.appendingPathComponent("manifest.json").path)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Adding

    enum AddError: LocalizedError {
        case noManifest
        case unpackFailed(String)
        case alreadyInstalled(String)

        var errorDescription: String? {
            switch self {
            case .noManifest:
                return "That doesn't look like a Chrome extension — no manifest.json inside."
            case .unpackFailed(let why):
                return "Couldn't unpack it: \(why)"
            case .alreadyInstalled(let name):
                return "\(name) is already added."
            }
        }
    }

    /// Accepts an unpacked folder, a .zip, or a .crx.
    @discardableResult
    static func add(from source: URL) throws -> Item {
        let fm = FileManager.default
        try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let staging = fm.temporaryDirectory
            .appendingPathComponent("perch-ext-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)

        if isDir.boolValue {
            try copyContents(of: source, into: staging)
        } else {
            switch source.pathExtension.lowercased() {
            case "crx": try unpackCRX(source, into: staging)
            case "zip": try unzip(source, into: staging)
            default:    try unzip(source, into: staging)   // many .crx arrive renamed
            }
        }

        // A zip may hold the extension at its root or inside one wrapper folder.
        guard let root = locateManifestRoot(staging) else { throw AddError.noManifest }
        guard let manifest = readManifest(at: root) else { throw AddError.noManifest }

        let name = (manifest["name"] as? String) ?? source.deletingPathExtension().lastPathComponent
        let folderName = safeFolderName(name)
        let destination = storeDirectory.appendingPathComponent(folderName, isDirectory: true)

        if fm.fileExists(atPath: destination.path) { throw AddError.alreadyInstalled(name) }
        try fm.moveItem(at: root, to: destination)

        NSLog("%@", "[Perch] added user extension \(name) at \(destination.path)")
        return Item(id: folderName, name: name,
                    version: (manifest["version"] as? String) ?? "?",
                    url: destination, enabled: true)
    }

    static func setEnabled(_ item: Item, _ enabled: Bool) {
        var ids = disabledIDs
        if enabled { ids.remove(item.id) } else { ids.insert(item.id) }
        disabledIDs = ids
    }

    /// To the Trash, never deleted — the user may have no other copy of it.
    static func remove(_ item: Item) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        var ids = disabledIDs; ids.remove(item.id); disabledIDs = ids
    }

    // MARK: - Unpacking

    private static func copyContents(of source: URL, into destination: URL) throws {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
    }

    private static func unzip(_ archive: URL, into destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, destination.path]
        let err = Pipe(); task.standardError = err; task.standardOutput = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? "unknown"
            throw AddError.unpackFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// A .crx is a header followed by an ordinary zip. Rather than parse the
    /// header — which differs between CRX2 and CRX3 — find where the zip starts.
    private static func unpackCRX(_ crx: URL, into destination: URL) throws {
        guard let data = try? Data(contentsOf: crx) else {
            throw AddError.unpackFailed("could not read the file")
        }
        let signature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]   // "PK\03\04"
        guard let start = firstIndex(of: signature, in: data) else {
            throw AddError.unpackFailed("no zip data inside the .crx")
        }
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-crx-\(UUID().uuidString).zip")
        try data.subdata(in: start..<data.count).write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        try unzip(zip, into: destination)
    }

    private static func firstIndex(of pattern: [UInt8], in data: Data) -> Int? {
        guard data.count >= pattern.count else { return nil }
        let bytes = [UInt8](data)
        for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<i+pattern.count]) == pattern {
            return i
        }
        return nil
    }

    /// manifest.json may sit at the top, or one folder down if the zip wrapped it.
    private static func locateManifestRoot(_ base: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: base.appendingPathComponent("manifest.json").path) { return base }
        for entry in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: entry.appendingPathComponent("manifest.json").path) { return entry }
        }
        return nil
    }

    private static func safeFolderName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_")).inverted).joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "extension-\(UUID().uuidString.prefix(8))" : trimmed
    }
}
