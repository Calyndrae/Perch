import AVFoundation
import Foundation
import ScreenCaptureKit

/// Captures one Chrome window and pushes frames into an
/// `AVSampleBufferDisplayLayer`.
///
/// The key call is `SCContentFilter(desktopIndependentWindow:)` — ScreenCaptureKit
/// delivers that window's full content even while it is completely covered by
/// another app, which is what lets the mirror stay live while you're in Discord.
///
/// Audio is deliberately *not* captured: Chrome keeps playing through the system
/// output normally, so capturing it here would only double it up.
final class MirrorStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.trixarh.perch.frames")

    private(set) var sourceFrame: CGRect = .zero
    private(set) var sourcePID: pid_t = 0
    private(set) var lastFrameAt: Date?

    /// Where frames go. Assigned by MirrorWindow.
    weak var displayLayer: AVSampleBufferDisplayLayer?

    /// Fired on the main queue when the source window's size changes, so the
    /// mirror window can match its aspect ratio.
    var onSourceGeometryChange: ((CGRect) -> Void)?

    /// Fired on the main queue if the stream dies (window closed, Chrome quit).
    var onStop: ((Error?) -> Void)?

    var isRunning: Bool { stream != nil }

    /// Seconds since the last delivered frame, or nil when not streaming.
    ///
    /// Diagnostics only — do NOT use this to infer "the mirror is frozen".
    /// ScreenCaptureKit emits a frame only when the window's contents actually
    /// change, so a still page or a paused video sits at zero frames while the
    /// mirror is showing exactly the right picture.
    var secondsSinceLastFrame: TimeInterval? {
        guard isRunning, let last = lastFrameAt else { return nil }
        return Date().timeIntervalSince(last)
    }

    /// Where the captured window sits on screen, kept so a crop can be
    /// recomputed against it without re-resolving the window.
    private var windowFrame: CGRect = .zero
    /// The page area as fractions of the window. Nil mirrors the whole window.
    private var pageFraction: (x: Double, y: Double, w: Double, h: Double)?
    /// That fraction resolved against the current window rect.
    private var crop: CGRect?

    func start(windowID: CGWindowID,
               pageFraction: (x: Double, y: Double, w: Double, h: Double)? = nil) async throws {
        stop()

        guard let window = try await WindowPicker.resolve(windowID) else {
            throw MirrorError.windowGone
        }

        windowFrame = window.frame
        self.pageFraction = pageFraction
        self.crop = Self.resolve(pageFraction, in: window.frame)
        sourceFrame = self.crop ?? window.frame
        sourcePID = window.owningApplication?.processID ?? 0

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        apply(to: config, scale: scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = false
        config.scalesToFit = true
        config.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await s.startCapture()

        stream = s
        lastFrameAt = Date()

        let frame = sourceFrame
        await MainActor.run { self.onSourceGeometryChange?(frame) }
        NSLog("[Perch] streaming window %u (%.0fx%.0f)%@", windowID, frame.width, frame.height,
              self.crop == nil ? "" : " cropped to page")
    }

    /// Re-crops a running stream.
    ///
    /// Worth doing on a timer rather than once at the start: the sharing bar
    /// arrives the instant a site begins capturing and the page shrinks by 56pt
    /// under it, and the whole point of the crop is that you never see that.
    func updateCrop(_ fraction: (x: Double, y: Double, w: Double, h: Double)?,
                    windowFrame newFrame: CGRect? = nil) async {
        guard let s = stream else { return }
        if let newFrame, !newFrame.isEmpty { windowFrame = newFrame }
        pageFraction = fraction
        let next = Self.resolve(fraction, in: windowFrame)
        // Sub-pixel churn would restart the stream config every tick for nothing.
        if let a = next, let b = crop, a.insetBy(dx: -1.5, dy: -1.5).contains(b),
           b.insetBy(dx: -1.5, dy: -1.5).contains(a) { return }
        if next == nil && crop == nil { return }

        crop = next
        sourceFrame = next ?? windowFrame

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        apply(to: config, scale: scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = false
        config.scalesToFit = true
        config.capturesAudio = false
        do { try await s.updateConfiguration(config) }
        catch { NSLog("%@", "[Perch] could not re-crop: \(error.localizedDescription)") }

        let frame = sourceFrame
        await MainActor.run { self.onSourceGeometryChange?(frame) }
    }

    /// `sourceRect` is window-relative, so the screen-space crop is translated
    /// here — and clamped, because a rect that escapes the window makes
    /// ScreenCaptureKit hand back empty frames rather than an error.
    private func apply(to config: SCStreamConfiguration, scale: CGFloat) {
        let visible = crop ?? windowFrame
        if let crop {
            config.sourceRect = CGRect(x: crop.minX - windowFrame.minX,
                                       y: crop.minY - windowFrame.minY,
                                       width: crop.width, height: crop.height)
        }
        config.width  = Int(visible.width  * scale)
        config.height = Int(visible.height * scale)
    }

    /// Fractions are resolved against whatever rect ScreenCaptureKit reports,
    /// so no coordinate conversion happens anywhere.
    private static func resolve(_ f: (x: Double, y: Double, w: Double, h: Double)?,
                                in window: CGRect) -> CGRect? {
        guard let f, !window.isEmpty else { return nil }
        let rect = CGRect(x: window.minX + f.x * window.width,
                          y: window.minY + f.y * window.height,
                          width: f.w * window.width,
                          height: f.h * window.height)
        let clamped = rect.intersection(window)
        guard !clamped.isNull, clamped.width > 40, clamped.height > 40 else { return nil }
        // Nothing worth cropping — treat it as "no browser chrome found" rather
        // than re-encoding the stream for a two-pixel difference.
        if clamped.height > window.height - 4 && clamped.width > window.width - 4 { return nil }
        return clamped
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        crop = nil
        pageFraction = nil
        lastFrameAt = nil
        Task { try? await s.stopCapture() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // SCK marks frames it didn't actually repaint; enqueuing those is
        // harmless but pointless, and we must not treat them as liveness.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        lastFrameAt = Date()

        guard let layer = displayLayer else { return }
        DispatchQueue.main.async {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Perch] stream stopped: %@", error.localizedDescription)
        self.stream = nil
        DispatchQueue.main.async { self.onStop?(error) }
    }

    enum MirrorError: LocalizedError {
        case windowGone
        var errorDescription: String? {
            "That Chrome window no longer exists. Pick another one."
        }
    }
}
