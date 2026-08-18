import AVFoundation
import AppKit

/// The floating window that shows the mirrored Chrome window.
///
/// Because this is an ordinary app window, Chrome's own screen-share picker
/// lists it like any other window — so you can share *this* to a website and it
/// will only ever see that one Chrome window, live, no matter what you switch to.
final class MirrorWindow: NSWindow {
    let mirrorView: MirrorView

    init(stream: MirrorStream) {
        mirrorView = MirrorView(stream: stream)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        title = "Perch"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = mirrorView
        backgroundColor = .black
        isReleasedWhenClosed = false
        setFrameAutosaveName("PerchMirror")
    }

    /// Lock the window's aspect ratio to the source so the mirror never distorts.
    func matchAspect(to sourceFrame: CGRect) {
        guard sourceFrame.width > 0, sourceFrame.height > 0 else { return }
        contentAspectRatio = NSSize(width: sourceFrame.width, height: sourceFrame.height)

        let current = frame.size
        let ratio = sourceFrame.height / sourceFrame.width
        let newHeight = current.width * ratio
        setContentSize(NSSize(width: current.width, height: newHeight))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Displays frames and, when enabled, relays mouse input back to the real
/// Chrome window.
final class MirrorView: NSView {
    private let stream: MirrorStream
    private let layerHost = AVSampleBufferDisplayLayer()

    /// When false the mirror is view-only and clicks do nothing.
    var forwardsInput = true

    /// Where input goes. Set by AppState, which routes it over the DevTools
    /// pipe. Synthetic CGEvents were tried first and do not work: Chromium
    /// ignores mouse events posted to its pid even when frontmost.
    var onClick: ((CGPoint, Int) -> Void)?
    var onScroll: ((CGPoint, Double, Double) -> Void)?

    /// Top-left origin makes the math line up with CoreGraphics global
    /// coordinates, which is what CGEvent wants.
    override var isFlipped: Bool { true }

    init(stream: MirrorStream) {
        self.stream = stream
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        layerHost.videoGravity = .resizeAspect
        layerHost.frame = bounds
        layerHost.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(layerHost)

        stream.displayLayer = layerHost
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layerHost.frame = bounds
    }

    // MARK: - Input relay

    /// Map a point in this view onto the corresponding global screen point
    /// inside the real Chrome window.
    private func globalPoint(for local: NSPoint) -> CGPoint? {
        let src = stream.sourceFrame
        guard src.width > 0, src.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }

        // The layer letterboxes with .resizeAspect; compute the drawn rect so
        // clicks in the black bars don't map to bogus coordinates.
        let scale = min(bounds.width / src.width, bounds.height / src.height)
        let drawn = CGSize(width: src.width * scale, height: src.height * scale)
        let originX = (bounds.width  - drawn.width)  / 2
        let originY = (bounds.height - drawn.height) / 2
        let content = CGRect(x: originX, y: originY, width: drawn.width, height: drawn.height)
        guard content.contains(local) else { return nil }

        let fx = (local.x - content.minX) / content.width
        let fy = (local.y - content.minY) / content.height
        return CGPoint(x: src.origin.x + fx * src.width,
                       y: src.origin.y + fy * src.height)
    }

    private func globalPoint(from event: NSEvent) -> CGPoint? {
        guard forwardsInput else { return nil }
        return globalPoint(for: convert(event.locationInWindow, from: nil))
    }

    // The click is sent on mouseUp so a click-to-focus on the mirror window
    // doesn't also fire into the page.
    override func mouseUp(with event: NSEvent) {
        guard let p = globalPoint(from: event) else { return }
        onClick?(p, max(1, event.clickCount))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = globalPoint(from: event) else { return }
        // AppKit reports scrolling deltas inverted relative to page scrolling.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 16.0
        onScroll?(p, -Double(event.scrollingDeltaX) * scale,
                     -Double(event.scrollingDeltaY) * scale)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
