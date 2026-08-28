import Foundation

/// Little-endian binary writer for the media channel.
///
/// The control channel is JSON because Apple defines it that way. The media
/// channel is ours, carries a header per frame at 90 Hz, and is read by a
/// decoder that wants bytes — so it is packed binary instead.
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func write<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ value: Float) {
        write(value.bitPattern)
    }

    public mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    /// Length-prefixed blob, for anything whose size the reader can't infer.
    public mutating func writeBlob(_ bytes: Data) {
        write(UInt32(bytes.count))
        data.append(bytes)
    }
}

public struct ByteReader {
    private let data: Data
    private var offset: Int

    public enum Failure: Error, Equatable {
        case truncated(needed: Int, available: Int)
        case blobTooLarge(UInt32)
    }

    /// Ceiling on a single length-prefixed blob. A parameter set or an access
    /// unit is at most a few megabytes; anything larger means a desynchronized
    /// stream, and honouring the length would allocate on a peer's say-so.
    public static let maxBlobBytes: UInt32 = 64 << 20

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    private mutating func take(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw Failure.truncated(needed: count, available: remaining)
        }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    public mutating func read<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self).littleEndian }
    }

    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try read(UInt32.self))
    }

    public mutating func readBlob() throws -> Data {
        let count = try read(UInt32.self)
        guard count <= Self.maxBlobBytes else { throw Failure.blobTooLarge(count) }
        return Data(try take(Int(count)))
    }

    public mutating func readRest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }
}
