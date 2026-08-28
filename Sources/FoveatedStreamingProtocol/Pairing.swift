import Foundation

/// Credentials presented in the pairing QR code.
public struct BarcodePayload: Sendable, Equatable {
    /// Token derived from the client ID, authenticating this Apple Vision Pro.
    public var clientToken: String
    /// SHA-256 fingerprint of the certificate the media stream will present.
    public var certificateFingerprint: String

    public init(clientToken: String, certificateFingerprint: String) {
        self.clientToken = clientToken
        self.certificateFingerprint = certificateFingerprint
    }

    /// The QR code's contents.
    ///
    /// Apple's reference endpoint encodes exactly these two short keys, so the
    /// spelling here is load-bearing rather than a matter of taste.
    private struct WireForm: Encodable {
        let token: String
        let digest: String
    }

    public func qrPayloadJSON() throws -> Data {
        try JSONEncoder().encode(WireForm(token: clientToken, digest: certificateFingerprint))
    }
}

/// What the endpoint knows about the session currently being negotiated.
public struct SessionInformation: Sendable, Equatable {
    public var sessionID: String
    public var clientID: String
    public var barcode: BarcodePayload?

    public init(sessionID: String, clientID: String, barcode: BarcodePayload? = nil) {
        self.sessionID = sessionID
        self.clientID = clientID
        self.barcode = barcode
    }
}
