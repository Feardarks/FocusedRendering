import XCTest
@testable import FoveationBenchmark

final class FoveationProfileTests: XCTestCase {

    func testFullQualityInsideTheFovea() {
        let profile = FoveationProfile.balanced
        XCTAssertEqual(profile.quality(atOffset: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(profile.quality(atOffset: profile.foveaRadius * 0.5 * 0.99), 1, accuracy: 1e-6)
    }

    func testFallsToPeripheralQualityAtTheEdge() {
        let profile = FoveationProfile.aggressive
        // 0.5 is the far edge for a centred gaze; anything beyond saturates.
        XCTAssertEqual(profile.quality(atOffset: 0.5), profile.peripheralQuality, accuracy: 1e-5)
        XCTAssertEqual(profile.quality(atOffset: 0.9), profile.peripheralQuality, accuracy: 1e-5)
    }

    func testQualityIsMonotonicAndBounded() {
        let profile = FoveationProfile.balanced
        var previous: Float = 1
        for step in 0...100 {
            let quality = profile.quality(atOffset: Float(step) / 200)
            XCTAssertLessThanOrEqual(quality, previous + 1e-6, "quality must not rise with distance")
            XCTAssertGreaterThanOrEqual(quality, profile.peripheralQuality - 1e-6)
            XCTAssertLessThanOrEqual(quality, 1 + 1e-6)
            previous = quality
        }
    }

    func testFalloffIsSymmetric() {
        let profile = FoveationProfile.extreme
        for offset in stride(from: Float(0), through: 1, by: 0.05) {
            XCTAssertEqual(
                profile.quality(atOffset: offset),
                profile.quality(atOffset: -offset),
                accuracy: 1e-6
            )
        }
    }

    /// A visible seam in the periphery is worse than a slightly larger target,
    /// so neighbouring cells must never jump abruptly.
    func testNeighbouringCellsChangeSmoothly() {
        let rates = FoveationProfile.aggressive.rates(cells: 32, gaze: 0.5)
        for (a, b) in zip(rates, rates.dropFirst()) {
            XCTAssertLessThan(abs(a - b), 0.12, "adjacent rates jump too far")
        }
    }

    func testGazeMovesTheFovea() {
        let cells = 32
        let left = FoveationProfile.balanced.rates(cells: cells, gaze: 0.2)
        let right = FoveationProfile.balanced.rates(cells: cells, gaze: 0.8)

        let leftPeak = left.firstIndex(of: left.max()!)!
        let rightPeak = right.firstIndex(of: right.max()!)!
        XCTAssertLessThan(leftPeak, cells / 2)
        XCTAssertGreaterThan(rightPeak, cells / 2)
    }

    func testOffProfileKeepsEveryPixel() {
        XCTAssertTrue(FoveationProfile.off.rates(cells: 16, gaze: 0.5).allSatisfy { $0 == 1 })
    }

    func testPresetsGetProgressivelyMoreAggressive() {
        let working = FoveationProfile.presets.filter { $0 != .off }
        for (a, b) in zip(working, working.dropFirst()) {
            XCTAssertGreaterThan(a.peripheralQuality, b.peripheralQuality)
            XCTAssertGreaterThanOrEqual(a.foveaRadius, b.foveaRadius)
        }
    }
}
