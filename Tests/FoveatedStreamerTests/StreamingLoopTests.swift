import Network
import XCTest
@testable import FoveatedStreamer
@testable import FoveatedStreamingHost
@testable import FoveatedStreamingProtocol
@testable import FoveationBenchmark

/// The headset's half of the media channel, enough to check the host's half.
private final class SimulatedHeadset: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.headset")
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var messages: [MediaMessage] = []

    init(port: UInt16, secret: PairingSecret) {
        connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!,
            using: SecureTransport.parameters(secret: secret)
        )
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    func stop() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.decoder.append(data)
                while let payload = try? self.decoder.next() {
                    if let message = try? MediaCodec.decode(payload) { self.messages.append(message) }
                }
                self.lock.unlock()
            }
            self.receive()
        }
    }

    func send(_ message: MediaMessage) {
        connection.send(content: MediaCodec.encode(message), completion: .idempotent)
    }

    var snapshot: [MediaMessage] { lock.lock(); defer { lock.unlock() }; return messages }

    var frames: [(FrameHeader, Data)] {
        snapshot.compactMap { if case .frame(let h, let p) = $0 { return (h, p) } else { return nil } }
    }

    var rateMaps: [RateMapDescription] {
        snapshot.compactMap { if case .rateMap(let d) = $0 { return d } else { return nil } }
    }

    func wait(timeout: TimeInterval = 20, until predicate: (SimulatedHeadset) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(self) { return true }
            usleep(20_000)
        }
        return predicate(self)
    }
}

final class StreamingLoopTests: XCTestCase {

    private let secret = PairingSecret.random()

    private func makeStreamer() throws -> (FoveatedStreamer, MediaLink, UInt16) {
        let link = MediaLink(secret: secret)
        var configuration = StreamerConfiguration()
        // Small and cheap; this test is about the plumbing, not the pixels.
        configuration.width = 1280
        configuration.height = 720
        configuration.marchSteps = 24
        configuration.framesPerSecond = 60

        let streamer = try FoveatedStreamer(configuration: configuration, link: link)
        link.onEvent = { event in
            if case .focus(let update) = event { streamer.updateFocus(update) }
        }
        try link.start(port: 0)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let port = link.boundPort, port != 0 { return (streamer, link, port) }
            usleep(10_000)
        }
        throw XCTSkip("the media link did not bind a port")
    }

    func testStreamsFramesToAConnectedHeadset() throws {
        let (streamer, link, port) = try makeStreamer()
        defer { streamer.stop(); link.stop() }

        let headset = SimulatedHeadset(port: port, secret: secret)
        headset.start()
        defer { headset.stop() }
        XCTAssertTrue(headset.wait { _ in link.isConnected }, "never connected")

        streamer.start()
        XCTAssertTrue(headset.wait { $0.frames.count >= 10 }, "no frames arrived")

        let messages = headset.snapshot
        let firstFrameIndex = try XCTUnwrap(messages.firstIndex { if case .frame = $0 { true } else { false } })

        // A decoder cannot start without parameter sets or invert without the
        // rate map, so both have to precede the first frame.
        XCTAssertTrue(
            messages[..<firstFrameIndex].contains { if case .parameterSets = $0 { true } else { false } },
            "parameter sets must arrive before the first frame"
        )
        XCTAssertTrue(
            messages[..<firstFrameIndex].contains { if case .rateMap = $0 { true } else { false } },
            "the rate map must arrive before the first frame"
        )

        let frames = headset.frames
        XCTAssertEqual(frames.map(\.0.index), Array(0..<UInt64(frames.count)), "frames must be in order")
        XCTAssertTrue(frames[0].0.isKeyframe, "the stream must open with a keyframe")
        XCTAssertTrue(frames.allSatisfy { !$0.1.isEmpty }, "every frame must carry a payload")

        // Every frame must name a rate map the headset has actually been sent.
        let known = Set(headset.rateMaps.map(\.generation))
        XCTAssertTrue(
            frames.allSatisfy { known.contains($0.0.rateMapGeneration) },
            "a frame referenced a rate map the headset never received"
        )
    }

    func testMovingTheFocusRebuildsTheRateMap() throws {
        let (streamer, link, port) = try makeStreamer()
        defer { streamer.stop(); link.stop() }

        let headset = SimulatedHeadset(port: port, secret: secret)
        headset.start()
        defer { headset.stop() }
        XCTAssertTrue(headset.wait { _ in link.isConnected })

        streamer.start()
        XCTAssertTrue(headset.wait { $0.frames.count >= 5 })
        let generationsBefore = headset.rateMaps.count

        headset.send(.focus(FocusUpdate(x: 0.15, y: 0.8, timestampNanoseconds: 1)))

        XCTAssertTrue(
            headset.wait { $0.rateMaps.count > generationsBefore },
            "moving the focus should have produced a new rate map"
        )
        XCTAssertEqual(streamer.statistics.focusUpdatesReceived, 1)

        let latest = try XCTUnwrap(headset.rateMaps.last)
        XCTAssertFalse(latest.parameterData.isEmpty, "a rate map without parameters cannot be inverted")
        XCTAssertTrue(headset.wait { $0.frames.contains { $0.0.rateMapGeneration == latest.generation } },
                      "frames should start referencing the new map")
    }

    /// Micro-movement must not rebuild the map every frame; the client would
    /// spend its time reloading rate maps instead of decoding.
    func testTinyFocusMovementDoesNotRebuildTheRateMap() throws {
        let (streamer, link, port) = try makeStreamer()
        defer { streamer.stop(); link.stop() }

        let headset = SimulatedHeadset(port: port, secret: secret)
        headset.start()
        defer { headset.stop() }
        XCTAssertTrue(headset.wait { _ in link.isConnected })

        streamer.start()
        XCTAssertTrue(headset.wait { $0.frames.count >= 5 })
        let generationsBefore = headset.rateMaps.count

        for step in 0..<10 {
            headset.send(.focus(FocusUpdate(
                x: 0.5 + Float(step) * 0.001, y: 0.5, timestampNanoseconds: UInt64(step)
            )))
        }
        XCTAssertTrue(headset.wait { $0.frames.count >= 20 })

        XCTAssertEqual(
            headset.rateMaps.count, generationsBefore,
            "jitter below the threshold should not rebuild the map"
        )
    }
}
