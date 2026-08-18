import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// Why the app is refusing to mirror, if it is.
enum GateFailure: Equatable {
    case screenRecordingDenied
    case extensionMissing
    case chromeNotRunning

    var title: String {
        switch self {
        case .screenRecordingDenied: return "Perch needs Screen Recording access"
        case .extensionMissing:      return "The Perch Chrome extension isn’t running"
        case .chromeNotRunning:      return "Chrome isn’t open"
        }
    }

    var detail: String {
        switch self {
        case .screenRecordingDenied:
            return """
            macOS won’t let Perch see a Chrome window until you allow it. \
            Open Privacy & Security → Screen Recording and switch Perch on.

            You only have to do this once.
            """
        case .extensionMissing:
            return """
            Perch and its Chrome extension only work as a pair. The app moves the \
            picture; the extension is what stops sites from noticing you’ve looked \
            away — that’s what kills the exit-intent popups and the “are you still \
            watching?” interruptions.

            Install the extension, then come back and press Check Again.
            """
        case .chromeNotRunning:
            return "Open Google Chrome and Perch will pick it up automatically."
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // Gate
    @Published private(set) var gateFailures: [GateFailure] = []
    @Published private(set) var extensionPresent = false
    @Published private(set) var screenRecordingGranted = false

    // Windows
    @Published private(set) var windows: [CapturableWindow] = []
    @Published var selectedWindowID: CGWindowID?
    @Published private(set) var isMirroring = false

    // Health
    @Published var lastError: String?

    // Settings
    @Published var forwardInput = true {
        didSet { mirrorWindow?.mirrorView.forwardsInput = forwardInput }
    }
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var isLaunchingChrome = false
    @Published private(set) var extensionVersion: String?
    @Published private(set) var updateStatus: String?

    let stream = MirrorStream()
    private let bridge = BridgeServer()
    private let launcher = ChromeLauncher()
    private var mirrorWindow: MirrorWindow?
    private var healthTimer: Timer?

    var canMirror: Bool { gateFailures.isEmpty }

    // MARK: - Lifecycle

    func boot() {
        BridgeHostInstaller.installIfNeeded()
        extensionVersion = ExtensionUpdater.installedVersion()

        // Refresh from GitHub in the background so the next launch is current.
        Task { @MainActor in
            let result = await ExtensionUpdater.updateFromGitHub()
            self.updateStatus = result.describedForUser
            self.extensionVersion = ExtensionUpdater.installedVersion()
        }

        bridge.onPresenceChange = { [weak self] present in
            Task { @MainActor in
                self?.extensionPresent = present
                self?.refreshGate()
            }
        }
        do { try bridge.start() }
        catch { lastError = error.localizedDescription }

        stream.onSourceGeometryChange = { [weak self] frame in
            self?.mirrorWindow?.matchAspect(to: frame)
        }
        stream.onStop = { [weak self] error in
            Task { @MainActor in
                self?.isMirroring = false
                if let error { self?.lastError = error.localizedDescription }
            }
        }

        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        Task { await refreshAll() }
    }

    func shutdown() {
        healthTimer?.invalidate()
        stream.stop()
        bridge.stop()
        launcher.shutdown()
    }

    private func tick() {
        accessibilityGranted = InputForwarder.hasPermission
        mirrorWindow?.mirrorView.inputPermissionGranted = accessibilityGranted
    }

    // MARK: - Gate

    func refreshAll() async {
        accessibilityGranted = InputForwarder.hasPermission
        await refreshWindows()
        refreshGate()
    }

    /// `CGPreflightScreenCaptureAccess` answers without prompting, which lets the
    /// gate screen show the real state instead of nagging on every launch.
    private func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        Task { await refreshAll() }
    }

    func refreshGate() {
        var failures: [GateFailure] = []

        screenRecordingGranted = checkScreenRecording()
        if !screenRecordingGranted { failures.append(.screenRecordingDenied) }
        if !extensionPresent { failures.append(.extensionMissing) }
        if !WindowPicker.isChromeRunning() { failures.append(.chromeNotRunning) }

        gateFailures = failures

        if !failures.isEmpty && isMirroring {
            stopMirroring()
        }
    }

    // MARK: - Windows

    func refreshWindows() async {
        guard checkScreenRecording() else { windows = []; return }
        do {
            windows = try await WindowPicker.chromeWindows()
            if let sel = selectedWindowID, !windows.contains(where: { $0.id == sel }) {
                selectedWindowID = nil
            }
        } catch {
            lastError = error.localizedDescription
            windows = []
        }
    }

    // MARK: - Mirroring

    func startMirroring(_ windowID: CGWindowID) {
        guard canMirror else { return }
        selectedWindowID = windowID
        lastError = nil

        let window = mirrorWindow ?? {
            let w = MirrorWindow(stream: stream)
            mirrorWindow = w
            return w
        }()
        window.mirrorView.forwardsInput = forwardInput
        window.mirrorView.inputPermissionGranted = InputForwarder.hasPermission

        Task {
            do {
                try await stream.start(windowID: windowID)
                isMirroring = true
                window.makeKeyAndOrderFront(nil)
            } catch {
                lastError = error.localizedDescription
                isMirroring = false
            }
        }
    }

    func stopMirroring() {
        stream.stop()
        isMirroring = false
        mirrorWindow?.orderOut(nil)
    }

    // MARK: - Settings actions

    /// Quit Chrome and start it again with the extension already loaded.
    /// The one route Chrome still allows a native app on macOS.
    func relaunchChromeWithExtension() {
        guard !isLaunchingChrome else { return }
        isLaunchingChrome = true
        lastError = nil
        Task {
            // Always try for the newest extension before handing it to Chrome;
            // a failure here is non-fatal and falls back to the bundled copy.
            let result = await ExtensionUpdater.updateFromGitHub()
            updateStatus = result.describedForUser
            extensionVersion = ExtensionUpdater.installedVersion()
            do {
                _ = try await launcher.relaunchChromeWithExtension()
                // Give the extension's service worker time to dial the bridge.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await refreshAll()
            } catch {
                lastError = error.localizedDescription
            }
            isLaunchingChrome = false
        }
    }

    func checkForExtensionUpdate() {
        Task {
            let result = await ExtensionUpdater.updateFromGitHub()
            updateStatus = result.describedForUser
            extensionVersion = ExtensionUpdater.installedVersion()
        }
    }

    func requestAccessibility() {
        InputForwarder.requestPermission()
        InputForwarder.openAccessibilitySettings()
    }

    func openScreenRecordingSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func openSetupPage() {
        if let url = URL(string: Perch.setupURL) { NSWorkspace.shared.open(url) }
    }
}
