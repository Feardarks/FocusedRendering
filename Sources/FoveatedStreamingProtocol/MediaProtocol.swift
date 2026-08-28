import Foundation

/// Messages on the media channel.
///
/// The channel is bidirectional: video and the rate map that decodes it travel
/// to the headset, and the focus point travels back. Keeping the return path on
/// the same connection means the focus update cannot arrive out of order with
/// respect to the frames it will steer.
public enum MediaMessage: Sendable, Equatable {

    /// HEVC parameter sets (VPS, SPS, PPS).
    ///
    /// Sent whenever they change, and always before the first frame that needs
    /// them — the decoder cannot build a format description without them.
    case parameterSets([Data])

    /// How to rebuild the rate map needed to undo the foveation.
    ///
    /// Carries a generation number so frames can reference it without repeating
    /// it: the map only changes when the gaze moves far enough to rebuild it,
    /// while frames arrive at 90 Hz.
    case rateMap(RateMapDescription)

    case frame(FrameHeader, payload: Data)

    /// Headset to host. In M4 this is derived from head pose; the focus region
    /// replaces it later without changing the wire format.
    case focus(FocusUpdate)

    var typeCode: UInt8 {
        switch self {
        case .parameterSets: 1
        case .rateMap: 2
        case .frame: 3
        case .focus: 4
        }
    }
}

/// Everything the receiver needs to rebuild the rate map the host rendered with.
///
/// The parameters travel rather than Metal's serialized rate map, which is
/// specific to the GPU that produced it and would not be safe to replay on a
/// different device. Both ends run the same deterministic construction from the
/// same numbers, so the inverse still cannot drift from the forward mapping —
/// and it costs a handful of bytes instead of a kilobyte per rebuild.
public struct RateMapDescription: Sendable, Equatable {
    public var generation: UInt32
    public var screenWidth: UInt16
    public var screenHeight: UInt16
    /// Size of the encoded image, which the receiver renders back out to the
    /// screen size.
    public var physicalWidth: UInt16
    public var physicalHeight: UInt16
    /// Fraction of each axis held at full quality, centred on the gaze.
    public var foveaRadius: Float
    /// Rate at the far edge, where 1 is full resolution.
    public var peripheralQuality: Float
    /// Where the fovea sits, in 0...1 across the image.
    public var gazeX: Float
    public var gazeY: Float

    public init(
        generation: UInt32,
        screenWidth: UInt16, screenHeight: UInt16,
        physicalWidth: UInt16, physicalHeight: UInt16,
        foveaRadius: Float, peripheralQuality: Float,
        gazeX: Float, gazeY: Float
    ) {
        self.generation = generation
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        self.foveaRadius = foveaRadius
        self.peripheralQuality = peripheralQuality
        self.gazeX = gazeX
        self.gazeY = gazeY
    }
}

public struct FrameHeader: Sendable, Equatable {
    public var index: UInt64
    /// Host clock at render time, for end-to-end latency measurement.
    public var timestampNanoseconds: UInt64
    /// Which rate map decodes this frame.
    public var rateMapGeneration: UInt32
    public var isKeyframe: Bool

    public init(
        index: UInt64,
        timestampNanoseconds: UInt64,
        rateMapGeneration: UInt32,
        isKeyframe: Bool
    ) {
        self.index = index
        self.timestampNanoseconds = timestampNanoseconds
        self.rateMapGeneration = rateMapGeneration
        self.isKeyframe = isKeyframe
    }
}

public struct FocusUpdate: Sendable, Equatable {
    /// Where to centre the fovea, in 0...1 across the streamed image.
    public var x: Float
    public var y: Float
    /// Headset clock when the pose was sampled.
    public var timestampNanoseconds: UInt64

    public init(x: Float, y: Float, timestampNanoseconds: UInt64) {
        self.x = x
        self.y = y
        self.timestampNanoseconds = timestampNanoseconds
    }
}

public enum MediaCodec {

    public enum Failure: Error, Equatable {
        case emptyMessage
        case unknownType(UInt8)
        case malformed(String)
    }

    public static func encode(_ message: MediaMessage) -> Data {
        var writer = ByteWriter()
        writer.write(message.typeCode)

        switch message {
        case .parameterSets(let sets):
            writer.write(UInt8(min(sets.count, Int(UInt8.max))))
            for set in sets { writer.writeBlob(set) }

        case .rateMap(let description):
            writer.write(description.generation)
            writer.write(description.screenWidth)
            writer.write(description.screenHeight)
            writer.write(description.physicalWidth)
            writer.write(description.physicalHeight)
            writer.write(description.foveaRadius)
            writer.write(description.peripheralQuality)
            writer.write(description.gazeX)
            writer.write(description.gazeY)

        case .frame(let header, let payload):
            writer.write(header.index)
            writer.write(header.timestampNanoseconds)
            writer.write(header.rateMapGeneration)
            writer.write(UInt8(header.isKeyframe ? 1 : 0))
            writer.writeBlob(payload)

        case .focus(let update):
            writer.write(update.x)
            writer.write(update.y)
            writer.write(update.timestampNanoseconds)
        }

        return Framing.frame(writer.data)
    }

    public static func decode(_ payload: Data) throws -> MediaMessage {
        var reader = ByteReader(payload)
        guard reader.remaining > 0 else { throw Failure.emptyMessage }
        let type = try reader.read(UInt8.self)

        switch type {
        case 1:
            let count = try reader.read(UInt8.self)
            var sets: [Data] = []
            sets.reserveCapacity(Int(count))
            for _ in 0..<count { sets.append(try reader.readBlob()) }
            return .parameterSets(sets)

        case 2:
            return .rateMap(RateMapDescription(
                generation: try reader.read(UInt32.self),
                screenWidth: try reader.read(UInt16.self),
                screenHeight: try reader.read(UInt16.self),
                physicalWidth: try reader.read(UInt16.self),
                physicalHeight: try reader.read(UInt16.self),
                foveaRadius: try reader.readFloat(),
                peripheralQuality: try reader.readFloat(),
                gazeX: try reader.readFloat(),
                gazeY: try reader.readFloat()
            ))

        case 3:
            let header = FrameHeader(
                index: try reader.read(UInt64.self),
                timestampNanoseconds: try reader.read(UInt64.self),
                rateMapGeneration: try reader.read(UInt32.self),
                isKeyframe: try reader.read(UInt8.self) != 0
            )
            return .frame(header, payload: try reader.readBlob())

        case 4:
            return .focus(FocusUpdate(
                x: try reader.readFloat(),
                y: try reader.readFloat(),
                timestampNanoseconds: try reader.read(UInt64.self)
            ))

        default:
            throw Failure.unknownType(type)
        }
    }
}
