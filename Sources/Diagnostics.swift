import AppKit

/// Everything needed to work out why Perch isn't behaving, in one paste.
///
/// This exists because the alternative was real: diagnosing a Chrome that quit
/// on another Mac meant talking someone through curling shell scripts down from
/// GitHub and pasting the output back, and a stale cached copy of one of those
/// scripts sent the whole investigation down the wrong path for an afternoon.
/// One button that reads the machine directly is both faster and harder to get
/// wrong.
struct Diagnostics {

    struct Input {
        var screenRecordingGranted: Bool
        var extensionPresent: Bool
        var managedChromeRunning: Bool
        var extensionVersion: String?
        var appUpdateStatus: String?
        var updateStatus: String?
        var lastError: String?
        var recentCalls: String
        var forwardInput: Bool
        var cropMirrorToPage: Bool
        var autoFullscreenOnShare: Bool
        var allowlist: [String]
        var windowCount: Int
    }

    static func report(_ input: Input) -> String {
        var out: [String] = []

        out.append("PERCH DIAGNOSTICS")
        out.append(ISO8601DateFormatter().string(from: Date()))
        out.append("")

        out.append("— Versions —")
        out.append("Perch:      \(AppUpdater.currentVersion) (\(bundlePath))")
        out.append("Extension:  \(input.extensionVersion ?? "not installed")")
        out.append("Chrome:     \(chromeVersion)")
        out.append("macOS:      \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("Hardware:   \(hardware)")
        out.append("")

        out.append("— State —")
        out.append("Screen Recording granted: \(yn(input.screenRecordingGranted))")
        out.append("Extension connected:      \(yn(input.extensionPresent))")
        out.append("Managed Chrome running:   \(yn(input.managedChromeRunning))")
        out.append("Chrome windows visible:   \(input.windowCount)")
        out.append("Last error:               \(input.lastError ?? "none")")
        out.append("App update:               \(input.appUpdateStatus ?? "not checked")")
        out.append("Extension update:         \(input.updateStatus ?? "not checked")")
        out.append("")

        out.append("— Settings —")
        out.append("Forward input to mirror:  \(yn(input.forwardInput))")
        out.append("Crop mirror to page:      \(yn(input.cropMirrorToPage))")
        out.append("Fullscreen while sharing: \(yn(input.autoFullscreenOnShare))")
        out.append("Real screen share allowed on: "
                 + (input.allowlist.isEmpty ? "(nothing)" : input.allowlist.joined(separator: ", ")))
        out.append("")

        out.append("— Files —")
        out.append("Profile:     \(exists(Perch.chromeProfilePath))")
        out.append("Chrome log:  \(exists(Perch.chromeLogPath))")
        out.append("Bridge sock: \(exists(Perch.bridgeSocketPath))")
        out.append("Host manifest: \(exists(nativeHostManifestPath))")
        out.append("Your extensions: "
                 + (UserExtensions.installed().isEmpty
                    ? "(none)"
                    : UserExtensions.installed().map { "\($0.name)\($0.enabled ? "" : " [off]")" }
                                        .joined(separator: ", ")))
        out.append("")

        out.append("— Last commands Perch sent Chrome —")
        out.append(input.recentCalls)
        out.append("")

        out.append("— Chrome crash reports —")
        out.append(CrashReports.recentChromeCrashes())
        out.append("")

        out.append("— chrome.log (last 40 lines) —")
        out.append(ChromeLauncher.lastChromeLogTail(40))

        return out.joined(separator: "\n")
    }

    @discardableResult
    static func copyToClipboard(_ input: Input) -> String {
        let text = report(input)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        return text
    }

    // MARK: - Bits and pieces

    private static func yn(_ v: Bool) -> String { v ? "yes" : "NO" }

    private static func exists(_ path: String) -> String {
        FileManager.default.fileExists(atPath: path) ? "present — \(path)" : "MISSING — \(path)"
    }

    private static var bundlePath: String { Bundle.main.bundleURL.path }

    private static var nativeHostManifestPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Google/Chrome/NativeMessagingHosts/"
                + "\(Perch.nativeHostName).json").path
    }

    private static var chromeVersion: String {
        let plist = Perch.chromeAppPath + "/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: plist),
              let version = dict["CFBundleShortVersionString"] as? String
        else { return "not found at \(Perch.chromeAppPath)" }
        return version
    }

    private static var hardware: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }
}
