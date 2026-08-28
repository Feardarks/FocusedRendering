import CoreVideo
import Foundation
import FoveatedPipeline
import FoveationBenchmark
import Metal
import VideoToolbox

setvbuf(stdout, nil, _IOLBF, 0)

// Finds the sustained ceiling of the hardware encoder, which is the number that
// decides whether a 90 fps screen stream is possible at all.
//
// Measuring one frame's latency does not answer this: the media engine pipelines,
// so a frame taking 20 ms does not mean only 50 fit in a second. Frames are
// submitted as fast as the encoder accepts them and completions are counted.

struct Case {
    let label: String
    let width: Int
    let height: Int
}

let cases = [
    Case(label: "1920×1080", width: 1920, height: 1080),
    Case(label: "2560×1440", width: 2560, height: 1440),
    Case(label: "3360×1440  MVD Wide @1×", width: 3360, height: 1440),
    Case(label: "3660×3200  AVP per eye", width: 3660, height: 3200),
    Case(label: "5120×2880  MVD 5K @2×", width: 5120, height: 2880),
    Case(label: "6720×2880  MVD Wide @2×", width: 6720, height: 2880),
]

var sessionCounts = [1, 2, 4]
var seconds = 3.0
var bitrateMbps = 60

var index = 0
let argv = Array(CommandLine.arguments.dropFirst())
while index < argv.count {
    let flag = argv[index]
    func value() -> String {
        index += 1
        guard index < argv.count else { exit(2) }
        return argv[index]
    }
    switch flag {
    case "--seconds": seconds = Double(value()) ?? seconds
    case "--bitrate": bitrateMbps = Int(value()) ?? bitrateMbps
    case "--sessions": sessionCounts = value().split(separator: ",").compactMap { Int($0) }
    case "-h", "--help":
        print("fr-encbench — sustained hardware HEVC encode throughput\n\n"
              + "  --seconds <n>   measurement window per case (default 3)\n"
              + "  --bitrate <n>   Mbps (default 60)\n"
              + "  --sessions <l>  comma-separated parallel session counts (default 1,2,4)")
        exit(0)
    default: exit(2)
    }
    index += 1
}

/// Counts completions across every session without blocking submission.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private var failures = 0
    func succeed() { lock.lock(); completed += 1; lock.unlock() }
    func fail() { lock.lock(); failures += 1; lock.unlock() }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (completed, failures) }
}

func makeSession(width: Int, height: Int, bitrateMbps: Int) -> VTCompressionSession? {
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: Int32(width), height: Int32(height),
        codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: nil, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session
    ) == noErr, let session else { return nil }

    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                         value: kVTProfileLevel_HEVC_Main_AutoLevel)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                         value: NSNumber(value: bitrateMbps * 1_000_000))
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         value: NSNumber(value: 240))
    VTCompressionSessionPrepareToEncodeFrames(session)
    return session
}

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("no Metal device\n".utf8))
    exit(1)
}
let bridge = try PixelBufferBridge(device: device)
let renderer = try RoundTrip(device: device)

print("GPU:      \(device.name)")
print("Codec:    HEVC, real-time, \(bitrateMbps) Mbps")
print("Window:   \(seconds)s per case, frames submitted as fast as accepted")
print("Target:   90 fps sustained")
print("")
print("resolution                      Mpx  sessions      fps      Mpx/s   90fps?")

for testCase in cases {
    // Distinct frames so the encoder faces real motion; a repeated frame
    // compresses to almost nothing and would flatter the result.
    var pool: [CVPixelBuffer] = []
    for frame in 0..<6 {
        let buffer = try bridge.makePixelBuffer(width: testCase.width, height: testCase.height)
        let texture = try bridge.makeTexture(for: buffer)
        var configuration = RoundTripConfiguration()
        configuration.width = testCase.width
        configuration.height = testCase.height
        configuration.marchSteps = 40
        configuration.time = Float(frame) * 0.05
        try renderer.renderScene(into: texture, rateMap: nil, configuration: configuration)
        pool.append(buffer)
    }

    for count in sessionCounts {
        let sessions = (0..<count).compactMap { _ in
            makeSession(width: testCase.width, height: testCase.height, bitrateMbps: bitrateMbps)
        }
        guard sessions.count == count else {
            print("\(testCase.label)  — could not create \(count) sessions")
            continue
        }

        let counter = Counter()
        var timestamp: Int64 = 0
        let deadline = Date().addingTimeInterval(seconds)
        let start = Date()

        // Keep a bounded number of frames in flight: unbounded submission
        // measures how fast a queue fills, not how fast the engine drains it.
        let inFlight = DispatchSemaphore(value: count * 3)

        while Date() < deadline {
            for session in sessions {
                inFlight.wait()
                let buffer = pool[Int(timestamp) % pool.count]
                let time = CMTime(value: timestamp, timescale: 90)
                timestamp += 1
                let status = VTCompressionSessionEncodeFrame(
                    session, imageBuffer: buffer,
                    presentationTimeStamp: time, duration: CMTime(value: 1, timescale: 90),
                    frameProperties: nil, infoFlagsOut: nil
                ) { status, _, sample in
                    if status == noErr, sample != nil { counter.succeed() } else { counter.fail() }
                    inFlight.signal()
                }
                if status != noErr { counter.fail(); inFlight.signal() }
            }
        }
        for session in sessions {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }

        let elapsed = Date().timeIntervalSince(start)
        let (completed, failures) = counter.counts
        let fps = Double(completed) / elapsed
        let megapixels = Double(testCase.width * testCase.height) / 1e6
        let verdict = fps >= 90 ? "yes" : String(format: "%.0f%%", fps / 90 * 100)

        print(String(format: "%-30s %5.1f  %8d %8.1f %10.0f %8s",
                     (testCase.label as NSString).utf8String!, megapixels, count, fps,
                     fps * megapixels, (verdict as NSString).utf8String!)
              + (failures > 0 ? "  (\(failures) failed)" : ""))
    }
    print("")
}
