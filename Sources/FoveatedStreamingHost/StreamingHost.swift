import Foundation
import FoveatedStreamingProtocol
import Network

public struct StreamingHostConfiguration: Sendable {
    /// TCP port for the session-management connection. Advertised over Bonjour,
    /// so any free port works; 0 lets the system choose.
    public var port: UInt16
    /// Reverse-DNS provider identifier this endpoint serves. Must match the
    /// `StreamingProvider` the visionOS client asks for.
    public var providerIdentifier: String
    /// Bundle ID of the visionOS app permitted to connect. Advertised in the TXT
    /// record; without it Apple Vision Pro will not connect.
    public var visionOSBundleID: String
    /// Bonjour instance name shown to the device.
    public var serviceName: String
    /// Forget any remembered pairing and require a fresh QR scan.
    public var forceRepair: Bool
    /// Stable identifier for this endpoint across sessions.
    public var serverID: String

    public init(
        port: UInt16 = 48010,
        providerIdentifier: String,
        visionOSBundleID: String,
        serviceName: String = "Focused Rendering",
        forceRepair: Bool = false,
        serverID: String = UUID().uuidString
    ) {
        self.port = port
        self.providerIdentifier = providerIdentifier
        self.visionOSBundleID = visionOSBundleID
        self.serviceName = serviceName
        self.forceRepair = forceRepair
        self.serverID = serverID
    }
}

public enum HostEvent: Sendable {
    case listening(port: UInt16)
    case clientConnected
    case clientDisconnected
    case received(InboundMessage)
    case sent(OutboundMessage)
    case presentBarcode(BarcodePayload)
    case dismissBarcode
    case status(SessionStatus)
    case sessionEnded(String)
    case rejected(String)
    case failed(String)
}

/// Serves the session-management protocol over TCP and advertises it on Bonjour.
///
/// This is the whole endpoint side of pairing: discovery, handshake, QR
/// presentation and session-state tracking. The media stream is a separate
/// connection that Apple Vision Pro only opens after `MediaStreamIsReady`.
public final class StreamingHost: @unchecked Sendable {

    private let configuration: StreamingHostConfiguration
    private let credentials: DevelopmentCredentials
    private let queue = DispatchQueue(label: "com.focusedrendering.host")

    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var stateMachine: SessionStateMachine

    /// Delivered on the host's internal queue.
    public var onEvent: (@Sendable (HostEvent) -> Void)?

    public init(configuration: StreamingHostConfiguration, credentials: DevelopmentCredentials) {
        self.configuration = configuration
        self.credentials = credentials
        self.stateMachine = SessionStateMachine(environment: SessionEnvironment(
            serverID: configuration.serverID,
            providerIdentifier: configuration.providerIdentifier,
            forceRepair: configuration.forceRepair,
            generateBarcode: { clientID in credentials.barcode(for: clientID) },
            knownFingerprint: { _ in
                // No pairing store yet: every session re-pairs. Persisting the
                // last accepted fingerprint per client ID removes the QR step.
                nil
            }
        ))
    }

    public func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )

        var txt = NWTXTRecord()
        txt[ProtocolConstants.bundleIDKey] = configuration.visionOSBundleID
        listener.service = NWListener.Service(
            name: configuration.serviceName,
            type: ProtocolConstants.serviceType,
            txtRecord: txt
        )

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue ?? self.configuration.port
                self.emit(.listening(port: port))
            case .failed(let error):
                self.emit(.failed("listener failed: \(error)"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async {
            self.perform(self.stateMachine.requestDisconnect())
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// Tells Apple Vision Pro the media stream is accepting connections.
    /// Nothing connects to the stream before this is sent.
    public func signalMediaStreamReady() {
        queue.async { self.perform(self.stateMachine.mediaStreamIsReady()) }
    }

    /// The port actually bound, once listening.
    public var boundPort: UInt16? {
        queue.sync { listener?.port?.rawValue }
    }

    // MARK: - Connection handling

    private func accept(_ new: NWConnection) {
        // One session at a time; a fresh connection supersedes a stale one, which
        // is also how the device reconnects after being doffed.
        connection?.cancel()
        decoder = FrameDecoder()
        connection = new

        new.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.clientConnected)
            case .failed(let error):
                self.emit(.failed("connection failed: \(error)"))
                self.handleClose(new)
            case .cancelled:
                self.handleClose(new)
            default:
                break
            }
        }
        new.start(queue: queue)
        receive(on: new)
    }

    private func handleClose(_ closed: NWConnection) {
        guard connection === closed else { return }
        connection = nil
        emit(.clientDisconnected)
        perform(stateMachine.connectionClosed())
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.ingest(data, on: connection)
            }
            if let error {
                self.emit(.failed("receive failed: \(error)"))
                self.handleClose(connection)
                return
            }
            if isComplete {
                self.handleClose(connection)
                return
            }
            self.receive(on: connection)
        }
    }

    private func ingest(_ data: Data, on connection: NWConnection) {
        decoder.append(data)
        while true {
            let payload: Data?
            do {
                payload = try decoder.next()
            } catch {
                // A bad length prefix means the stream is desynchronized; there is
                // no way to resynchronize, so drop the connection.
                emit(.failed("framing error: \(error)"))
                connection.cancel()
                return
            }
            guard let payload else { return }

            do {
                let message = try MessageCodec.decode(payload)
                emit(.received(message))
                perform(stateMachine.handle(message))
            } catch {
                emit(.failed("could not decode message: \(error)"))
            }
        }
    }

    // MARK: - Actions

    private func perform(_ actions: [SessionAction]) {
        for action in actions {
            switch action {
            case .send(let message):
                send(message)
            case .presentBarcode(let payload):
                emit(.presentBarcode(payload))
            case .dismissBarcode:
                emit(.dismissBarcode)
            case .statusChanged(let status):
                emit(.status(status))
            case .sessionEnded(let reason):
                emit(.sessionEnded(reason))
            case .rejected(let reason):
                emit(.rejected(reason))
            }
        }
    }

    private func send(_ message: OutboundMessage) {
        guard let connection else { return }
        do {
            let framed = Framing.frame(try MessageCodec.encode(message))
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if let error { self?.emit(.failed("send failed: \(error)")) }
            })
            emit(.sent(message))
        } catch {
            emit(.failed("could not encode \(message.eventName): \(error)"))
        }
    }

    private func emit(_ event: HostEvent) {
        onEvent?(event)
    }
}

