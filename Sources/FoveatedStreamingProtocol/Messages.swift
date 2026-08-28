import Foundation

/// Session status values reported by Apple Vision Pro.
///
/// Mirrors the `Status` field of `SessionStatusDidChange`.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    /// Provider is ready to connect but `MediaStreamIsReady` hasn't been sent yet.
    case waiting = "WAITING"
    /// Provider is connecting to the endpoint. Reachable from `paused`.
    case connecting = "CONNECTING"
    /// Provider is connected and streaming. Always follows `connecting`.
    case connected = "CONNECTED"
    /// Session is alive but the connection dropped, e.g. the device was doffed.
    /// Recoverable and normal — keep the endpoint running.
    case paused = "PAUSED"
    /// Session is fully disconnected. Also sent if the user cancels pairing.
    case disconnected = "DISCONNECTED"
}

public enum ProtocolConstants {
    /// The only protocol version defined by Apple to date.
    public static let supportedVersion = "1"
    /// Bonjour service the endpoint advertises so Apple Vision Pro can find it.
    public static let serviceType = "_apple-foveated-streaming._tcp"
    /// TXT record key naming the visionOS app allowed to connect.
    public static let bundleIDKey = "Application-Identifier"
    /// Bytes of the little-endian length prefix ahead of each JSON message.
    public static let lengthPrefixBytes = 4
}

// MARK: - Inbound (Apple Vision Pro to endpoint)

public struct RequestConnection: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var streamingProvider: String
    public var streamingProviderVersion: String
    public var userInterfaceIdiom: String
    public var sessionID: String
    public var clientID: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "ProtocolVersion"
        case streamingProvider = "StreamingProvider"
        case streamingProviderVersion = "StreamingProviderVersion"
        case userInterfaceIdiom = "UserInterfaceIdiom"
        case sessionID = "SessionID"
        case clientID = "ClientID"
    }
}

public struct RequestBarcodePresentation: Codable, Sendable, Equatable {
    public var sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "SessionID" }
}

public struct SessionStatusDidChange: Codable, Sendable, Equatable {
    public var sessionID: String
    public var status: SessionStatus
    enum CodingKeys: String, CodingKey {
        case sessionID = "SessionID"
        case status = "Status"
    }
}

/// A decoded message sent by Apple Vision Pro.
public enum InboundMessage: Sendable, Equatable {
    case requestConnection(RequestConnection)
    case requestBarcodePresentation(RequestBarcodePresentation)
    case sessionStatusDidChange(SessionStatusDidChange)
    /// A well-formed message whose `Event` this endpoint doesn't handle.
    case unknown(event: String)
}

// MARK: - Outbound (endpoint to Apple Vision Pro)

public struct AcknowledgeConnection: Codable, Sendable, Equatable {
    public var sessionID: String
    public var serverID: String
    /// Fingerprint presented in the pairing barcode.
    /// Omit (`nil`) to force Apple Vision Pro to re-pair.
    public var certificateFingerprint: String?

    public init(sessionID: String, serverID: String, certificateFingerprint: String?) {
        self.sessionID = sessionID
        self.serverID = serverID
        self.certificateFingerprint = certificateFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "SessionID"
        case serverID = "ServerID"
        case certificateFingerprint = "CertificateFingerprint"
    }
}

public struct AcknowledgeBarcodePresentation: Codable, Sendable, Equatable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
    enum CodingKeys: String, CodingKey { case sessionID = "SessionID" }
}

public struct MediaStreamIsReady: Codable, Sendable, Equatable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
    enum CodingKeys: String, CodingKey { case sessionID = "SessionID" }
}

public struct RequestSessionDisconnect: Codable, Sendable, Equatable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
    enum CodingKeys: String, CodingKey { case sessionID = "SessionID" }
}

public enum OutboundMessage: Sendable, Equatable {
    case acknowledgeConnection(AcknowledgeConnection)
    case acknowledgeBarcodePresentation(AcknowledgeBarcodePresentation)
    case mediaStreamIsReady(MediaStreamIsReady)
    case requestSessionDisconnect(RequestSessionDisconnect)

    public var eventName: String {
        switch self {
        case .acknowledgeConnection: "AcknowledgeConnection"
        case .acknowledgeBarcodePresentation: "AcknowledgeBarcodePresentation"
        case .mediaStreamIsReady: "MediaStreamIsReady"
        case .requestSessionDisconnect: "RequestSessionDisconnect"
        }
    }
}
