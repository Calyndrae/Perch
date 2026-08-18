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
            Perch asked macOS for Screen Recording as soon as it opened, so a \
            permission box should be on screen now.

            Screen Recording is one macOS never lets an app switch on for you — \
            the box only takes you to the right Settings pane, where Perch is \
            already listed. Turn it on there, then come back and relaunch.
            """
        case .extensionMissing:
            return """
            Perch and its Chrome extension only work as a pair. The app moves \
            the picture; the extension blocks the exit-intent popups and the \
            “are you sure you want to leave?” prompts.

            Chrome only lets an app add an extension to a session that app \
            started itself, so Perch will close Chrome and open it again with \
            the extension already in place. Chrome restores your tabs as usual, \
            but anything you’ve typed and not sent will be lost.
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
    /// False once macOS has an answer on file — from then on a prompt is a
    /// silent no-op and Settings is genuinely the only route.
    @Published private(set) var canPromptScreenRecording = true
    /// After switching Perch on in Settings, the running process still has the
    /// old answer — macOS hands a Screen Recording grant out at launch. So once
    /// we've asked and are still denied, offer the restart that actually fixes it.
    var shouldOfferRelaunch: Bool {
        !screenRecordingGranted && !canPromptScreenRecording
    }

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

        Task {
            await refreshAll()
            // Ask every launch while the permission is missing. Calling this
            // when macOS already has an answer is a silent no-op, so there is
            // no cost — whereas gating it on our own "have we asked" flag
            // strands the app permanently if the user ever dismissed the box
            // without answering it.
            if !screenRecordingGranted {
                requestScreenRecording()
            }
        }
    }

    func shutdown() {
        healthTimer?.invalidate()
        stream.stop()
        bridge.stop()
        launcher.shutdown()
    }

    private func tick() {
        // Nothing to poll: input now goes over the DevTools pipe, so there is
        // no Accessibility grant to watch for.
    }

    // MARK: - Gate

    func refreshAll() async {
        canPromptScreenRecording = PermissionPrompter.canPromptForScreenRecording
        await refreshWindows()
        refreshGate()
    }

    private func checkScreenRecording() -> Bool {
        PermissionPrompter.screenRecordingGranted
    }

    /// Puts the system dialog on screen. Only does anything the first time —
    /// see PermissionPrompter for why.
    func requestScreenRecording() {
        let granted = PermissionPrompter.promptForScreenRecording()
        _ = granted
        canPromptScreenRecording = PermissionPrompter.canPromptForScreenRecording
        Task { await refreshAll() }
    }

    func openScreenRecordingSettings() {
        PermissionPrompter.openScreenRecordingSettings()
    }

    func relaunchPerch() { PermissionPrompter.relaunchPerch() }

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
        window.mirrorView.onClick = { [weak self] point, count in
            guard let self else { return }
            Task { await self.launcher.forwardClick(at: point, clickCount: count) }
        }
        window.mirrorView.onScroll = { [weak self] point, dx, dy in
            guard let self else { return }
            Task { await self.launcher.forwardScroll(at: point, deltaX: dx, deltaY: dy) }
        }

        Task {
            do {
                try await stream.start(windowID: windowID)
                // Bind input to the tab actually showing in this window.
                if let w = windows.first(where: { $0.id == windowID }) {
                    _ = try? await launcher.attachToPage(showingIn: w.frame)
                }
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

    /// Shows the system dialog, which has its own "Open System Settings"
    /// button. Opening Settings ourselves as well would bury that dialog.
    func openSetupPage() {
        if let url = URL(string: Perch.setupURL) { NSWorkspace.shared.open(url) }
    }
}
