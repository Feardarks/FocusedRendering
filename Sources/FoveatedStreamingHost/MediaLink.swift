import Foundation
import FoveatedStreamingProtocol
import Network

public enum MediaLinkEvent: Sendable {
    case listening(port: UInt16)
    case clientConnected
    case clientDisconnected
    case focus(FocusUpdate)
    case failed(String)
}

/// The video connection, separate from session management.
///
/// Apple Vision Pro opens this only after `MediaStreamIsReady`, so the two
/// channels have different lifetimes and different shapes: the control channel
/// is JSON and idle, this one is binary and carries every frame.
public final class MediaLink: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.focusedrendering.media")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = FrameDecoder()

    /// Delivered on the link's internal queue.
    public var onEvent: (@Sendable (MediaLinkEvent) -> Void)?

    public init() {}

    public var isConnected: Bool {
        queue.sync { connection != nil }
    }

    public var boundPort: UInt16? {
        queue.sync { listener?.port?.rawValue }
    }

    public func start(port: UInt16) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Video is useless late. Let the stack drop a stalled connection rather
        // than buffer frames the headset will never show in time.
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: port) ?? .any
        )
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.listening(port: self.listener?.port?.rawValue ?? port))
            case .failed(let error):
                self.emit(.failed("media listener failed: \(error)"))
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
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    public func send(_ message: MediaMessage) {
        queue.async {
            guard let connection = self.connection else { return }
            connection.send(
                content: MediaCodec.encode(message),
                completion: .contentProcessed { [weak self] error in
                    if let error { self?.emit(.failed("media send failed: \(error)")) }
                }
            )
        }
    }

    private func accept(_ new: NWConnection) {
        connection?.cancel()
        decoder = FrameDecoder()
        connection = new

        new.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.emit(.clientConnected)
            case .failed(let error):
                self.emit(.failed("media connection failed: \(error)"))
                self.close(new)
            case .cancelled: self.close(new)
            default: break
            }
        }
        new.start(queue: queue)
        receive(on: new)
    }

    private func close(_ closed: NWConnection) {
        guard connection === closed else { return }
        connection = nil
        emit(.clientDisconnected)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.decoder.append(data)
                while true {
                    let payload: Data?
                    do {
                        payload = try self.decoder.next()
                    } catch {
                        self.emit(.failed("media framing error: \(error)"))
                        connection.cancel()
                        return
                    }
                    guard let payload else { break }

                    do {
                        // Only the focus update travels this way; anything else
                        // is a client bug rather than something to act on.
                        if case .focus(let update) = try MediaCodec.decode(payload) {
                            self.emit(.focus(update))
                        }
                    } catch {
                        self.emit(.failed("could not decode a media message: \(error)"))
                    }
                }
            }
            if let error {
                self.emit(.failed("media receive failed: \(error)"))
                self.close(connection)
                return
            }
            if isComplete {
                self.close(connection)
                return
            }
            self.receive(on: connection)
        }
    }

    private func emit(_ event: MediaLinkEvent) {
        onEvent?(event)
    }
}
