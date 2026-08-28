import XCTest
@testable import FoveatedPipeline

final class ImageMetricsTests: XCTestCase {

    private let fovea = NormalizedRect(center: SIMD2(0.5, 0.5), size: 0.2)

    private func image(width: Int, height: Int, value: UInt8) -> CapturedImage {
        CapturedImage(
            width: width, height: height,
            pixels: [UInt8](repeating: value, count: width * height * 4)
        )
    }

    func testIdenticalImagesAreLossless() throws {
        let a = image(width: 64, height: 64, value: 128)
        let report = try ImageMetrics.compare(a, a, fovea: fovea)
        XCTAssertTrue(report.overallPSNR.isInfinite)
        XCTAssertTrue(report.fovealPSNR.isInfinite)
    }

    /// A uniform difference of 1 across every channel gives a mean squared
    /// error of exactly 1, so PSNR must land on 10·log10(255²).
    func testKnownDifferenceGivesKnownPSNR() throws {
        let reference = image(width: 32, height: 32, value: 100)
        let candidate = image(width: 32, height: 32, value: 101)
        let report = try ImageMetrics.compare(reference, candidate, fovea: fovea)
        XCTAssertEqual(report.overallPSNR, 10 * log10(255 * 255), accuracy: 1e-9)
    }

    func testMismatchedSizesAreRejected() {
        let a = image(width: 8, height: 8, value: 0)
        let b = image(width: 8, height: 9, value: 0)
        XCTAssertThrowsError(try ImageMetrics.compare(a, b, fovea: fovea))
    }

    /// The worst tile must report the damaged region, not the average, and must
    /// ignore tiles inside the fovea.
    func testWorstTileFindsLocalDamageOutsideTheFovea() throws {
        let size = 512
        let reference = image(width: size, height: size, value: 100)
        var pixels = reference.pixels

        // Corrupt one tile in the far corner, well outside the fovea.
        for y in 0..<ImageMetrics.tileSize {
            for x in 0..<ImageMetrics.tileSize {
                let index = (y * size + x) * 4
                for channel in 0..<3 { pixels[index + channel] = 160 }
            }
        }
        let candidate = CapturedImage(width: size, height: size, pixels: pixels)
        let report = try ImageMetrics.compare(reference, candidate, fovea: fovea)

        XCTAssertEqual(report.worstTileOrigin.x, 0)
        XCTAssertEqual(report.worstTileOrigin.y, 0)
        XCTAssertLessThan(
            report.worstPeripheralTilePSNR, report.peripheralPSNR,
            "a local defect must read worse than the periphery's average"
        )
        XCTAssertTrue(report.fovealPSNR.isInfinite, "the fovea was untouched")
    }

    func testFoveaRectTracksTheGaze() {
        let rect = NormalizedRect(center: SIMD2(0.25, 0.75), size: 0.2)
        XCTAssertTrue(rect.contains(x: 0.25, y: 0.75))
        XCTAssertFalse(rect.contains(x: 0.5, y: 0.5))
    }
}
