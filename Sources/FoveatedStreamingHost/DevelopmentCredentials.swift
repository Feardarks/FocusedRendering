import CryptoKit
import Foundation
import FoveatedStreamingProtocol

/// Stand-in pairing credentials for bringing the handshake up.
///
/// The client token is stable per device so a paired headset keeps working across
/// restarts. The certificate fingerprint is a placeholder: until the media stream
/// exists there is no certificate to fingerprint, and Apple Vision Pro only
/// verifies it when it connects to the stream itself.
///
/// - Important: Replace `certificateFingerprint` with the SHA-256 digest of the
///   real TLS certificate once the media transport lands, or pairing will
///   succeed and the stream connection will then be refused.
public struct DevelopmentCredentials: Sendable {
    private let secret: SymmetricKey
    public let certificateFingerprint: String

    /// - Parameter seed: Stable secret for token derivation. Persist it so tokens
    ///   survive a restart; a random seed forces every client to re-pair.
    public init(seed: String) {
        self.secret = SymmetricKey(data: Data(SHA256.hash(data: Data(seed.utf8))))
        var hasher = SHA256()
        hasher.update(data: Data("placeholder-certificate".utf8))
        hasher.update(data: Data(seed.utf8))
        self.certificateFingerprint = Self.hex(Data(hasher.finalize()))
    }

    public func clientToken(for clientID: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(clientID.utf8), using: secret)
        return Self.hex(Data(mac))
    }

    public func barcode(for clientID: String) -> BarcodePayload {
        BarcodePayload(
            clientToken: clientToken(for: clientID),
            certificateFingerprint: certificateFingerprint
        )
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
