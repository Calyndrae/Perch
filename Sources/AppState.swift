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
        case .chromeNotRunning:      return "Perch hasn’t started Chrome yet"
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
            started itself, so Perch opens a second Chrome with the extension \
            already in place. It uses its own profile, so your everyday Chrome \
            keeps running untouched — nothing is closed and no tabs are lost.

            Watch things in that Chrome window, and mirror it from here.

            If Perch was restarted, press this again: the link to Chrome belongs \
            to the Perch that opened it, so a fresh Perch has to open a fresh \
            Chrome. It'll reuse the same profile, so nothing is lost.
            """
        case .chromeNotRunning:
            return """
            Perch mirrors the Chrome it starts itself, because that is the only \
            one carrying the extension. Your everyday Chrome is left alone.
            """
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
    /// Which window is on screen in the mirror, so the list can say so.
    @Published private(set) var mirroredWindowID: CGWindowID?
    /// True when the Chrome we can actually drive is running.
    @Published private(set) var managedChromeRunning = false

    // Health
    @Published var lastError: String?

    // Settings
    @Published var forwardInput = true {
        didSet { mirrorWindow?.mirrorView.forwardsInput = forwardInput }
    }
    /// Sites allowed a genuine screen share, by registrable domain.
    ///
    /// The substitution fails closed, which is right almost always and wrong
    /// for the one site that actually needs to show you a whole screen. An
    /// entry covers its subdomains and every path beneath it, so `example.com`
    /// also means `login.example.com`.
    @Published var screenShareAllowlist: [String] =
        UserDefaults.standard.stringArray(forKey: "PerchScreenShareAllowlist") ?? [] {
        didSet { UserDefaults.standard.set(screenShareAllowlist, forKey: "PerchScreenShareAllowlist") }
    }

    /// Accepts whatever someone pastes — a bare domain, a full URL, a trailing
    /// slash — and keeps the host. Returns nil if there is no host in it.
    func addAllowedDomain(_ raw: String) -> Bool {
        guard let host = Self.normaliseDomain(raw) else { return false }
        guard !screenShareAllowlist.contains(host) else { return true }
        screenShareAllowlist.append(host)
        screenShareAllowlist.sort()
        return true
    }

    func removeAllowedDomain(_ host: String) {
        screenShareAllowlist.removeAll { $0 == host }
    }

    static func normaliseDomain(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        text = text.components(separatedBy: "/")[0]        // drop any path
        text = text.components(separatedBy: "@").last ?? text
        text = text.components(separatedBy: ":")[0]        // drop any port
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard text.contains("."), !text.contains(" "),
              text.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil
        else { return nil }
        return text
    }

    /// Put the Chrome window fullscreen for as long as a site is capturing, so
    /// the tab strip and address bar collapse and only Chrome's sharing bar is
    /// left. Read by the extension through the native host at the moment it
    /// acts, so a change here takes effect on the next share rather than the
    /// next restart.
    @Published var autoFullscreenOnShare = UserDefaults.standard.object(forKey: "PerchAutoFullscreenOnShare") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoFullscreenOnShare, forKey: "PerchAutoFullscreenOnShare") }
    }
    /// Crop the tab strip, address bar and "Sharing this tab" indicator out of
    /// the mirror, leaving only the page.
    ///
    /// Chrome's sharing bar cannot be closed or suppressed — measured against
    /// every flag that claims to, and the extension route that avoids it needs
    /// an activeTab grant a UI-less extension can never get. Cropping is what's
    /// left, and it is the only thing that removes it from view outright.
    @Published var cropMirrorToPage = UserDefaults.standard.object(forKey: "PerchCropMirror") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(cropMirrorToPage, forKey: "PerchCropMirror")
            Task { await recrop() }
        }
    }
    @Published private(set) var isLaunchingChrome = false
    @Published private(set) var extensionVersion: String?
    @Published private(set) var updateStatus: String?
    @Published private(set) var appUpdateStatus: String?
    @Published private(set) var appUpdateReady = false

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
            if case .updated(let version) = result {
                UpdateNotifier.extensionUpdated(to: version)
            }
        }

        // And update Perch itself. The swap happens on disk; the running copy
        // stays as it is until relaunched, so this never pulls the app out from
        // under someone mid-session.
        Task { @MainActor in
            let result = await AppUpdater.checkAndInstall()
            self.appUpdateStatus = result.describedForUser
            if case .installed(let version) = result {
                self.appUpdateReady = true
                UpdateNotifier.appUpdated(to: version)
            }
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

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        managedChromeRunning = launcher.isManagingChrome

        // Chrome windows open, close and get renamed constantly. Leaving the
        // list stale until someone finds the refresh icon made the app look
        // broken, so it refreshes itself every couple of seconds.
        if tickCount % 2 == 0 {
            Task { await refreshWindows() }
        }

        // The extension's link dies whenever its service worker is reclaimed,
        // and nothing inside Chrome reliably brings it back. Perch holds the
        // DevTools pipe, so it does the reviving itself rather than leaving the
        // app sitting there looking broken.
        // Also covers deliberate removal, not just an idle worker: without an
        // enterprise lock available, putting it back is the only enforcement
        // there is.
        if managedChromeRunning, !extensionPresent, tickCount % 5 == 0 {
            Task { await launcher.ensureExtensionLoaded() }
        }

        // The page area moves under us — the sharing bar alone takes 56pt the
        // moment a site starts capturing — so the crop is re-read rather than
        // measured once. updateCrop ignores anything that hasn't really changed.
        if isMirroring, cropMirrorToPage, tickCount % 2 == 0 {
            Task { await recrop() }
        }

        // Chrome dying after a successful start used to be silent: the window
        // list simply emptied. Say what happened, once, with a reason.
        if let report = launcher.noticeUnexpectedChromeExit() {
            lastError = report
            managedChromeRunning = false
            NSLog("%@", "[Perch] \(report)")
        }

        // If the managed Chrome went away, stop claiming to mirror it.
        if isMirroring, !stream.isRunning {
            isMirroring = false
            mirroredWindowID = nil
        }
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
            // Quiet on purpose: this now runs on a timer, and a transient
            // failure should not paint an error banner over a working app.
            NSLog("%@", "[Perch] window refresh failed: \(error.localizedDescription)")
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
                // Attach BEFORE streaming: the crop comes from the page, so the
                // first frame is already trimmed rather than showing a tab strip
                // for a moment and then snapping.
                var fraction: (x: Double, y: Double, w: Double, h: Double)?
                if let w = windows.first(where: { $0.id == windowID }) {
                    _ = try? await launcher.attachToPage(showingIn: w.frame)
                    if cropMirrorToPage { fraction = await launcher.pageInsetFractions() }
                }
                try await stream.start(windowID: windowID, pageFraction: fraction)
                isMirroring = true
                mirroredWindowID = windowID
                window.makeKeyAndOrderFront(nil)
            } catch {
                lastError = error.localizedDescription
                isMirroring = false
            }
        }
    }

    private func recrop() async {
        guard isMirroring else { return }
        let windowFrame = windows.first(where: { $0.id == mirroredWindowID })?.frame
        let fraction = cropMirrorToPage ? await launcher.pageInsetFractions() : nil
        await stream.updateCrop(fraction, windowFrame: windowFrame)
    }

    func stopMirroring() {
        stream.stop()
        isMirroring = false
        mirroredWindowID = nil
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

    /// Everything about this machine's Perch, on the clipboard.
    @discardableResult
    func copyDiagnostics() -> String {
        let text = Diagnostics.copyToClipboard(.init(
            screenRecordingGranted: screenRecordingGranted,
            extensionPresent: extensionPresent,
            managedChromeRunning: managedChromeRunning,
            extensionVersion: extensionVersion,
            appUpdateStatus: appUpdateStatus,
            updateStatus: updateStatus,
            lastError: lastError,
            recentCalls: launcher.recentCallLog,
            forwardInput: forwardInput,
            cropMirrorToPage: cropMirrorToPage,
            autoFullscreenOnShare: autoFullscreenOnShare,
            allowlist: screenShareAllowlist,
            windowCount: windows.count))
        NSLog("%@", "[Perch] diagnostics copied (\(text.count) characters)")
        return text
    }

    func checkForAppUpdate() {
        Task {
            let result = await AppUpdater.checkAndInstall()
            appUpdateStatus = result.describedForUser
            if case .installed(let version) = result {
                appUpdateReady = true
                UpdateNotifier.appUpdated(to: version)
            }
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
