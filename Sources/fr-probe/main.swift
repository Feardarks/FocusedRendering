import Foundation
import FoveatedStreamingProtocol
import Network

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
fr-probe — a stand-in headset for the media channel

Connects to a running fr-host --stream, consumes the video stream and reports
what arrives. Lets the host side be measured before a real device is involved.

USAGE:
  fr-probe [options]

OPTIONS:
  --host <name>    Host to connect to. Default: 127.0.0.1
  --port <n>       Media port. Default: 48011
  --seconds <n>    How long to run. Default: 10
  --sweep          Send a moving focus point, as a wearer's eyes would.
  -h, --help       Show this message.
"""

var host = "127.0.0.1"
var port: UInt16 = 48011
var seconds = 10.0
var sweep = false

var index = 0
let argv = Array(CommandLine.arguments.dropFirst())
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
    case "--host": host = value()
    case "--port": port = UInt16(value()) ?? port
    case "--seconds": seconds = Double(value()) ?? seconds
    case "--sweep": sweep = true
    default:
        FileHandle.standardError.write(Data("error: unknown option \(flag)\n\n\(usage)\n".utf8))
        exit(2)
    }
    index += 1
}

final class Probe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "fr-probe")
    private let lock = NSLock()
    private var decoder = FrameDecoder()

    private var frames = 0
    private var bytes = 0
    private var rateMaps = 0
    private var latencies: [Double] = []
    private var lastIndex: UInt64?
    private var gaps = 0
    private var started: Date?

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    func start() {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("connection failed: \(error)\n".utf8))
                exit(1)
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func sendFocus(_ update: FocusUpdate) {
        connection.send(content: MediaCodec.encode(.focus(update)), completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if error != nil { return }
            self.receive()
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        decoder.append(data)
        while let payload = try? decoder.next() {
            guard let message = try? MediaCodec.decode(payload) else { continue }
            switch message {
            case .frame(let header, let bytesIn):
                if started == nil { started = Date() }
                frames += 1
                bytes += bytesIn.count
                // Host and probe share a clock here, so this is a real
                // render-to-arrival figure rather than an estimate.
                let now = DispatchTime.now().uptimeNanoseconds
                if now > header.timestampNanoseconds {
                    latencies.append(Double(now - header.timestampNanoseconds) / 1e6)
                }
                if let last = lastIndex, header.index != last + 1 { gaps += 1 }
                lastIndex = header.index
            case .rateMap:
                rateMaps += 1
            default:
                break
            }
        }
    }

    func report() {
        lock.lock(); defer { lock.unlock() }
        guard frames > 0, let started else {
            print("no frames arrived — is fr-host running with --stream?")
            return
        }
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        let sorted = latencies.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return .nan }
            return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }

        print("")
        print(String(format: "frames        %d in %.1f s  (%.1f fps)", frames, elapsed, Double(frames) / elapsed))
        print(String(format: "bitrate       %.1f Mbps  (%.0f KB/frame)",
                     Double(bytes) * 8 / elapsed / 1e6, Double(bytes) / Double(frames) / 1024))
        print(String(format: "latency       median %.1f ms, p95 %.1f ms  (render to arrival)",
                     percentile(0.5), percentile(0.95)))
        print("rate maps     \(rateMaps)")
        print("index gaps    \(gaps)")
    }
}

let probe = Probe(host: host, port: port)
probe.start()
print("probing \(host):\(port) for \(Int(seconds)) s\(sweep ? ", sweeping focus" : "")")

/// Drives a moving focus point from a timer queue.
///
/// The state lives here rather than at file scope because top-level code is
/// main-actor isolated, and a timer handler touching it from another queue is a
/// genuine race, not a technicality.
final class FocusSweep: @unchecked Sendable {
    private let probe: Probe
    private let timer: DispatchSourceTimer
    private var tick = 0.0

    init(probe: Probe) {
        self.probe = probe
        self.timer = DispatchSource.makeTimerSource(queue: .global())
    }

    func start() {
        timer.schedule(deadline: .now() + 0.5, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // A slow circle: enough movement to exercise rate map rebuilds
            // without pretending to imitate real saccades.
            self.tick += 0.05
            self.probe.sendFocus(FocusUpdate(
                x: 0.5 + 0.3 * Float(cos(self.tick)),
                y: 0.5 + 0.3 * Float(sin(self.tick)),
                timestampNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
        }
        timer.resume()
    }

    func stop() { timer.cancel() }
}

let focusSweep = sweep ? FocusSweep(probe: probe) : nil
focusSweep?.start()
Thread.sleep(forTimeInterval: seconds)
focusSweep?.stop()

probe.report()
