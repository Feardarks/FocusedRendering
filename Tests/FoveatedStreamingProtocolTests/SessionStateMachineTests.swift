import XCTest
@testable import FoveatedStreamingProtocol

final class SessionStateMachineTests: XCTestCase {

    private let provider = "com.focusedrendering.provider"
    private let barcode = BarcodePayload(clientToken: "token", certificateFingerprint: "digest")

    private func makeMachine(
        forceRepair: Bool = false,
        knownFingerprint: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> SessionStateMachine {
        let barcode = barcode
        return SessionStateMachine(environment: SessionEnvironment(
            serverID: "server-id",
            providerIdentifier: provider,
            forceRepair: forceRepair,
            generateBarcode: { _ in barcode },
            knownFingerprint: knownFingerprint
        ))
    }

    private func connection(
        version: String = ProtocolConstants.supportedVersion,
        provider: String? = nil
    ) -> InboundMessage {
        .requestConnection(RequestConnection(
            protocolVersion: version,
            streamingProvider: provider ?? self.provider,
            streamingProviderVersion: "1",
            userInterfaceIdiom: "Vision",
            sessionID: "session-1",
            clientID: "client-1"
        ))
    }

    func testCompletesTheDocumentedHandshake() throws {
        var machine = makeMachine()

        XCTAssertEqual(machine.handle(connection()), [
            .send(.acknowledgeConnection(.init(
                sessionID: "session-1", serverID: "server-id", certificateFingerprint: nil
            )))
        ])
        XCTAssertEqual(machine.session?.clientID, "client-1")

        // The code must be on screen before the acknowledgement, because the
        // device opens its scanner as soon as the acknowledgement arrives.
        XCTAssertEqual(
            machine.handle(.requestBarcodePresentation(.init(sessionID: "session-1"))),
            [
                .presentBarcode(barcode),
                .send(.acknowledgeBarcodePresentation(.init(sessionID: "session-1"))),
            ]
        )
        XCTAssertEqual(machine.session?.barcode, barcode)

        XCTAssertEqual(
            machine.handle(.sessionStatusDidChange(.init(sessionID: "session-1", status: .waiting))),
            [.dismissBarcode, .statusChanged(.waiting)]
        )

        XCTAssertEqual(machine.mediaStreamIsReady(), [
            .send(.mediaStreamIsReady(.init(sessionID: "session-1")))
        ])

        _ = machine.handle(.sessionStatusDidChange(.init(sessionID: "session-1", status: .connecting)))
        XCTAssertEqual(
            machine.handle(.sessionStatusDidChange(.init(sessionID: "session-1", status: .connected))),
            [.dismissBarcode, .statusChanged(.connected)]
        )
        XCTAssertEqual(machine.status, .connected)
    }

    func testReplaysAKnownFingerprintToSkipPairing() {
        var machine = makeMachine(knownFingerprint: { $0 == "client-1" ? "remembered" : nil })
        XCTAssertEqual(machine.handle(connection()), [
            .send(.acknowledgeConnection(.init(
                sessionID: "session-1", serverID: "server-id", certificateFingerprint: "remembered"
            )))
        ])
    }

    func testForceRepairSuppressesTheRememberedFingerprint() {
        var machine = makeMachine(forceRepair: true, knownFingerprint: { _ in "remembered" })
        XCTAssertEqual(machine.handle(connection()), [
            .send(.acknowledgeConnection(.init(
                sessionID: "session-1", serverID: "server-id", certificateFingerprint: nil
            )))
        ])
    }

    func testRefusesAnUnsupportedProtocolVersion() {
        var machine = makeMachine()
        let actions = machine.handle(connection(version: "2"))
        XCTAssertEqual(actions.first, .send(.requestSessionDisconnect(.init(sessionID: "session-1"))))
        XCTAssertNil(machine.session)
    }

    func testRefusesAProviderItDoesNotServe() {
        var machine = makeMachine()
        let actions = machine.handle(connection(provider: "com.nvidia.CloudXR"))
        XCTAssertEqual(actions.first, .send(.requestSessionDisconnect(.init(sessionID: "session-1"))))
        XCTAssertNil(machine.session)
    }

    func testIgnoresMessagesForAnotherSession() {
        var machine = makeMachine()
        _ = machine.handle(connection())
        XCTAssertEqual(
            machine.handle(.requestBarcodePresentation(.init(sessionID: "other"))),
            [.rejected(reason: "barcode request for an unknown session")]
        )
    }

    /// Doffing the device pauses the session and drops TCP. The endpoint has to
    /// keep the session so the headset can reconnect without re-pairing.
    func testKeepsTheSessionWhenTheDeviceIsDoffed() {
        var machine = makeMachine()
        _ = machine.handle(connection())
        _ = machine.handle(.sessionStatusDidChange(.init(sessionID: "session-1", status: .paused)))

        XCTAssertEqual(machine.connectionClosed(), [])
        XCTAssertNotNil(machine.session, "a paused session survives its connection")
    }

    func testDropsTheSessionOnAnUnexpectedDisconnect() {
        var machine = makeMachine()
        _ = machine.handle(connection())
        _ = machine.handle(.sessionStatusDidChange(.init(sessionID: "session-1", status: .connected)))

        XCTAssertEqual(machine.connectionClosed(), [.sessionEnded(reason: "connection closed")])
        XCTAssertNil(machine.session)
    }

    func testDisconnectedStatusEndsTheSessionAndDismissesTheCode() {
        var machine = makeMachine()
        _ = machine.handle(connection())
        _ = machine.handle(.requestBarcodePresentation(.init(sessionID: "session-1")))

        let actions = machine.handle(
            .sessionStatusDidChange(.init(sessionID: "session-1", status: .disconnected))
        )
        XCTAssertEqual(actions, [
            .dismissBarcode,
            .statusChanged(.disconnected),
            .sessionEnded(reason: "device reported DISCONNECTED"),
        ])
        XCTAssertNil(machine.session)
    }

    func testIgnoresUnknownEvents() {
        var machine = makeMachine()
        _ = machine.handle(connection())
        XCTAssertEqual(machine.handle(.unknown(event: "Future")), [])
        XCTAssertNotNil(machine.session)
    }
}
