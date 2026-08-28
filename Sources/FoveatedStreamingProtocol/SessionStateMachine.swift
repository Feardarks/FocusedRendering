import Foundation

/// Something the transport should do in response to an inbound message.
public enum SessionAction: Sendable, Equatable {
    case send(OutboundMessage)
    case presentBarcode(BarcodePayload)
    case dismissBarcode
    case statusChanged(SessionStatus)
    case sessionEnded(reason: String)
    case rejected(reason: String)
}

/// Endpoint identity and pairing lookups, injected so the state machine stays
/// free of I/O and therefore testable on its own.
public struct SessionEnvironment: Sendable {
    /// Stable UUID identifying this endpoint across sessions.
    public var serverID: String
    /// Reverse-DNS identifier of the streaming provider this endpoint serves.
    /// Apple Vision Pro names the provider it wants in `RequestConnection`.
    public var providerIdentifier: String
    /// Drop any remembered pairing and make the device scan a fresh QR code.
    public var forceRepair: Bool
    public var generateBarcode: @Sendable (_ clientID: String) -> BarcodePayload
    /// Fingerprint this client already paired with, if any.
    public var knownFingerprint: @Sendable (_ clientID: String) -> String?

    public init(
        serverID: String,
        providerIdentifier: String,
        forceRepair: Bool = false,
        generateBarcode: @escaping @Sendable (String) -> BarcodePayload,
        knownFingerprint: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.serverID = serverID
        self.providerIdentifier = providerIdentifier
        self.forceRepair = forceRepair
        self.generateBarcode = generateBarcode
        self.knownFingerprint = knownFingerprint
    }
}

/// The session-management protocol as a pure state machine.
///
/// Feed it decoded inbound messages; it returns the actions to perform. It never
/// touches the network, so the whole handshake is exercisable in unit tests.
public struct SessionStateMachine: Sendable {
    public private(set) var session: SessionInformation?
    public private(set) var status: SessionStatus?

    private let environment: SessionEnvironment

    public init(environment: SessionEnvironment) {
        self.environment = environment
    }

    public mutating func handle(_ message: InboundMessage) -> [SessionAction] {
        switch message {
        case .requestConnection(let request):
            return handleRequestConnection(request)

        case .requestBarcodePresentation(let request):
            guard let current = session, current.sessionID == request.sessionID else {
                return [.rejected(reason: "barcode request for an unknown session")]
            }
            let barcode = environment.generateBarcode(current.clientID)
            session?.barcode = barcode
            // Apple Vision Pro opens its scanner on the acknowledgement, so the
            // code has to be on screen before the acknowledgement goes out.
            return [
                .presentBarcode(barcode),
                .send(.acknowledgeBarcodePresentation(.init(sessionID: current.sessionID))),
            ]

        case .sessionStatusDidChange(let change):
            guard let current = session, current.sessionID == change.sessionID else {
                return [.rejected(reason: "status change for an unknown session")]
            }
            status = change.status
            // The QR code is dismissed on any status change, including the
            // DISCONNECTED that signals the user cancelled pairing.
            var actions: [SessionAction] = [.dismissBarcode, .statusChanged(change.status)]
            if change.status == .disconnected {
                session = nil
                actions.append(.sessionEnded(reason: "device reported DISCONNECTED"))
            }
            return actions

        case .unknown:
            // Ignored so a future protocol revision doesn't break the handshake.
            return []
        }
    }

    private mutating func handleRequestConnection(_ request: RequestConnection) -> [SessionAction] {
        guard request.protocolVersion == ProtocolConstants.supportedVersion else {
            return refuse(
                sessionID: request.sessionID,
                reason: "unsupported protocol version \(request.protocolVersion)"
            )
        }
        guard request.streamingProvider == environment.providerIdentifier else {
            return refuse(
                sessionID: request.sessionID,
                reason: "requested provider \(request.streamingProvider) is not served here"
            )
        }

        session = SessionInformation(sessionID: request.sessionID, clientID: request.clientID)
        status = nil

        // Omitting the fingerprint is how the endpoint asks for a fresh pairing.
        let fingerprint = environment.forceRepair
            ? nil
            : environment.knownFingerprint(request.clientID)

        return [.send(.acknowledgeConnection(.init(
            sessionID: request.sessionID,
            serverID: environment.serverID,
            certificateFingerprint: fingerprint
        )))]
    }

    private func refuse(sessionID: String, reason: String) -> [SessionAction] {
        [
            .send(.requestSessionDisconnect(.init(sessionID: sessionID))),
            .rejected(reason: reason),
        ]
    }

    /// Tells Apple Vision Pro the media stream is accepting connections.
    public mutating func mediaStreamIsReady() -> [SessionAction] {
        guard let current = session else { return [] }
        return [.send(.mediaStreamIsReady(.init(sessionID: current.sessionID)))]
    }

    /// Asks Apple Vision Pro to tear the session down, e.g. when the endpoint quits.
    public mutating func requestDisconnect() -> [SessionAction] {
        guard let current = session else { return [] }
        return [.send(.requestSessionDisconnect(.init(sessionID: current.sessionID)))]
    }

    /// Call when the TCP connection drops.
    ///
    /// A drop after `PAUSED` is the documented behaviour when the device is
    /// doffed, so the session is kept for the reconnect that follows.
    public mutating func connectionClosed() -> [SessionAction] {
        if status == .paused { return [] }
        guard session != nil else { return [] }
        session = nil
        return [.sessionEnded(reason: "connection closed")]
    }
}
