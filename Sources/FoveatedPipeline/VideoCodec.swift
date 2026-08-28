import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum CodecError: Error, CustomStringConvertible {
    case sessionCreationFailed(OSStatus)
    case encodeFailed(OSStatus)
    case decodeFailed(OSStatus)
    case noOutput

    public var description: String {
        switch self {
        case .sessionCreationFailed(let status): "could not create a VideoToolbox session (\(status))"
        case .encodeFailed(let status): "encode failed (\(status))"
        case .decodeFailed(let status): "decode failed (\(status))"
        case .noOutput: "the codec produced no frame"
        }
    }
}

public struct CodecMeasurement: Sendable {
    public let byteCount: Int
    public let encodeMilliseconds: Double
    public let decodeMilliseconds: Double
}

/// A synchronous HEVC encode-then-decode round trip.
///
/// Configured the way a streaming endpoint would be: real-time, no frame
/// reordering, and a bitrate ceiling — so what it measures is what the link
/// would actually carry, not what an offline encoder could achieve with
/// unlimited lookahead.
public final class VideoCodec: @unchecked Sendable {
    private let compression: VTCompressionSession
    private var decompression: VTDecompressionSession?
    private var frameIndex: Int64 = 0

    public let width: Int
    public let height: Int

    public init(width: Int, height: Int, bitsPerSecond: Int) throws {
        // Video encoders want even dimensions; the rate map's physical size is
        // rounded to its own granularity and need not be.
        self.width = width - (width % 2)
        self.height = height - (height % 2)

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(self.width), height: Int32(self.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw CodecError.sessionCreationFailed(status)
        }
        self.compression = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitsPerSecond))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: 60))
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(compression)
        if let decompression { VTDecompressionSessionInvalidate(decompression) }
    }

    /// Encodes `source`, decodes the result, and writes the decoded frame back.
    public func roundTrip(_ source: CVPixelBuffer) throws -> (image: CVPixelBuffer, measurement: CodecMeasurement) {
        let (sample, encodeMilliseconds) = try encode(source)
        let (decoded, decodeMilliseconds) = try decode(sample)

        let byteCount = CMSampleBufferGetTotalSampleSize(sample)
        return (decoded, CodecMeasurement(
            byteCount: byteCount,
            encodeMilliseconds: encodeMilliseconds,
            decodeMilliseconds: decodeMilliseconds
        ))
    }

    private func encode(_ source: CVPixelBuffer) throws -> (CMSampleBuffer, Double) {
        let timestamp = CMTime(value: frameIndex, timescale: 90)
        frameIndex += 1

        let semaphore = DispatchSemaphore(value: 0)
        var produced: CMSampleBuffer?
        var callbackStatus = noErr
        let start = Date()

        let status = VTCompressionSessionEncodeFrame(
            compression,
            imageBuffer: source,
            presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: 90),
            frameProperties: nil,
            infoFlagsOut: nil
        ) { encodeStatus, _, sampleBuffer in
            callbackStatus = encodeStatus
            produced = sampleBuffer
            semaphore.signal()
        }
        guard status == noErr else { throw CodecError.encodeFailed(status) }

        // Real-time mode still buffers, so drain before waiting or the semaphore
        // never fires for the final frame.
        VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
        semaphore.wait()

        let elapsed = Date().timeIntervalSince(start) * 1000
        guard callbackStatus == noErr else { throw CodecError.encodeFailed(callbackStatus) }
        guard let produced else { throw CodecError.noOutput }
        return (produced, elapsed)
    }

    private func decode(_ sample: CMSampleBuffer) throws -> (CVPixelBuffer, Double) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sample) else {
            throw CodecError.noOutput
        }
        if decompression == nil {
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ] as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            guard status == noErr, let session else {
                throw CodecError.sessionCreationFailed(status)
            }
            decompression = session
        }
        guard let decompression else { throw CodecError.noOutput }

        let semaphore = DispatchSemaphore(value: 0)
        var produced: CVPixelBuffer?
        var callbackStatus = noErr
        let start = Date()

        let status = VTDecompressionSessionDecodeFrame(
            decompression,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { decodeStatus, _, imageBuffer, _, _ in
            callbackStatus = decodeStatus
            produced = imageBuffer
            semaphore.signal()
        }
        guard status == noErr else { throw CodecError.decodeFailed(status) }
        VTDecompressionSessionWaitForAsynchronousFrames(decompression)
        semaphore.wait()

        let elapsed = Date().timeIntervalSince(start) * 1000
        guard callbackStatus == noErr else { throw CodecError.decodeFailed(callbackStatus) }
        guard let produced else { throw CodecError.noOutput }
        return (produced, elapsed)
    }
}
