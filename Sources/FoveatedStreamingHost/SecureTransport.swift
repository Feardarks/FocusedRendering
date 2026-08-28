import CryptoKit
import Foundation
import Network

/// The shared secret established by scanning the pairing QR code.
///
/// The media channel is authenticated with a pre-shared key rather than a
/// certificate. Scanning the code is already the moment the person authorizes
/// this Mac, so the secret it carries is exactly the trust anchor — and a PSK
/// needs no certificate authority, no X.509 generation, and no trust store,
/// none of which would add anything between two devices one person owns.
public struct PairingSecret: Sendable, Equatable {
    public let key: Data

    public init(key: Data) {
        self.key = key
    }

    public static func random() -> PairingSecret {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return PairingSecret(key: bytes)
    }

    public init?(hex: String) {
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16)
            else { return nil }
            bytes.append(byte)
            index = next
        }
        guard !bytes.isEmpty else { return nil }
        self.key = bytes
    }

    public var hex: String {
        key.map { String(format: "%02x", $0) }.joined()
    }

    /// Published in the pairing handshake so the headset can tell one endpoint
    /// from another without the secret itself appearing there.
    public var digest: String {
        Data(SHA256.hash(data: key)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SecureTransport {

    /// Identity label sent alongside the key. Constant: there is one endpoint
    /// and one headset, so it carries no information worth varying.
    private static let identity = Data("focused-rendering".utf8)

    /// TCP parameters with TLS-PSK, for both ends of the media channel.
    ///
    /// Both sides derive the session from the same scanned secret, so this
    /// authenticates as well as encrypts: an endpoint that did not present the
    /// QR code cannot complete the handshake, and a listener will not accept a
    /// client that did not scan it.
    public static func parameters(secret: PairingSecret) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        let key = secret.key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Self.identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            options,
            key as __DispatchData,
            identity as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            options,
            tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!
        )
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Video is useless late; let the stack drop a stalled connection rather
        // than buffer frames the headset will never show in time.
        tcp.connectionTimeout = 5

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }
}
