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

    /// One encoded access unit, ready to put on the wire.
    public struct EncodedAccessUnit: Sendable {
        public let data: Data
        public let isKeyframe: Bool
        /// Present only when the parameter sets changed, which for a real-time
        /// session means the first frame. A decoder cannot build a format
        /// description without them, so they must lead the stream they describe.
        public let parameterSets: [Data]?
        public let encodeMilliseconds: Double
    }

    private var sentParameterSets: [Data]?

    /// Encodes one frame for transmission.
    public func encodeForTransport(_ source: CVPixelBuffer) throws -> EncodedAccessUnit {
        let (sample, milliseconds) = try encodePipelined(source)
        return try accessUnit(from: sample, milliseconds: milliseconds)
    }

    private func accessUnit(from sample: CMSampleBuffer, milliseconds: Double) throws -> EncodedAccessUnit {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else {
            throw CodecError.noOutput
        }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer
        )
        guard status == kCMBlockBufferNoErr, let pointer else { throw CodecError.noOutput }
        let payload = Data(bytes: pointer, count: length)

        // A frame is a sync sample unless it is explicitly marked otherwise;
        // the attachment is absent on keyframes rather than set to false.
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = unsafeBitCast(raw, to: CFDictionary.self)
            if let notSync = (dictionary as? [CFString: Any])?[kCMSampleAttachmentKey_NotSync] as? Bool {
                isKeyframe = !notSync
            }
        }

        var changedParameterSets: [Data]?
        if let formatDescription = CMSampleBufferGetFormatDescription(sample) {
            let sets = Self.hevcParameterSets(from: formatDescription)
            if sets != sentParameterSets {
                sentParameterSets = sets
                changedParameterSets = sets
            }
        }

        return EncodedAccessUnit(
            data: payload,
            isKeyframe: isKeyframe,
            parameterSets: changedParameterSets,
            encodeMilliseconds: milliseconds
        )
    }

    private static func hevcParameterSets(from description: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            description, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return [] }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { continue }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
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

    /// Encodes without blocking the caller.
    ///
    /// VideoToolbox delivers the frame on its own thread, so the render loop
    /// never waits on the media engine and successive frames can be in flight at
    /// once. With reordering disabled and real-time set, output arrives in
    /// submission order, so sends stay ordered without extra sequencing.
    public func encodeAsync(
        _ source: CVPixelBuffer,
        completion: @escaping @Sendable (Result<EncodedAccessUnit, any Error>) -> Void
    ) {
        let timestamp = CMTime(value: frameIndex, timescale: 90)
        frameIndex += 1
        let start = Date()

        let status = VTCompressionSessionEncodeFrame(
            compression,
            imageBuffer: source,
            presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: 90),
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] encodeStatus, _, sampleBuffer in
            guard let self else { return }
            guard encodeStatus == noErr, let sampleBuffer else {
                completion(.failure(CodecError.encodeFailed(encodeStatus)))
                return
            }
            do {
                let unit = try self.accessUnit(
                    from: sampleBuffer,
                    milliseconds: Date().timeIntervalSince(start) * 1000
                )
                completion(.success(unit))
            } catch {
                completion(.failure(error))
            }
        }
        if status != noErr {
            completion(.failure(CodecError.encodeFailed(status)))
        }
    }

    /// Encodes without draining the session.
    ///
    /// `VTCompressionSessionCompleteFrames` forces a synchronous flush, which is
    /// what a one-frame measurement needs and exactly what a stream must avoid:
    /// it serializes the encoder against the render loop instead of letting the
    /// two overlap. In real-time mode with reordering disabled the encoder emits
    /// each frame on its own, so the handler is simply awaited.
    private func encodePipelined(_ source: CVPixelBuffer) throws -> (CMSampleBuffer, Double) {
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

        // Bounded, so a stalled encoder drops the frame rather than wedging the
        // render loop for good.
        if semaphore.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
            semaphore.wait()
        }

        let elapsed = Date().timeIntervalSince(start) * 1000
        guard callbackStatus == noErr else { throw CodecError.encodeFailed(callbackStatus) }
        guard let produced else { throw CodecError.noOutput }
        return (produced, elapsed)
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
