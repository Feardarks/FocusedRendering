import CryptoKit
import Foundation

/// The endpoint's pairing material.
///
/// The QR code carries the shared secret itself, which is what makes scanning it
/// the moment of authorization: a headset that has not seen the code cannot
/// complete the media channel's TLS handshake.
public struct PairingCredentials: Sendable {
    /// Secret backing the media channel's pre-shared key.
    public let secret: PairingSecret

    /// - Parameter seed: Stable input for key derivation. Persist it so a paired
    ///   headset keeps working across restarts; a random seed forces a re-pair.
    public init(seed: String) {
        // Derived rather than random so the endpoint keeps its identity across
        // restarts without writing the secret to disk.
        let material = SHA256.hash(data: Data("focused-rendering::\(seed)".utf8))
        self.secret = PairingSecret(key: Data(material))
    }

    /// Fingerprint published in `AcknowledgeConnection`, letting the headset
    /// recognise an endpoint it has already paired with without the secret
    /// itself appearing in the handshake.
    public var fingerprint: String { secret.digest }

    /// What the QR code encodes.
    ///
    /// One secret per endpoint rather than per client: binding a distinct key to
    /// each headset would mean the media listener could not be brought up until
    /// the control channel had identified the peer. With a single wearer and a
    /// local network that trade is not worth the complexity, but it is the
    /// reason a re-pair rotates the seed rather than one client's key.
    public func barcode(for clientID: String) -> BarcodePayload {
        BarcodePayload(clientToken: secret.hex, certificateFingerprint: fingerprint)
    }
}
