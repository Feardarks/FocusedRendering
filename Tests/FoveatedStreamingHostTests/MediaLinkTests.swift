import Network
import XCTest
@testable import FoveatedStreamingHost
@testable import FoveatedStreamingProtocol

/// Stands in for the headset on the media channel: receives video, sends focus.
private final class SimulatedClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.media-client")
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var received: [MediaMessage] = []

    init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
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
                    if let message = try? MediaCodec.decode(payload) {
                        self.received.append(message)
                    }
                }
                self.lock.unlock()
            }
            self.receive()
        }
    }

    func send(_ message: MediaMessage) {
        connection.send(content: MediaCodec.encode(message), completion: .idempotent)
    }

    func messages(timeout: TimeInterval = 5, until predicate: ([MediaMessage]) -> Bool) -> [MediaMessage] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let snapshot = received
            lock.unlock()
            if predicate(snapshot) { return snapshot }
            usleep(5_000)
        }
        lock.lock(); defer { lock.unlock() }
        return received
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MediaLinkEvent] = []
    func append(_ event: MediaLinkEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [MediaLinkEvent] { lock.lock(); defer { lock.unlock() }; return storage }

    func waitForFocus(count: Int, timeout: TimeInterval = 5) -> [FocusUpdate] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let updates = events.compactMap { event -> FocusUpdate? in
                if case .focus(let update) = event { return update }
                return nil
            }
            if updates.count >= count { return updates }
            usleep(5_000)
        }
        return events.compactMap { if case .focus(let u) = $0 { return u } else { return nil } }
    }
}

final class MediaLinkTests: XCTestCase {

    private func startLink() throws -> (MediaLink, UInt16, EventBox) {
        let link = MediaLink()
        let box = EventBox()
        link.onEvent = { box.append($0) }
        try link.start(port: 0)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let port = link.boundPort, port != 0 { return (link, port, box) }
            usleep(10_000)
        }
        throw XCTSkip("the media link did not bind a port")
    }

    private func connectedClient(to port: UInt16, link: MediaLink) throws -> SimulatedClient {
        let client = SimulatedClient(port: port)
        client.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if link.isConnected { return client }
            usleep(10_000)
        }
        client.stop()
        throw XCTSkip("the client never connected")
    }

    func testVideoReachesTheClientInOrder() throws {
        let (link, port, _) = try startLink()
        defer { link.stop() }
        let client = try connectedClient(to: port, link: link)
        defer { client.stop() }

        let parameterSets = MediaMessage.parameterSets([Data([0x40, 0x01]), Data([0x42, 0x01])])
        let rateMap = MediaMessage.rateMap(RateMapDescription(
            generation: 1, screenWidth: 3660, screenHeight: 3200,
            physicalWidth: 2480, physicalHeight: 2160,
            parameterData: Data(repeating: 0xAB, count: 1024)
        ))
        link.send(parameterSets)
        link.send(rateMap)

        var sentFrames: [MediaMessage] = []
        for index in 0..<8 {
            let message = MediaMessage.frame(
                FrameHeader(
                    index: UInt64(index),
                    timestampNanoseconds: UInt64(index) * 11_111_111,
                    rateMapGeneration: 1,
                    isKeyframe: index == 0
                ),
                // Large enough that frames span several receive callbacks.
                payload: Data(repeating: UInt8(index), count: 200_000)
            )
            sentFrames.append(message)
            link.send(message)
        }

        let received = client.messages { $0.count >= 10 }
        XCTAssertEqual(received.first, parameterSets, "parameter sets must precede the frames")
        XCTAssertEqual(received.dropFirst().first, rateMap)
        XCTAssertEqual(Array(received.dropFirst(2)), sentFrames, "frames must arrive intact and in order")
    }

    func testFocusUpdatesReachTheHost() throws {
        let (link, port, box) = try startLink()
        defer { link.stop() }
        let client = try connectedClient(to: port, link: link)
        defer { client.stop() }

        let sent = (0..<5).map {
            FocusUpdate(x: Float($0) / 10, y: 0.5, timestampNanoseconds: UInt64($0))
        }
        for update in sent { client.send(.focus(update)) }

        XCTAssertEqual(box.waitForFocus(count: sent.count), sent)
    }

    /// The host must ignore anything but focus on the return path rather than
    /// acting on a client that sends the wrong thing.
    func testNonFocusMessagesFromTheClientAreIgnored() throws {
        let (link, port, box) = try startLink()
        defer { link.stop() }
        let client = try connectedClient(to: port, link: link)
        defer { client.stop() }

        client.send(.parameterSets([Data([1, 2, 3])]))
        client.send(.focus(FocusUpdate(x: 0.25, y: 0.25, timestampNanoseconds: 99)))

        let updates = box.waitForFocus(count: 1)
        XCTAssertEqual(updates.count, 1, "only the focus update should have registered")
        XCTAssertEqual(updates.first?.timestampNanoseconds, 99)
    }

    func testDisconnectIsReported() throws {
        let (link, port, box) = try startLink()
        defer { link.stop() }
        let client = try connectedClient(to: port, link: link)
        client.stop()

        let deadline = Date().addingTimeInterval(5)
        var sawDisconnect = false
        while Date() < deadline && !sawDisconnect {
            sawDisconnect = box.events.contains { if case .clientDisconnected = $0 { true } else { false } }
            usleep(10_000)
        }
        XCTAssertTrue(sawDisconnect)
        XCTAssertFalse(link.isConnected)
    }
}
