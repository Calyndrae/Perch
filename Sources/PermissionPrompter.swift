import AppKit
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
///
/// Screen Recording is the only permission Perch needs. Clicking through the
/// mirror used to require Accessibility; input now travels over the DevTools
/// pipe instead, so that grant was dropped entirely.
enum PermissionPrompter {

    private enum Key {
        static let askedScreenRecording = "PerchAskedScreenRecording"
    }

    // MARK: - Screen Recording

    /// Answers without prompting, so the UI can show real state on every launch.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static var hasAskedForScreenRecording: Bool {
        UserDefaults.standard.bool(forKey: Key.askedScreenRecording)
    }

    /// Whether we've asked before. This is a HINT for wording only — never a
    /// gate on whether to ask.
    ///
    /// Our flag and TCC's actual record drift apart the moment a user dismisses
    /// the dialog without choosing: TCC stores no answer, so macOS would still
    /// show the box, but our flag says "asked". Gating on it stranded the app
    /// with no way back. Asking when already answered is a harmless no-op, so
    /// the safe direction is to always ask.
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
