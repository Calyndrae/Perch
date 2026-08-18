import Foundation

enum Perch {
    static let bundleID = "com.trixarh.perch"
    static let displayName = "Perch"

    /// Pinned by the `key` field in Extension/manifest.json, so this never drifts.
    static let extensionID = "bgcnjnfhpcimijankdloldghafhjaami"

    static let nativeHostName = "com.trixarh.perch.bridge"

    /// Single edit point for the setup link once the projects are published.
    static let setupURL = "https://github.com/Calyndrae/Perch"

    static let chromeBundleID = "com.google.Chrome"
    static let chromeAppPath = "/Applications/Google Chrome.app"

    /// Chrome's occlusion policy key. Setting it false stops Chrome from
    /// backgrounding a window that is fully covered — which is what keeps the
    /// mirror live instead of frozen on a stale frame.
    static let occlusionDefaultsKey = "WindowOcclusionEnabled"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Perch", isDirectory: true)
    }

    static var bridgeSocketPath: String {
        supportDirectory.appendingPathComponent("bridge.sock").path
    }

    /// How long the extension may be silent before we consider it gone.
    static let extensionGracePeriod: TimeInterval = 5.0
}
