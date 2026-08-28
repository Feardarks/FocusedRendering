import Foundation

/// Wire framing for the session-management connection.
///
/// TCP has no notion of a message boundary, so each JSON payload is prefixed
/// with its length as a 4-byte unsigned little-endian integer.
public enum Framing {

    public enum Error: Swift.Error, Equatable {
        /// A length prefix exceeded ``Framing/maxMessageBytes``. Control messages
        /// are tens of bytes; anything large means a desynchronized stream, and
        /// honoring the length would mean trusting a peer-supplied allocation.
        case messageTooLarge(UInt32)
    }

    /// Generous ceiling for a control message that is normally under 200 bytes.
    public static let maxMessageBytes: UInt32 = 1 << 20

    /// Prefixes `payload` with its little-endian length.
    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + ProtocolConstants.lengthPrefixBytes)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Reassembles length-prefixed payloads from a byte stream that arrives in
/// arbitrary chunks.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete payload, or `nil` if more bytes are needed.
    public mutating func next() throws -> Data? {
        let prefix = ProtocolConstants.lengthPrefixBytes
        guard buffer.count >= prefix else { return nil }

        // Data slices can carry a non-zero startIndex, so index relative to it.
        let start = buffer.startIndex
        var length: UInt32 = 0
        for i in 0..<prefix {
            length |= UInt32(buffer[start + i]) << (8 * UInt32(i))
        }

        guard length <= Framing.maxMessageBytes else {
            throw Framing.Error.messageTooLarge(length)
        }

        let total = prefix + Int(length)
        guard buffer.count >= total else { return nil }

        let payload = buffer[(start + prefix)..<(start + total)]
        buffer.removeSubrange(start..<(start + total))
        return Data(payload)
    }

    /// Bytes buffered but not yet forming a complete message.
    public var pendingByteCount: Int { buffer.count }
}
