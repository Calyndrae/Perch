import AppKit
import Foundation
import ScreenCaptureKit

struct CapturableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let ownerPID: pid_t
    let frame: CGRect

    static func == (a: CapturableWindow, b: CapturableWindow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum WindowPicker {
    /// Chrome windows worth showing: on-screen or not, but real windows with a
    /// title and a non-trivial size. `onScreenWindowsOnly: false` matters — a
    /// window buried behind Discord must still be listed, since capturing it
    /// while covered is the entire point of this app.
    static func chromeWindows() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)

        return content.windows
            .filter { $0.owningApplication?.bundleIdentifier == Perch.chromeBundleID }
            .filter { $0.frame.width > 200 && $0.frame.height > 200 }
            .filter { !($0.title ?? "").isEmpty }
            .map {
                CapturableWindow(
                    id: $0.windowID,
                    title: $0.title ?? "Untitled",
                    ownerPID: $0.owningApplication?.processID ?? 0,
                    frame: $0.frame)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Re-resolve an `SCWindow` by ID; needed because SCWindow objects go stale
    /// as Chrome opens and closes windows.
    static func resolve(_ id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == id }
    }

    static func chromeInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Perch.chromeBundleID)
    }

    static func isChromeRunning() -> Bool { !chromeInstances().isEmpty }
}
