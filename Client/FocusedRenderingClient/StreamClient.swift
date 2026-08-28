import Combine
import Foundation
import FoveatedStreamingProtocol
import Network

/// The headset's end of the media channel.
///
/// Speaks the same protocol as `fr-host`: TLS keyed by the pairing secret,
/// length-prefixed binary messages in, focus points out.
@MainActor
@Observable
final class StreamClient {

    enum State: Equatable {
        case idle
        case searching
        case connecting(String)
        case streaming
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Idle"
            case .searching: "Looking for a host…"
            case .connecting(let name): "Connecting to \(name)…"
            case .streaming: "Streaming"
            case .failed(let reason): "Failed: \(reason)"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var discovered: [String] = []

    // Diagnostics, so a session can be judged without a debugger attached.
    private(set) var framesReceived = 0
    private(set) var framesDecoded = 0
    private(set) var framesPerSecond = 0.0
    private(set) var megabitsPerSecond = 0.0
    private(set) var latencyMilliseconds = 0.0
    private(set) var rateMapGenerations = 0
    private(set) var lastError: String?

    private(set) var rateMap: RateMapDescription?

    var onFrame: ((FrameHeader, Data) -> Void)?
    var onParameterSets: (([Data]) -> Void)?

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var decoder = FrameDecoder()
    private let secret: PairingSecret

    private var windowStart = Date()
    private var windowFrames = 0
    private var windowBytes = 0

    init(providerIdentifier: String = "com.focusedrendering.provider") {
        // In a paired session this comes from the QR code. Deriving it from the
        // provider identifier is the same secret by the same rule, which keeps
        // bring-up from depending on a camera.
        self.secret = PairingCredentials(seed: providerIdentifier).secret
    }

    // MARK: - Discovery

    /// Finds hosts advertising the endpoint on the local network.
    ///
    /// Typing an IP address while wearing a headset is miserable, and the host
    /// already advertises itself for the pairing handshake.
    func startBrowsing() {
        state = .searching
        let browser = NWBrowser(
            for: .bonjour(type: ProtocolConstants.serviceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discovered = results.compactMap { result in
                    if case .service(let name, _, _, _) = result.endpoint { return name }
                    return nil
                }.sorted()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Connection

    func connect(toServiceNamed name: String, mediaPort: UInt16) {
        // The advertised service is the control channel; the media channel sits
        // on its own port, which is why the host prints it.
        let endpoint = NWEndpoint.service(
            name: name, type: ProtocolConstants.serviceType, domain: "local.", interface: nil
        )
        // Resolve the service to a host, then dial the media port on it.
        resolve(endpoint) { [weak self] host in
            Task { @MainActor in
                guard let self else { return }
                guard let host else {
                    self.state = .failed("could not resolve \(name)")
                    return
                }
                self.connect(toHost: host, port: mediaPort, label: name)
            }
        }
    }

    func connect(toHost host: String, port: UInt16, label: String? = nil) {
        disconnect()
        state = .connecting(label ?? host)

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 48011,
            using: SecureTransport.parameters(secret: secret)
        )
        connection.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                switch update {
                case .ready:
                    self.state = .streaming
                    self.resetCounters()
                case .failed(let error):
                    // A handshake failure here almost always means the secret
                    // does not match, not that the network is down.
                    self.state = .failed("\(error)")
                    self.lastError = "\(error)"
                case .cancelled:
                    if case .failed = self.state {} else { self.state = .idle }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        self.connection = connection
        receive(on: connection)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        decoder = FrameDecoder()
    }

    func sendFocus(x: Float, y: Float) {
        guard let connection, case .streaming = state else { return }
        let update = FocusUpdate(
            x: min(max(x, 0), 1), y: min(max(y, 0), 1),
            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        connection.send(content: MediaCodec.encode(.focus(update)), completion: .idempotent)
    }

    // MARK: - Receiving

    /// Turns a Bonjour service name into an address.
    ///
    /// Opening a throwaway connection is the reliable way to do this with
    /// Network.framework: the resolved peer shows up on the connection's path
    /// once it is ready.
    private func resolve(_ endpoint: NWEndpoint, completion: @escaping @Sendable (String?) -> Void) {
        let probe = NWConnection(to: endpoint, using: .tcp)
        probe.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var resolved: String?
                if case .hostPort(let host, _) = probe.currentPath?.remoteEndpoint {
                    // IPv6 link-local addresses carry a zone suffix the
                    // connection initializer will not accept back.
                    resolved = "\(host)".split(separator: "%").first.map(String.init)
                }
                completion(resolved)
                probe.cancel()
            case .failed, .cancelled:
                completion(nil)
            default:
                break
            }
        }
        probe.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.ingest(data) }
                if let error {
                    self.lastError = "\(error)"
                    return
                }
                if isComplete { return }
                self.receive(on: connection)
            }
        }
    }

    private func ingest(_ data: Data) {
        decoder.append(data)
        while true {
            let payload: Data?
            do {
                payload = try decoder.next()
            } catch {
                lastError = "framing: \(error)"
                disconnect()
                return
            }
            guard let payload else { return }
            guard let message = try? MediaCodec.decode(payload) else { continue }

            switch message {
            case .parameterSets(let sets):
                onParameterSets?(sets)
            case .rateMap(let description):
                rateMap = description
                rateMapGenerations += 1
            case .frame(let header, let bytes):
                framesReceived += 1
                note(bytes: bytes.count, stamped: header.timestampNanoseconds)
                onFrame?(header, bytes)
            case .focus:
                break
            }
        }
    }

    func noteDecoded() { framesDecoded += 1 }

    private func note(bytes: Int, stamped: UInt64) {
        windowFrames += 1
        windowBytes += bytes

        // Host and headset run separate clocks, so this is only meaningful when
        // both are on the same machine. On device it is a relative figure —
        // useful for spotting drift, not for an absolute latency claim.
        let now = DispatchTime.now().uptimeNanoseconds
        if now > stamped {
            latencyMilliseconds = Double(now - stamped) / 1e6
        }

        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            framesPerSecond = Double(windowFrames) / elapsed
            megabitsPerSecond = Double(windowBytes) * 8 / elapsed / 1e6
            windowStart = Date()
            windowFrames = 0
            windowBytes = 0
        }
    }

    private func resetCounters() {
        framesReceived = 0
        framesDecoded = 0
        rateMapGenerations = 0
        windowStart = Date()
        windowFrames = 0
        windowBytes = 0
    }
}
