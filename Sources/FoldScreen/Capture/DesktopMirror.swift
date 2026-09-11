import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import AppKit

/// Where desktop frames come from.
///
/// Two adapters satisfy this: a live ScreenCaptureKit mirror, and a still source
/// that replays one image. The settings preview uses the still adapter, which is
/// why the preview keeps working before screen recording has ever been granted.
protocol DesktopFrames: AnyObject {
    /// Called on an arbitrary queue with each complete frame.
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// Called when capture stops on its own, for example when the display sleeps.
    var onFailure: ((Error) -> Void)? { get set }

    /// Begins capturing a display. Throws if permission is missing or the
    /// display is gone.
    func start(displayID: CGDirectDisplayID) async throws
    func stop() async

    /// Raises the frame rate while the fold is on screen and lowers it again
    /// afterwards, so an idle menu bar app is not paying for 60 fps.
    func setHighRate(_ high: Bool) async
}

/// Live capture of one display.
///
/// The app's own windows are excluded from the filter. Without that the overlay
/// would capture itself and the fold would recurse.
final class ScreenCaptureMirror: NSObject, DesktopFrames, SCStreamOutput, SCStreamDelegate {

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: ((Error) -> Void)?

    /// Frame rate while the desktop is unfolded and while it is folding.
    private static let idleRate = 5
    private static let activeRate = 60

    private let queue = DispatchQueue(label: "app.ruic.foldscreen.capture", qos: .userInteractive)

    // Stream state is only touched from the main actor.
    @MainActor private var stream: SCStream?
    @MainActor private var configuration: SCStreamConfiguration?
    /// Guards against a slow `start` finishing after a newer `stop`.
    @MainActor private var generation = 0
    @MainActor private var highRateRequested = false
    @MainActor private var rateUpdateInFlight = false

    /// Number of frames delivered since the last start. Reported by the harness.
    private let counterLock = NSLock()
    private var delivered = 0
    var frameCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return delivered
    }

    @MainActor
    func start(displayID: CGDirectDisplayID) async throws {
        generation += 1
        let request = generation

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }

        // Exclude this app from its own capture. Without this the overlay would
        // capture the folded desktop it is drawing and fold it again, frame after
        // frame, which reads as a runaway feedback smear. Note that
        // `exceptingWindows` is an exception *to* an exclusion, so the exclusion
        // has to name the application; listing windows alone excludes nothing.
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let ownApplications = content.applications.filter { $0.processID == ownProcess }
        let filter = SCContentFilter(
            display: display, excludingApplications: ownApplications, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        // Capture at the display mode's backing resolution so Retina displays
        // stay sharp instead of being upscaled from points.
        let mode = CGDisplayCopyDisplayMode(displayID)
        configuration.width = mode?.pixelWidth ?? CGDisplayPixelsWide(displayID)
        configuration.height = mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.idleRate))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        self.stream = stream
        self.configuration = configuration
        self.highRateRequested = false
        resetCounter()

        do {
            try await stream.startCapture()
        } catch {
            if self.stream === stream {
                self.stream = nil
                self.configuration = nil
            }
            throw error
        }

        // A newer stop or start may have landed while awaiting.
        if request != generation {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    @MainActor
    func stop() async {
        generation += 1
        let previous = stream
        stream = nil
        configuration = nil
        highRateRequested = false
        resetCounter()
        try? await previous?.stopCapture()
    }

    @MainActor
    func setHighRate(_ high: Bool) async {
        highRateRequested = high
        guard !rateUpdateInFlight else { return }
        rateUpdateInFlight = true
        defer { rateUpdateInFlight = false }

        // Requests can arrive mid-update; keep applying until the stream matches
        // the latest request so the rate never sticks at the wrong value.
        while let stream, let configuration {
            let wanted = highRateRequested
            configuration.minimumFrameInterval = CMTime(
                value: 1, timescale: CMTimeScale(wanted ? Self.activeRate : Self.idleRate))
            do {
                try await stream.updateConfiguration(configuration)
            } catch {
                if self.stream === stream { onFailure?(error) }
                return
            }
            if self.stream === stream && wanted == highRateRequested { return }
        }
    }

    private func resetCounter() {
        counterLock.lock()
        delivered = 0
        counterLock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.onFailure?(error)
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        // Only complete frames are usable; .idle and .blank arrive while nothing
        // on screen has changed and carry no new image.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        counterLock.lock()
        delivered += 1
        counterLock.unlock()
        onFrame?(pixelBuffer)
    }
}

/// A frame source that serves one still image forever.
///
/// Used by the settings preview and by the offline harness, so both exercise the
/// renderer without screen recording permission or a live display.
final class StillFrameSource: DesktopFrames {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let buffer: CVPixelBuffer?

    init(image: CGImage) {
        buffer = StillFrameSource.makeBuffer(from: image)
    }

    func start(displayID: CGDirectDisplayID) async throws {
        if let buffer { onFrame?(buffer) }
    }

    func stop() async {}
    func setHighRate(_ high: Bool) async {}

    /// Converts an image into a BGRA pixel buffer matching the capture format.
    private static func makeBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little).rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

enum CaptureError: LocalizedError {
    case displayUnavailable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "找不到内置显示器。"
        case .permissionDenied: return "没有屏幕录制权限。"
        }
    }
}
