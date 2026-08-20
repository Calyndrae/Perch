import AppKit
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Perch") {
            ContentView(state: delegate.state)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh Chrome Windows") {
                    Task { await delegate.state.refreshAll() }
                }
                .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView(state: delegate.state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateNotifier.clearIfApplied()
        state.boot()
        installStatusItem()

        // Chrome coming and going changes the gate and the window list.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.state.refreshAll() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Perch")

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Perch", action: #selector(openMain), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Stop Mirroring", action: #selector(stopMirroring), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.menu = menu
        statusItem = item
        refreshUpdateBadge()
        NotificationCenter.default.addObserver(
            forName: .perchUpdateStaged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshUpdateBadge() }
        }
    }

    /// The one place a staged update is visible without opening Settings.
    private func refreshUpdateBadge() {
        guard let menu = statusItem?.menu else { return }
        let existing = menu.items.first { $0.identifier == Self.updateItemID }
        guard let version = UpdateNotifier.pendingAppVersion else {
            if let existing { menu.removeItem(existing) }
            statusItem?.button?.image = NSImage(
                systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Perch")
            return
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "Perch — update ready")
        let title = "Update to \(version) — Relaunch"
        if let existing { existing.title = title; return }
        let entry = NSMenuItem(title: title, action: #selector(relaunchForUpdate), keyEquivalent: "")
        entry.target = self
        entry.identifier = Self.updateItemID
        menu.insertItem(entry, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    private static let updateItemID = NSUserInterfaceItemIdentifier("perch.update")

    @objc private func relaunchForUpdate() {
        PermissionPrompter.relaunchPerch()
    }

    @objc private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Perch" && !($0 is MirrorWindow) }?
            .makeKeyAndOrderFront(nil)
    }

    @objc private func stopMirroring() {
        Task { @MainActor in state.stopMirroring() }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // The selector differs across macOS releases; try the current one first.
        if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
            NSApp.perform(Selector(("showSettingsWindow:")), with: nil)
        } else {
            NSApp.perform(Selector(("showPreferencesWindow:")), with: nil)
        }
    }
}
