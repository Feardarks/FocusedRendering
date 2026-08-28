import Foundation
import FoveatedPipeline
import FoveationBenchmark

setvbuf(stdout, nil, _IOLBF, 0)

var configuration = RoundTripConfiguration()
var outputDirectory: URL?
var bitsPerSecond: Int?
var index = 0
let argv = Array(CommandLine.arguments.dropFirst())

let usage = """
fr-pipeline — foveated render, inverse warp, and what the round trip costs

Renders a frame at full rate as a reference, renders it again through a
rasterization rate map, inverts the warp, and reports PSNR inside and outside
the full-rate region.

USAGE:
  fr-pipeline [options]

OPTIONS:
  --width <n>     Logical width.  Default: 3660
  --height <n>    Logical height. Default: 3200
  --steps <n>     March steps. Default: 96
  --gaze <x,y>    Fovea centre in 0...1. Default: 0.5,0.5
  --out <dir>     Write reference and unwarped PNGs here.
  --bitrate <n>   Run the codec comparison instead, at n Mbps.
                  Encodes each path through real-time HEVC at the same
                  budget and reports what survives.
  -h, --help      Show this message.
"""

while index < argv.count {
    let flag = argv[index]
    func value() -> String {
        index += 1
        guard index < argv.count else {
            FileHandle.standardError.write(Data("error: \(flag) requires a value\n".utf8))
            exit(2)
        }
        return argv[index]
    }
    switch flag {
    case "-h", "--help": print(usage); exit(0)
    case "--width": configuration.width = Int(value()) ?? configuration.width
    case "--height": configuration.height = Int(value()) ?? configuration.height
    case "--steps": configuration.marchSteps = Int(value()) ?? configuration.marchSteps
    case "--out": outputDirectory = URL(fileURLWithPath: value())
    case "--bitrate":
        let raw = value()
        guard let megabits = Int(raw), megabits > 0 else {
            FileHandle.standardError.write(Data("error: --bitrate cannot be \"\(raw)\"\n".utf8))
            exit(2)
        }
        bitsPerSecond = megabits * 1_000_000
    case "--gaze":
        let parts = value().split(separator: ",").compactMap { Float($0) }
        if parts.count == 2 { configuration.gaze = SIMD2(parts[0], parts[1]) }
    default:
        FileHandle.standardError.write(Data("error: unknown option \(flag)\n\n\(usage)\n".utf8))
        exit(2)
    }
    index += 1
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let padding = String(repeating: " ", count: max(0, width - text.count))
    return right ? padding + text : text + padding
}

func format(_ value: Double) -> String {
    value.isInfinite ? "lossless" : String(format: "%.1f dB", value)
}

if let bitsPerSecond {
    do {
        try CodecCommand.run(
            configuration: configuration,
            bitsPerSecond: bitsPerSecond,
            outputDirectory: outputDirectory
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

do {
    let roundTrip = try RoundTrip()
    print("GPU:        \(roundTrip.deviceName)")
    print("Resolution: \(configuration.width)×\(configuration.height)")
    print("Gaze:       \(configuration.gaze.x), \(configuration.gaze.y)")
    print("")

    let reference = try roundTrip.renderReference(configuration)
    if let outputDirectory {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try reference.writePNG(to: outputDirectory.appendingPathComponent("reference.png"))
    }

    print(pad("profile", 14) + pad("pixels", 10, right: true)
          + pad("fovea", 13, right: true) + pad("periphery", 13, right: true)
          + pad("worst tile", 13, right: true) + pad("at", 14, right: true))

    for profile in FoveationProfile.presets where profile != .off {
        let result = try roundTrip.run(profile: profile, reference: reference, configuration: configuration)
        let origin = result.quality.worstTileOrigin
        print(pad(profile.name, 14)
              + pad(String(format: "-%.1f%%", (1 - result.pixelRatio) * 100), 10, right: true)
              + pad(format(result.quality.fovealPSNR), 13, right: true)
              + pad(format(result.quality.peripheralPSNR), 13, right: true)
              + pad(format(result.quality.worstPeripheralTilePSNR), 13, right: true)
              + pad("\(origin.x),\(origin.y)", 14, right: true))

        if let outputDirectory {
            try result.unwarped.writePNG(
                to: outputDirectory.appendingPathComponent("unwarped-\(profile.name).png")
            )
        }
    }

    print("")
    print("The fovea column has to hold: it covers the region rendered at full")
    print("density, so a low number there means the inverse warp is wrong rather")
    print("than that foveation is working.")
    print("")
    print("`periphery` averages across mostly-untouched background and runs high.")
    print("`worst tile` is the \(ImageMetrics.tileSize)px square that suffered most, which is where")
    print("an artifact would actually be visible.")
    if let outputDirectory {
        print("")
        print("PNGs written to \(outputDirectory.path)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
