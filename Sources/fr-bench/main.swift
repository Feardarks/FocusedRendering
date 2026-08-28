import Foundation
import FoveationBenchmark

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var configuration = BenchmarkConfiguration()

    static let usage = """
    fr-bench — measures what gaze-driven foveated rendering actually saves

    Renders a fragment-bound raymarched scene with and without a Metal
    rasterization rate map, and reports real GPU time.

    USAGE:
      fr-bench [options]

    OPTIONS:
      --width <n>     Logical width.  Default: 3660 (Vision Pro, per eye)
      --height <n>    Logical height. Default: 3200
      --steps <list>  Comma-separated march-step counts. Default: 48,96,160
      --frames <n>    Measured frames per case. Default: 90
      --gaze <x,y>    Fovea centre in 0...1. Default: 0.5,0.5
      -h, --help      Show this message.
    """
}

enum OptionError: Error, CustomStringConvertible {
    case unknown(String), missing(String), bad(String, String), help
    var description: String {
        switch self {
        case .unknown(let f): "unknown option \(f)"
        case .missing(let f): "\(f) requires a value"
        case .bad(let f, let v): "\(f) cannot be \"\(v)\""
        case .help: ""
        }
    }
}

func parse(_ argv: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < argv.count {
        let flag = argv[index]
        func value() throws -> String {
            index += 1
            guard index < argv.count else { throw OptionError.missing(flag) }
            return argv[index]
        }
        switch flag {
        case "-h", "--help": throw OptionError.help
        case "--width":
            let raw = try value()
            guard let n = Int(raw), n > 0 else { throw OptionError.bad(flag, raw) }
            options.configuration.width = n
        case "--height":
            let raw = try value()
            guard let n = Int(raw), n > 0 else { throw OptionError.bad(flag, raw) }
            options.configuration.height = n
        case "--frames":
            let raw = try value()
            guard let n = Int(raw), n > 0 else { throw OptionError.bad(flag, raw) }
            options.configuration.measuredFrames = n
        case "--steps":
            let raw = try value()
            let steps = raw.split(separator: ",").compactMap { Int($0) }
            guard !steps.isEmpty, steps.allSatisfy({ $0 > 0 }) else { throw OptionError.bad(flag, raw) }
            options.configuration.marchSteps = steps
        case "--gaze":
            let raw = try value()
            let parts = raw.split(separator: ",").compactMap { Float($0) }
            guard parts.count == 2 else { throw OptionError.bad(flag, raw) }
            options.configuration.gaze = SIMD2(parts[0], parts[1])
        default: throw OptionError.unknown(flag)
        }
        index += 1
    }
    return options
}

let options: Options
do {
    options = try parse(Array(CommandLine.arguments.dropFirst()))
} catch OptionError.help {
    print(Options.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(Options.usage)\n".utf8))
    exit(2)
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let padding = String(repeating: " ", count: max(0, width - text.count))
    return right ? padding + text : text + padding
}

do {
    let benchmark = try Benchmark()
    let configuration = options.configuration

    print("GPU:        \(benchmark.deviceName)")
    print("Resolution: \(configuration.width)×\(configuration.height) "
          + "(\(String(format: "%.1f", Double(configuration.width * configuration.height) / 1e6)) Mpx logical)")
    print("Frames:     \(configuration.warmupFrames) warmup + \(configuration.measuredFrames) measured per case")
    print("Gaze:       \(configuration.gaze.x), \(configuration.gaze.y)")
    print("")

    let results = try benchmark.run(configuration)

    for steps in configuration.marchSteps {
        let group = results.filter { $0.marchSteps == steps }
        guard let baseline = group.first(where: { $0.profile == .off }) else { continue }

        print("── march steps: \(steps) "
              + String(repeating: "─", count: max(0, 46 - String(steps).count)))
        print(pad("profile", 14) + pad("phys Mpx", 11, right: true)
              + pad("pixels", 10, right: true) + pad("GPU ms", 10, right: true)
              + pad("p95 ms", 10, right: true) + pad("GPU saved", 12, right: true))

        for result in group {
            let pixelsCut = 1 - result.pixelRatio
            let timeCut = 1 - result.medianMilliseconds / baseline.medianMilliseconds
            let savedText = result.profile == .off
                ? "baseline"
                : String(format: "%.1f%%", timeCut * 100)
            print(pad(result.profile.name, 14)
                  + pad(String(format: "%.2f", Double(result.physicalPixels) / 1e6), 11, right: true)
                  + pad(result.profile == .off ? "—" : String(format: "-%.1f%%", pixelsCut * 100), 10, right: true)
                  + pad(String(format: "%.2f", result.medianMilliseconds), 10, right: true)
                  + pad(String(format: "%.2f", result.p95Milliseconds), 10, right: true)
                  + pad(savedText, 12, right: true))
        }
        print("")
    }

    print("`pixels` is how much of the frame the GPU skipped rasterizing;")
    print("`GPU saved` is how much wall-clock GPU time that actually returned.")
    print("The gap between them is the overhead foveation does not remove.")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
