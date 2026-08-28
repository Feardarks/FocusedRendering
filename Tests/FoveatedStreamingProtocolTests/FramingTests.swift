import XCTest
@testable import FoveatedStreamingProtocol

final class FramingTests: XCTestCase {

    /// Apple documents this exact byte sequence, so it doubles as a conformance
    /// check on the length prefix's width, sign and endianness.
    func testMatchesDocumentedExample() throws {
        let json = #"{ "ClientID": "1234-5678-9ABC-DEF0" }"#
        let payload = Data(json.utf8)
        XCTAssertEqual(payload.count, 37, "the documented example is 0x25 bytes")

        let framed = Framing.frame(payload)
        XCTAssertEqual(Array(framed.prefix(4)), [0x25, 0x00, 0x00, 0x00])
        XCTAssertEqual(framed.count, 41)
    }

    func testRoundTripsASingleMessage() throws {
        let payload = Data(#"{"Event":"Ping"}"#.utf8)
        var decoder = FrameDecoder()
        decoder.append(Framing.frame(payload))
        XCTAssertEqual(try decoder.next(), payload)
        XCTAssertNil(try decoder.next())
    }

    func testReassemblesAcrossArbitraryChunkBoundaries() throws {
        let first = Data(#"{"Event":"One"}"#.utf8)
        let second = Data(#"{"Event":"Two"}"#.utf8)
        let stream = Framing.frame(first) + Framing.frame(second)

        // Feed one byte at a time: the decoder must not assume a chunk contains a
        // whole message, or even a whole length prefix.
        var decoder = FrameDecoder()
        var decoded: [Data] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let payload = try decoder.next() { decoded.append(payload) }
        }
        XCTAssertEqual(decoded, [first, second])
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testWaitsForTheRestOfATruncatedMessage() throws {
        let payload = Data(#"{"Event":"Partial"}"#.utf8)
        let framed = Framing.frame(payload)

        var decoder = FrameDecoder()
        decoder.append(framed.dropLast(3))
        XCTAssertNil(try decoder.next())
        decoder.append(framed.suffix(3))
        XCTAssertEqual(try decoder.next(), payload)
    }

    func testRejectsAnAbsurdLengthPrefix() {
        var decoder = FrameDecoder()
        var length = UInt32(Framing.maxMessageBytes + 1).littleEndian
        var bytes = Data()
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(
                error as? Framing.Error,
                .messageTooLarge(Framing.maxMessageBytes + 1)
            )
        }
    }
}
