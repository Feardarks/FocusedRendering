import CoreVideo
import Foundation
import FoveationBenchmark
import Metal

public struct CodecComparisonResult: Sendable {
    public let label: String
    public let profile: FoveationProfile?
    public let encodedPixels: Int
    public let screenPixels: Int
    public let bytesPerFrame: Int
    public let encodeMilliseconds: Double
    public let decodeMilliseconds: Double
    public let quality: QualityReport
    public let image: CapturedImage
}

/// Runs the two arrangements that actually decide whether this is worth doing:
/// a full-rate render through the codec, and a foveated render through the same
/// codec at the same bitrate.
///
/// Comparing them at a fixed bitrate is the point. The foveated frame carries
/// fewer pixels, so the same bit budget buys more bits per pixel — and whether
/// that outweighs the resolution it gave up is not something you can reason your
/// way to.
public struct CodecComparison {
    private let roundTrip: RoundTrip
    private let device: any MTLDevice
    private let bridge: PixelBufferBridge

    public var deviceName: String { device.name }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BenchmarkError.noDevice }
        self.device = device
        self.roundTrip = try RoundTrip(device: device)
        self.bridge = try PixelBufferBridge(device: device)
    }

    public func renderReference(_ configuration: RoundTripConfiguration) throws -> CapturedImage {
        try roundTrip.renderReference(configuration)
    }

    /// Full-rate render, encoded and decoded. No foveation anywhere.
    public func measureFullRate(
        reference: CapturedImage,
        configuration: RoundTripConfiguration,
        bitsPerSecond: Int
    ) throws -> CodecComparisonResult {
        let codec = try VideoCodec(
            width: configuration.width, height: configuration.height,
            bitsPerSecond: bitsPerSecond
        )
        let source = try bridge.makePixelBuffer(width: codec.width, height: codec.height)
        let target = try bridge.makeTexture(for: source)

        let run = try driveSequence(configuration: configuration) { frameConfiguration in
            try roundTrip.renderScene(into: target, rateMap: nil, configuration: frameConfiguration)
            return try codec.roundTrip(source)
        }
        let image = CapturedImage.read(from: run.lastFrame)
        let measurement = run.steadyState

        // Compare on the codec's even dimensions so the two paths are judged on
        // exactly the same pixels.
        let cropped = try crop(reference, to: image)
        let fovea = NormalizedRect(center: configuration.gaze, size: FoveationProfile.balanced.foveaRadius)

        return CodecComparisonResult(
            label: "full rate",
            profile: nil,
            encodedPixels: codec.width * codec.height,
            screenPixels: configuration.width * configuration.height,
            bytesPerFrame: measurement.byteCount,
            encodeMilliseconds: measurement.encodeMilliseconds,
            decodeMilliseconds: measurement.decodeMilliseconds,
            quality: try ImageMetrics.compare(cropped, image, fovea: fovea),
            image: image
        )
    }

    /// Foveated render, encoded and decoded at the same bitrate, then unwarped.
    public func measureFoveated(
        profile: FoveationProfile,
        reference: CapturedImage,
        configuration: RoundTripConfiguration,
        bitsPerSecond: Int
    ) throws -> CodecComparisonResult {
        let rateMap = try RateMapFactory.makeRateMap(
            device: device,
            screenWidth: configuration.width,
            screenHeight: configuration.height,
            profile: profile,
            gaze: configuration.gaze
        )
        let physical = rateMap.physicalSize(layer: 0)

        let codec = try VideoCodec(
            width: physical.width, height: physical.height,
            bitsPerSecond: bitsPerSecond
        )
        let source = try bridge.makePixelBuffer(width: codec.width, height: codec.height)
        let foveatedTexture = try bridge.makeTexture(for: source)

        let run = try driveSequence(configuration: configuration) { frameConfiguration in
            try roundTrip.renderScene(
                into: foveatedTexture, rateMap: rateMap, configuration: frameConfiguration
            )
            return try codec.roundTrip(source)
        }
        let measurement = run.steadyState

        // Unwarp what actually came back from the decoder, so the measurement
        // includes compression artifacts being stretched by the inverse warp.
        let decodedTexture = try bridge.makeTexture(for: run.lastFrame)
        let restored = try roundTrip.unwarpToImage(
            decodedTexture,
            rateMap: rateMap,
            width: configuration.width,
            height: configuration.height
        )

        let cropped = try crop(reference, to: restored)
        let fovea = NormalizedRect(center: configuration.gaze, size: profile.foveaRadius)

        return CodecComparisonResult(
            label: profile.name,
            profile: profile,
            encodedPixels: codec.width * codec.height,
            screenPixels: configuration.width * configuration.height,
            bytesPerFrame: measurement.byteCount,
            encodeMilliseconds: measurement.encodeMilliseconds,
            decodeMilliseconds: measurement.decodeMilliseconds,
            quality: try ImageMetrics.compare(cropped, restored, fovea: fovea),
            image: restored
        )
    }

    private struct SequenceRun {
        let lastFrame: CVPixelBuffer
        let steadyState: CodecMeasurement
    }

    /// Encodes a short animated sequence and reports the steady state.
    ///
    /// The opening keyframe is excluded: it is several times the size of the
    /// frames that follow, and averaging it in reports a cost the stream never
    /// sustains while leaving the bitrate ceiling untested.
    private func driveSequence(
        configuration: RoundTripConfiguration,
        frame: (RoundTripConfiguration) throws -> (image: CVPixelBuffer, measurement: CodecMeasurement)
    ) throws -> SequenceRun {
        var last: CVPixelBuffer?
        var bytes: [Int] = []
        var encodeTimes: [Double] = []
        var decodeTimes: [Double] = []

        for index in 0..<max(1, configuration.frameCount) {
            var frameConfiguration = configuration
            frameConfiguration.time = configuration.time + Float(index) * configuration.timeStep

            let (image, measurement) = try frame(frameConfiguration)
            last = image
            if index > 0 {
                bytes.append(measurement.byteCount)
                encodeTimes.append(measurement.encodeMilliseconds)
                decodeTimes.append(measurement.decodeMilliseconds)
            }
        }

        guard let last else { throw CodecError.noOutput }
        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        return SequenceRun(
            lastFrame: last,
            steadyState: CodecMeasurement(
                byteCount: bytes.isEmpty ? 0 : bytes.reduce(0, +) / bytes.count,
                encodeMilliseconds: mean(encodeTimes),
                decodeMilliseconds: mean(decodeTimes)
            )
        )
    }

    private func crop(_ image: CapturedImage, to target: CapturedImage) throws -> CapturedImage {
        guard image.width != target.width || image.height != target.height else { return image }
        guard image.width >= target.width, image.height >= target.height else {
            throw MetricsError.sizeMismatch
        }
        var pixels = [UInt8](repeating: 0, count: target.width * target.height * 4)
        for y in 0..<target.height {
            let sourceStart = (y * image.width) * 4
            let destinationStart = (y * target.width) * 4
            pixels.replaceSubrange(
                destinationStart..<(destinationStart + target.width * 4),
                with: image.pixels[sourceStart..<(sourceStart + target.width * 4)]
            )
        }
        return CapturedImage(width: target.width, height: target.height, pixels: pixels)
    }
}
