import Foundation

/// Reads macOS crash reports for Chrome.
///
/// The one artefact that actually explains a Chrome that "just quits" is the
/// .ips file macOS writes next to it, and asking someone to go and find that by
/// hand is how a bug stays open for days. Perch can just read it.
enum CrashReports {

    private static var directories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true),
        ]
    }

    /// Newest Chrome crash report from the last hour, summarised. Nil if none.
    static func newestChromeCrash(within: TimeInterval = 3600) -> String? {
        guard let (url, when) = newestChromeCrashFile(within: within) else { return nil }
        return "\(url.lastPathComponent) (\(Self.relative(when)))\n" + summarise(url)
    }

    /// The two newest Chrome reports, summarised, for a bug report.
    static func recentChromeCrashes(limit: Int = 2) -> String {
        let files = chromeCrashFiles().prefix(limit)
        guard !files.isEmpty else { return "(no Chrome crash reports found)" }
        return files.map { "\($0.0.lastPathComponent) (\(Self.relative($0.1)))\n\(summarise($0.0))" }
                    .joined(separator: "\n\n")
    }

    private static func newestChromeCrashFile(within: TimeInterval) -> (URL, Date)? {
        guard let newest = chromeCrashFiles().first else { return nil }
        guard Date().timeIntervalSince(newest.1) <= within else { return nil }
        return newest
    }

    private static func chromeCrashFiles() -> [(URL, Date)] {
        var found: [(URL, Date)] = []
        for dir in directories {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for url in contents where url.lastPathComponent.hasPrefix("Google Chrome") {
                guard ["ips", "crash"].contains(url.pathExtension) else { continue }
                let when = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append((url, when))
            }
        }
        return found.sorted { $0.1 > $1.1 }
    }

    /// The handful of fields that identify a crash, not the whole file — an
    /// .ips runs to hundreds of kilobytes and no one reads that from a
    /// clipboard.
    private static func summarise(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "  (could not read)"
        }
        let wanted = ["exceptionType", "\"signal\"", "termination", "\"namespace\"",
                      "\"reason\"", "\"code\"", "procName", "\"app_version\"",
                      "\"osVersion\"", "Exception Type", "Termination Reason",
                      "Crashed Thread", "parentProc"]
        var lines = text.split(separator: "\n")
            .filter { line in wanted.contains { line.contains($0) } }
            .prefix(10)
            .map { "  " + $0.trimmingCharacters(in: .whitespaces) }
        if lines.isEmpty { lines = ["  (no recognisable fields)"] }
        return lines.joined(separator: "\n")
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
