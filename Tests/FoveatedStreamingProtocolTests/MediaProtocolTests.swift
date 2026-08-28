import XCTest
@testable import FoveatedStreamingProtocol

final class MediaProtocolTests: XCTestCase {

    private func roundTrip(_ message: MediaMessage) throws -> MediaMessage {
        let framed = MediaCodec.encode(message)
        var decoder = FrameDecoder()
        decoder.append(framed)
        let payload = try XCTUnwrap(try decoder.next(), "the message should be one whole frame")
        return try MediaCodec.decode(payload)
    }

    func testParameterSetsSurviveTheRoundTrip() throws {
        let sets = [Data([0x40, 0x01, 0x0c]), Data([0x42, 0x01]), Data([0x44, 0x01, 0xc0, 0xf7])]
        XCTAssertEqual(try roundTrip(.parameterSets(sets)), .parameterSets(sets))
    }

    func testRateMapSurvivesTheRoundTrip() throws {
        let description = RateMapDescription(
            generation: 7,
            screenWidth: 3660, screenHeight: 3200,
            physicalWidth: 2480, physicalHeight: 2160,
            foveaRadius: 0.12, peripheralQuality: 0.3,
            gazeX: 0.375, gazeY: 0.625
        )
        XCTAssertEqual(try roundTrip(.rateMap(description)), .rateMap(description))
    }

    func testFrameSurvivesTheRoundTrip() throws {
        let header = FrameHeader(
            index: 9_007_199_254_740_993,     // beyond Double's exact range
            timestampNanoseconds: 1_724_800_000_123_456_789,
            rateMapGeneration: 42,
            isKeyframe: true
        )
        let payload = Data((0..<4096).map { UInt8($0 % 256) })
        XCTAssertEqual(try roundTrip(.frame(header, payload: payload)), .frame(header, payload: payload))
    }

    func testFocusSurvivesTheRoundTrip() throws {
        let update = FocusUpdate(x: 0.3125, y: 0.75, timestampNanoseconds: 12_345)
        XCTAssertEqual(try roundTrip(.focus(update)), .focus(update))
    }

    /// Frames arrive back to back on a stream with no boundaries of its own, so
    /// the decoder has to split them whatever the chunking looks like.
    func testMessagesSplitCorrectlyOutOfOneByteChunks() throws {
        let messages: [MediaMessage] = [
            .parameterSets([Data([1, 2, 3])]),
            .focus(FocusUpdate(x: 0.5, y: 0.5, timestampNanoseconds: 1)),
            .frame(
                FrameHeader(index: 1, timestampNanoseconds: 2, rateMapGeneration: 3, isKeyframe: false),
                payload: Data([9, 9, 9, 9])
            ),
        ]
        let stream = messages.map { MediaCodec.encode($0) }.reduce(Data(), +)

        var decoder = FrameDecoder()
        var decoded: [MediaMessage] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let payload = try decoder.next() {
                decoded.append(try MediaCodec.decode(payload))
            }
        }
        XCTAssertEqual(decoded, messages)
    }

    func testEmptyPayloadIsRejected() {
        XCTAssertThrowsError(try MediaCodec.decode(Data())) { error in
            XCTAssertEqual(error as? MediaCodec.Failure, .emptyMessage)
        }
    }

    func testUnknownTypeIsRejected() {
        XCTAssertThrowsError(try MediaCodec.decode(Data([99]))) { error in
            XCTAssertEqual(error as? MediaCodec.Failure, .unknownType(99))
        }
    }

    func testTruncatedMessageIsRejectedRatherThanGuessed() {
        // A frame header cut off mid-timestamp.
        let truncated = Data([3, 1, 0, 0, 0, 0, 0, 0, 0, 7, 7])
        XCTAssertThrowsError(try MediaCodec.decode(truncated))
    }

    /// A length prefix the sender never wrote must not become an allocation.
    func testOversizedBlobIsRefused() {
        var writer = ByteWriter()
        writer.write(UInt8(1))                       // parameterSets
        writer.write(UInt8(1))                       // one set
        writer.write(ByteReader.maxBlobBytes + 1)    // absurd length
        XCTAssertThrowsError(try MediaCodec.decode(writer.data)) { error in
            XCTAssertEqual(
                error as? ByteReader.Failure,
                .blobTooLarge(ByteReader.maxBlobBytes + 1)
            )
        }
    }

    func testFloatsSurviveExactlyRatherThanApproximately() throws {
        // Values with exact binary representations, so any drift is a real bug
        // rather than rounding.
        let update = FocusUpdate(x: 0.123456789, y: -0.987654321, timestampNanoseconds: 0)
        guard case .focus(let decoded) = try roundTrip(.focus(update)) else {
            return XCTFail("expected a focus update")
        }
        XCTAssertEqual(decoded.x.bitPattern, update.x.bitPattern)
        XCTAssertEqual(decoded.y.bitPattern, update.y.bitPattern)
    }
}
