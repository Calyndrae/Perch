import AppKit
import CoreGraphics

/// Relays mouse input from the mirror back into the real Chrome window.
///
/// `CGEventPostToPid` is the whole reason this works: it delivers the event
/// straight into Chrome's event queue *without* activating Chrome or pulling it
/// to the front. A plain `CGEventPost` would go to whatever app is frontmost,
/// which would defeat the point of a mirror you use while doing something else.
///
/// Requires Accessibility permission. Keyboard relay is deliberately not
/// implemented — Chrome routes key events by its own key-window state, so it is
/// unreliable enough that offering it would be a false promise.
enum InputForwarder {
    enum Action {
        case leftDown, leftUp, leftDrag
        case rightDown, rightUp
        case move
        case scroll
    }

    static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt. Returns the current state.
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func send(_ action: Action, at point: CGPoint, toPID pid: pid_t, event: NSEvent) {
        guard hasPermission else { return }

        let cgEvent: CGEvent?

        switch action {
        case .scroll:
            // NSEvent scrolling deltas are inverted relative to what CGEvent
            // expects for a "natural" feel, hence the sign flip.
            let dy = Int32(event.scrollingDeltaY.rounded())
            let dx = Int32(event.scrollingDeltaX.rounded())
            cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: event.hasPreciseScrollingDeltas ? .pixel : .line,
                wheelCount: 2,
                wheel1: dy, wheel2: dx, wheel3: 0)
            // A scroll must be located over the target for Chrome to route it
            // to the right frame.
            cgEvent?.location = point

        case .leftDown, .leftUp, .leftDrag, .rightDown, .rightUp, .move:
            let (type, button) = mapping(for: action)
            cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button)
            if action == .leftDown || action == .leftUp {
                cgEvent?.setIntegerValueField(.mouseEventClickState,
                                              value: Int64(max(1, event.clickCount)))
            }
        }

        guard let e = cgEvent else { return }
        e.flags = flags(from: event)
        e.postToPid(pid)
    }

    private static func mapping(for action: Action) -> (CGEventType, CGMouseButton) {
        switch action {
        case .leftDown:  return (.leftMouseDown, .left)
        case .leftUp:    return (.leftMouseUp, .left)
        case .leftDrag:  return (.leftMouseDragged, .left)
        case .rightDown: return (.rightMouseDown, .right)
        case .rightUp:   return (.rightMouseUp, .right)
        case .move:      return (.mouseMoved, .left)
        case .scroll:    return (.scrollWheel, .left)
        }
    }

    private static func flags(from event: NSEvent) -> CGEventFlags {
        var f: CGEventFlags = []
        let m = event.modifierFlags
        if m.contains(.shift)   { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option)  { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        return f
    }
}
