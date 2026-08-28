import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Frames from a Mac display, at whatever rate the display produces them.
///
/// Capturing an existing display rather than creating a virtual one keeps this
/// on public API: a virtual display needs either a private framework or a
/// DriverKit extension, and the latter is another entitlement to wait on.
public final class ScreenSource: NSObject, @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Upper bound on capture rate. The display cannot be made to produce
        /// more than its own refresh, so this only caps.
        public var framesPerSecond = 90
        public var showsCursor = true
        /// Capture width and height. Defaults to the display's own.
        public var width: Int?
        public var height: Int?

        public init() {}
    }

    public enum Failure: Error, CustomStringConvertible {
        case noDisplay
        case permissionDenied

        public var description: String {
            switch self {
            case .noDisplay: "no capturable display found"
            case .permissionDenied:
                "screen recording permission denied — grant it in System Settings › Privacy & Security › Screen Recording"
            }
        }
    }

    private let configuration: Configuration
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.focusedrendering.capture")

    /// Delivered on the capture queue.
    public var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public private(set) var captureWidth = 0
    public private(set) var captureHeight = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        super.init()
    }

    public func start() async throws {
        // Asking through CoreGraphics is what raises the system prompt. Going
        // straight to ScreenCaptureKit just fails, which for a command-line tool
        // means the person never finds out a permission was wanted.
        if !CGPreflightScreenCaptureAccess() {
            onLog?("requesting screen recording permission…")
            guard CGRequestScreenCaptureAccess() else { throw Failure.permissionDenied }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            // The only failure worth distinguishing: everything else is fatal
            // anyway, and this one has a fix the person can act on.
            throw Failure.permissionDenied
        }
        guard let display = content.displays.first else { throw Failure.noDisplay }

        let width = configuration.width ?? display.width
        let height = configuration.height ?? display.height
        captureWidth = width
        captureHeight = height

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = width
        streamConfiguration.height = height
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(configuration.framesPerSecond)
        )
        // Shallow: a deep queue trades latency for smoothness, and late video is
        // worse than dropped video here.
        streamConfiguration.queueDepth = 3

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        onLog?("capturing \(width)×\(height) at up to \(configuration.framesPerSecond) fps")
    }

    public func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }
}

extension ScreenSource: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit emits frames with no new content when nothing has
        // changed; forwarding them would encode the same picture at 90 Hz.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = unsafeBitCast(raw, to: CFDictionary.self) as? [CFString: Any]
            if let status = dictionary?[SCStreamFrameInfo.status.rawValue as CFString] as? Int,
               SCFrameStatus(rawValue: status) != .complete {
                return
            }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
