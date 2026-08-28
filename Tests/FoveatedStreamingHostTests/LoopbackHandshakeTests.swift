import Network
import XCTest
@testable import FoveatedStreamingHost
@testable import FoveatedStreamingProtocol

/// Drives the real host over a real TCP socket, standing in for Apple Vision Pro.
///
/// Everything above the socket is the shipping code path, so this covers the
/// framing, the codec and the state machine wired together — the part that can
/// only otherwise be checked with the headset in hand.
private final class SimulatedVisionPro: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.simulated-device")
    private var decoder = FrameDecoder()
    private let lock = NSLock()
    private var received: [[String: Any]] = []

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.decoder.append(data)
                while let payload = try? self.decoder.next() {
                    if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                        self.received.append(object)
                    }
                }
                self.lock.unlock()
            }
            self.receive()
        }
    }

    func send(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        connection.send(content: Framing.frame(payload), completion: .idempotent)
    }

    /// Waits for a message with the given `Event`, polling so the test doesn't
    /// depend on how the host schedules its replies.
    func awaitEvent(_ event: String, timeout: TimeInterval = 5) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let match = received.first { $0["Event"] as? String == event }
            lock.unlock()
            if let match { return match }
            usleep(10_000)
        }
        return nil
    }
}

final class LoopbackHandshakeTests: XCTestCase {

    private let provider = "com.focusedrendering.test"
    private let sessionID = "68753A444D6F12269C600050E4C00067"
    private let clientID = "a81bc81bdead4e5dabff90865d1e13b1"

    private func startHost(
        forceRepair: Bool = false
    ) throws -> (StreamingHost, UInt16, @Sendable () -> [HostEvent]) {
        let configuration = StreamingHostConfiguration(
            port: 0, // ephemeral, so concurrent test runs don't collide
            providerIdentifier: provider,
            visionOSBundleID: "com.example.client",
            serviceName: "Focused Rendering Test \(UUID().uuidString.prefix(8))",
            forceRepair: forceRepair
        )
        let host = StreamingHost(
            configuration: configuration,
            credentials: PairingCredentials(seed: "test-seed")
        )

        let box = EventBox()
        host.onEvent = { box.append($0) }
        try host.start()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let port = host.boundPort, port != 0 { return (host, port, { box.events }) }
            usleep(10_000)
        }
        throw XCTSkip("host did not bind a port")
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HostEvent] = []
        func append(_ event: HostEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }
        var events: [HostEvent] {
            lock.lock(); defer { lock.unlock() }; return storage
        }
    }

    private func requestConnection(version: String = "1", provider: String) -> [String: Any] {
        [
            "Event": "RequestConnection",
            "ProtocolVersion": version,
            "StreamingProvider": provider,
            "StreamingProviderVersion": "1",
            "UserInterfaceIdiom": "Vision",
            "SessionID": sessionID,
            "ClientID": clientID,
        ]
    }

    func testFullPairingHandshakeOverTCP() throws {
        let (host, port, events) = try startHost(forceRepair: true)
        defer { host.stop() }

        let device = SimulatedVisionPro(port: port)
        device.start()
        defer { device.stop() }

        try device.send(requestConnection(provider: provider))

        let ack = try XCTUnwrap(device.awaitEvent("AcknowledgeConnection"), "no AcknowledgeConnection")
        XCTAssertEqual(ack["SessionID"] as? String, sessionID)
        XCTAssertNotNil(ack["ServerID"] as? String)
        XCTAssertNil(ack["CertificateFingerprint"], "force-repair must omit the fingerprint")

        try device.send(["Event": "RequestBarcodePresentation", "SessionID": sessionID])
        let barcodeAck = try XCTUnwrap(
            device.awaitEvent("AcknowledgeBarcodePresentation"),
            "no AcknowledgeBarcodePresentation"
        )
        XCTAssertEqual(barcodeAck["SessionID"] as? String, sessionID)

        let presented = events().contains { if case .presentBarcode = $0 { true } else { false } }
        XCTAssertTrue(presented, "the host should have been asked to show a QR code")

        try device.send([
            "Event": "SessionStatusDidChange", "SessionID": sessionID, "Status": "WAITING",
        ])
        host.signalMediaStreamReady()

        let ready = try XCTUnwrap(device.awaitEvent("MediaStreamIsReady"), "no MediaStreamIsReady")
        XCTAssertEqual(ready["SessionID"] as? String, sessionID)
    }

    func testRefusesAProviderTheEndpointDoesNotServe() throws {
        let (host, port, _) = try startHost()
        defer { host.stop() }

        let device = SimulatedVisionPro(port: port)
        device.start()
        defer { device.stop() }

        try device.send(requestConnection(provider: "com.nvidia.CloudXR"))

        let disconnect = try XCTUnwrap(
            device.awaitEvent("RequestSessionDisconnect"),
            "a mismatched provider should be refused"
        )
        XCTAssertEqual(disconnect["SessionID"] as? String, sessionID)
        XCTAssertNil(device.awaitEvent("AcknowledgeConnection", timeout: 0.3))
    }

    func testRefusesAnUnsupportedProtocolVersion() throws {
        let (host, port, _) = try startHost()
        defer { host.stop() }

        let device = SimulatedVisionPro(port: port)
        device.start()
        defer { device.stop() }

        try device.send(requestConnection(version: "99", provider: provider))
        XCTAssertNotNil(device.awaitEvent("RequestSessionDisconnect"))
    }
}
