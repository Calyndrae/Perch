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

    func start(windowID: CGWindowID) async throws {
        stop()

        guard let window = try await WindowPicker.resolve(windowID) else {
            throw MirrorError.windowGone
        }

        sourceFrame = window.frame
        sourcePID = window.owningApplication?.processID ?? 0

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.width  = Int(window.frame.width  * scale)
        config.height = Int(window.frame.height * scale)
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

        let frame = window.frame
        await MainActor.run { self.onSourceGeometryChange?(frame) }
        NSLog("[Perch] streaming window %u (%.0fx%.0f)", windowID, frame.width, frame.height)
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
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
