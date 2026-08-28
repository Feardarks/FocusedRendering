import Foundation

/// Encodes and decodes session-management messages.
///
/// Every message carries a discriminating `Event` key alongside its body. The
/// body types stay free of that key; the codec splices it in on the way out and
/// reads it on the way in.
public enum MessageCodec {

    public enum DecodingFailure: Error, Equatable {
        case notAnObject
        case missingEvent
    }

    private struct EventPeek: Decodable {
        let event: String
        enum CodingKeys: String, CodingKey { case event = "Event" }
    }

    private struct EventKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let event = EventKey(stringValue: "Event")!
    }

    /// Writes `body`'s keys and an `Event` key into the same JSON object.
    private struct Enveloped<Body: Encodable>: Encodable {
        let event: String
        let body: Body

        func encode(to encoder: any Encoder) throws {
            try body.encode(to: encoder)
            var container = encoder.container(keyedBy: EventKey.self)
            try container.encode(event, forKey: .event)
        }
    }

    public static func encode(_ message: OutboundMessage) throws -> Data {
        let encoder = JSONEncoder()
        // Absent optionals are omitted, which is how a nil CertificateFingerprint
        // signals "force a re-pair".
        switch message {
        case .acknowledgeConnection(let body):
            return try encoder.encode(Enveloped(event: message.eventName, body: body))
        case .acknowledgeBarcodePresentation(let body):
            return try encoder.encode(Enveloped(event: message.eventName, body: body))
        case .mediaStreamIsReady(let body):
            return try encoder.encode(Enveloped(event: message.eventName, body: body))
        case .requestSessionDisconnect(let body):
            return try encoder.encode(Enveloped(event: message.eventName, body: body))
        }
    }

    public static func decode(_ data: Data) throws -> InboundMessage {
        let decoder = JSONDecoder()
        let event: String
        do {
            event = try decoder.decode(EventPeek.self, from: data).event
        } catch {
            throw DecodingFailure.missingEvent
        }

        switch event {
        case "RequestConnection":
            return .requestConnection(try decoder.decode(RequestConnection.self, from: data))
        case "RequestBarcodePresentation":
            return .requestBarcodePresentation(try decoder.decode(RequestBarcodePresentation.self, from: data))
        case "SessionStatusDidChange":
            return .sessionStatusDidChange(try decoder.decode(SessionStatusDidChange.self, from: data))
        default:
            return .unknown(event: event)
        }
    }
}
