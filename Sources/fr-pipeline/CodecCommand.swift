import Foundation
import FoveatedPipeline
import FoveationBenchmark

/// The fixed-bitrate comparison: same bit budget, foveated against not.
enum CodecCommand {

    static func run(
        configuration: RoundTripConfiguration,
        bitsPerSecond: Int,
        outputDirectory: URL?
    ) throws {
        let comparison = try CodecComparison()

        print("GPU:        \(comparison.deviceName)")
        print("Resolution: \(configuration.width)×\(configuration.height)")
        print("Bitrate:    \(bitsPerSecond / 1_000_000) Mbps, HEVC, real-time")
        print("Sequence:   \(configuration.frameCount) frames, first (keyframe) excluded")
        print("Gaze:       \(configuration.gaze.x), \(configuration.gaze.y)")
        print("")

        // The measured frame is the last of the sequence, so the ground truth
        // has to be rendered at that instant rather than the sequence's start.
        var referenceConfiguration = configuration
        referenceConfiguration.time = configuration.time
            + Float(max(1, configuration.frameCount) - 1) * configuration.timeStep
        let reference = try comparison.renderReference(referenceConfiguration)

        var results: [CodecComparisonResult] = []
        results.append(try comparison.measureFullRate(
            reference: reference, configuration: configuration, bitsPerSecond: bitsPerSecond
        ))
        for profile in FoveationProfile.presets where profile != .off {
            results.append(try comparison.measureFoveated(
                profile: profile, reference: reference,
                configuration: configuration, bitsPerSecond: bitsPerSecond
            ))
        }

        print(pad("path", 14) + pad("encoded", 11, right: true)
              + pad("KB/frame", 11, right: true) + pad("enc ms", 9, right: true)
              + pad("dec ms", 9, right: true) + pad("fovea", 12, right: true)
              + pad("worst tile", 12, right: true))

        for result in results {
            print(pad(result.label, 14)
                  + pad(String(format: "%.1f Mpx", Double(result.encodedPixels) / 1e6), 11, right: true)
                  + pad(String(format: "%.0f", Double(result.bytesPerFrame) / 1024), 11, right: true)
                  + pad(String(format: "%.1f", result.encodeMilliseconds), 9, right: true)
                  + pad(String(format: "%.1f", result.decodeMilliseconds), 9, right: true)
                  + pad(format(result.quality.fovealPSNR), 12, right: true)
                  + pad(format(result.quality.worstPeripheralTilePSNR), 12, right: true))

            if let outputDirectory {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let name = result.label.replacingOccurrences(of: " ", with: "-")
                try result.image.writePNG(to: outputDirectory.appendingPathComponent("codec-\(name).png"))
            }
        }

        print("")
        print("Every row got the same bit budget. The foveated rows encode fewer")
        print("pixels, so those bits go further — the question is whether that")
        print("buys back more than the resolution they gave up.")
        if let outputDirectory {
            print("")
            print("PNGs written to \(outputDirectory.path)")
        }
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let padding = String(repeating: " ", count: max(0, width - text.count))
        return right ? padding + text : text + padding
    }

    private static func format(_ value: Double) -> String {
        value.isInfinite ? "lossless" : String(format: "%.1f dB", value)
    }
}
