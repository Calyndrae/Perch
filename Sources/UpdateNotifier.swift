import AppKit

/// Announces an update that has already been installed on disk.
///
/// Not through UNUserNotificationCenter. That is refused outright for a locally
/// signed, non-notarized build — measured on this Mac: requestAuthorization
/// returns granted=false with "Notifications are not allowed for this
/// application", authorizationStatus stays notDetermined, and nothing is ever
/// delivered. Notarization is the only way past it and is out of scope.
///
/// So the announcement goes out through surfaces that do work: Perch's own menu
/// bar item, and a real banner raised by the Chrome extension — Chrome is
/// notarized and its notifications land, which is already proven by the
/// "Perch isn't running" toast. The extension picks this up by asking the
/// native host, which reads the value written here.
enum UpdateNotifier {

    private enum Key {
        static let pendingApp = "PerchPendingUpdateVersion"
        static let pendingExtension = "PerchPendingExtensionVersion"
    }

    /// The version installed on disk and waiting for a relaunch, if any.
    static var pendingAppVersion: String? {
        guard let v = UserDefaults.standard.string(forKey: Key.pendingApp),
              v != AppUpdater.currentVersion else { return nil }
        return v
    }

    static func appUpdated(to version: String) {
        UserDefaults.standard.set(version, forKey: Key.pendingApp)
        NSLog("%@", "[Perch] update \(version) staged; announcing")
        NotificationCenter.default.post(name: .perchUpdateStaged, object: nil)
    }

    static func extensionUpdated(to version: String) {
        UserDefaults.standard.set(version, forKey: Key.pendingExtension)
        NotificationCenter.default.post(name: .perchUpdateStaged, object: nil)
    }

    /// Called once the running copy IS the new version, so the menu bar stops
    /// advertising an update that already happened.
    static func clearIfApplied() {
        if let v = UserDefaults.standard.string(forKey: Key.pendingApp),
           v == AppUpdater.currentVersion {
            UserDefaults.standard.removeObject(forKey: Key.pendingApp)
        }
    }
}

extension Notification.Name {
    static let perchUpdateStaged = Notification.Name("PerchUpdateStaged")
}
