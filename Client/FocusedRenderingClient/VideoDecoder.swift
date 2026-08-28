import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Turns the host's HEVC access units back into pixel buffers.
///
/// The host sends parameter sets separately and ahead of the frames that need
/// them, because a decoder cannot build a format description without them.
final class VideoDecoder {

    enum Failure: Error, CustomStringConvertible {
        case noFormat
        case sessionFailed(OSStatus)
        case decodeFailed(OSStatus)

        var description: String {
            switch self {
            case .noFormat: "no parameter sets yet"
            case .sessionFailed(let status): "decompression session failed (\(status))"
            case .decodeFailed(let status): "decode failed (\(status))"
            }
        }
    }

    private var formatDescription: CMFormatDescription?
    private var session: VTDecompressionSession?

    var isReady: Bool { session != nil }

    /// Rebuilds the decoder around new parameter sets.
    func setParameterSets(_ sets: [Data]) throws {
        guard !sets.isEmpty else { return }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        // The pointers must outlive the call, so the data is copied into stable
        // allocations rather than borrowed from the incoming buffers.
        var storage: [UnsafeMutablePointer<UInt8>] = []
        defer { storage.forEach { $0.deallocate() } }

        for set in sets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            storage.append(buffer)
            pointers.append(UnsafePointer(buffer))
            sizes.append(set.count)
        }

        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointerBuffer.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw Failure.sessionFailed(status) }

        formatDescription = description
        try makeSession(for: description)
    }

    private func makeSession(for description: CMFormatDescription) throws {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw Failure.sessionFailed(status) }
        session = created
    }

    /// Decodes one access unit. Returns nil while the decoder is still warming up.
    func decode(_ payload: Data) throws -> CVPixelBuffer? {
        guard let session, let formatDescription else { throw Failure.noFormat }

        var blockBuffer: CMBlockBuffer?
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: payload.count)
        payload.copyBytes(to: bytes, count: payload.count)

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,   // frees `bytes` with the buffer
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            bytes.deallocate()
            throw Failure.decodeFailed(status)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw Failure.decodeFailed(status) }

        var decoded: CVPixelBuffer?
        let semaphore = DispatchSemaphore(value: 0)
        var callbackStatus = noErr

        status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer,
            flags: [._EnableTemporalProcessing], infoFlagsOut: nil
        ) { decodeStatus, _, imageBuffer, _, _ in
            callbackStatus = decodeStatus
            decoded = imageBuffer
            semaphore.signal()
        }
        guard status == noErr else { throw Failure.decodeFailed(status) }
        _ = semaphore.wait(timeout: .now() + .milliseconds(100))

        guard callbackStatus == noErr else { throw Failure.decodeFailed(callbackStatus) }
        return decoded
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }
}
