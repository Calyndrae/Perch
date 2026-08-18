import AppKit
import ApplicationServices
import CoreGraphics

/// Puts the real macOS permission dialogs on screen instead of sending you into
/// System Settings to hunt for a checkbox.
///
/// The constraint that shapes all of this: **TCC only ever prompts once.** The
/// first `CGRequestScreenCaptureAccess()` shows the system dialog; every call
/// after that returns the stored answer silently, with nothing on screen. Same
/// for `AXIsProcessTrustedWithOptions`. So the rule is: ask automatically and
/// early, while asking still does something — and only once that's spent fall
/// back to a deep link into the right Settings pane.
///
/// Perch's stable signing identity matters here too. TCC keys its record to the
/// code signature, so an ad-hoc build would burn its one prompt on every
/// rebuild and then be stuck in the deep-link path forever.
enum PermissionPrompter {

    private enum Key {
        static let askedScreenRecording = "PerchAskedScreenRecording"
        static let askedAccessibility = "PerchAskedAccessibility"
    }

    // MARK: - Screen Recording

    /// Answers without prompting, so the UI can show real state on every launch.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static var hasAskedForScreenRecording: Bool {
        UserDefaults.standard.bool(forKey: Key.askedScreenRecording)
    }

    /// True when a dialog can still appear. Once macOS has an answer on file,
    /// asking again is a silent no-op and we must say so rather than pretending.
    static var canPromptForScreenRecording: Bool {
        !screenRecordingGranted && !hasAskedForScreenRecording
    }

    /// Shows the system dialog. Returns the (possibly unchanged) grant state.
    @discardableResult
    static func promptForScreenRecording() -> Bool {
        UserDefaults.standard.set(true, forKey: Key.askedScreenRecording)
        let granted = CGRequestScreenCaptureAccess()
        NSLog("[Perch] screen recording prompt shown; granted=%@", granted ? "yes" : "no")
        return granted
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    // MARK: - Accessibility

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var hasAskedForAccessibility: Bool {
        UserDefaults.standard.bool(forKey: Key.askedAccessibility)
    }

    static var canPromptForAccessibility: Bool {
        !accessibilityGranted && !hasAskedForAccessibility
    }

    /// Shows the system dialog, which carries its own "Open System Settings"
    /// button. We deliberately do NOT also open Settings ourselves — doing both
    /// throws a window at you on top of the dialog you were about to read.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        UserDefaults.standard.set(true, forKey: Key.askedAccessibility)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSLog("[Perch] accessibility prompt shown; trusted=%@", trusted ? "yes" : "no")
        return trusted
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: - Relaunch

    /// macOS usually won't hand a running process a Screen Recording grant it
    /// didn't have at launch, so the honest fix after granting is to restart.
    static func relaunchPerch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
