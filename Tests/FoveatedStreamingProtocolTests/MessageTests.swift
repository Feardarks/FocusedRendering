import XCTest
@testable import FoveatedStreamingProtocol

final class MessageTests: XCTestCase {

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Verbatim from Apple's protocol documentation.
    func testDecodesTheDocumentedRequestConnection() throws {
        let json = """
        {
            "Event": "RequestConnection",
            "ProtocolVersion": "1",
            "StreamingProvider": "com.nvidia.CloudXR",
            "StreamingProviderVersion": "6",
            "UserInterfaceIdiom": "Vision",
            "SessionID": "68753A444D6F12269C600050E4C00067",
            "ClientID": "a81bc81bdead4e5dabff90865d1e13b1"
        }
        """

        guard case .requestConnection(let request) = try MessageCodec.decode(Data(json.utf8)) else {
            return XCTFail("expected a RequestConnection")
        }
        XCTAssertEqual(request.protocolVersion, "1")
        XCTAssertEqual(request.streamingProvider, "com.nvidia.CloudXR")
        XCTAssertEqual(request.streamingProviderVersion, "6")
        XCTAssertEqual(request.userInterfaceIdiom, "Vision")
        XCTAssertEqual(request.sessionID, "68753A444D6F12269C600050E4C00067")
        XCTAssertEqual(request.clientID, "a81bc81bdead4e5dabff90865d1e13b1")
    }

    func testDecodesEveryDocumentedStatusValue() throws {
        for status in SessionStatus.allCases {
            let json = """
            {"Event":"SessionStatusDidChange","SessionID":"S","Status":"\(status.rawValue)"}
            """
            guard case .sessionStatusDidChange(let change) = try MessageCodec.decode(Data(json.utf8)) else {
                return XCTFail("expected a SessionStatusDidChange for \(status)")
            }
            XCTAssertEqual(change.status, status)
        }
    }

    func testKeepsUnrecognizedEventsInsteadOfFailing() throws {
        let json = #"{"Event":"SomethingFromAFutureVersion","SessionID":"S"}"#
        XCTAssertEqual(
            try MessageCodec.decode(Data(json.utf8)),
            .unknown(event: "SomethingFromAFutureVersion")
        )
    }

    func testRejectsAMessageWithoutAnEvent() {
        XCTAssertThrowsError(try MessageCodec.decode(Data(#"{"SessionID":"S"}"#.utf8)))
    }

    func testEncodesAcknowledgeConnectionWithTheEventKey() throws {
        let message = OutboundMessage.acknowledgeConnection(.init(
            sessionID: "S", serverID: "V", certificateFingerprint: "abc123"
        ))
        let encoded = try object(MessageCodec.encode(message))

        XCTAssertEqual(encoded["Event"] as? String, "AcknowledgeConnection")
        XCTAssertEqual(encoded["SessionID"] as? String, "S")
        XCTAssertEqual(encoded["ServerID"] as? String, "V")
        XCTAssertEqual(encoded["CertificateFingerprint"] as? String, "abc123")
    }

    /// Omitting the key — rather than sending null — is what asks the device to
    /// re-pair, so the distinction has to survive encoding.
    func testOmitsTheFingerprintEntirelyWhenForcingARepair() throws {
        let message = OutboundMessage.acknowledgeConnection(.init(
            sessionID: "S", serverID: "V", certificateFingerprint: nil
        ))
        let encoded = try object(MessageCodec.encode(message))

        XCTAssertFalse(encoded.keys.contains("CertificateFingerprint"))
        XCTAssertEqual(encoded["Event"] as? String, "AcknowledgeConnection")
    }

    func testEncodesTheRemainingOutboundEvents() throws {
        let cases: [(OutboundMessage, String)] = [
            (.acknowledgeBarcodePresentation(.init(sessionID: "S")), "AcknowledgeBarcodePresentation"),
            (.mediaStreamIsReady(.init(sessionID: "S")), "MediaStreamIsReady"),
            (.requestSessionDisconnect(.init(sessionID: "S")), "RequestSessionDisconnect"),
        ]
        for (message, expected) in cases {
            let encoded = try object(MessageCodec.encode(message))
            XCTAssertEqual(encoded["Event"] as? String, expected)
            XCTAssertEqual(encoded["SessionID"] as? String, "S")
        }
    }

    /// Apple's reference endpoint encodes the pairing QR with these two keys.
    func testBarcodePayloadUsesTheReferenceKeys() throws {
        let payload = BarcodePayload(clientToken: "tok", certificateFingerprint: "dig")
        let encoded = try object(payload.qrPayloadJSON())
        XCTAssertEqual(encoded.count, 2)
        XCTAssertEqual(encoded["token"] as? String, "tok")
        XCTAssertEqual(encoded["digest"] as? String, "dig")
    }
}
