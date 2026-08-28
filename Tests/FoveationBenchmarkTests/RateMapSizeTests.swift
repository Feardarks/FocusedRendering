import Metal
import XCTest
@testable import FoveationBenchmark

final class RateMapSizeTests: XCTestCase {

    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        return device
    }

    /// The rate budget must not depend on where the person is looking.
    ///
    /// Without this the physical size swings by a quarter across the screen,
    /// which would tear down and rebuild the compression session — and emit a
    /// keyframe — every time the eye moved.
    func testMeanRateIsIndependentOfGaze() {
        for profile in FoveationProfile.presets {
            let means = stride(from: Float(0.05), through: 0.95, by: 0.05).map { gaze in
                let rates = profile.rates(cells: RateMapFactory.cellsPerAxis, gaze: gaze)
                return rates.reduce(0, +) / Float(rates.count)
            }
            let spread = (means.max() ?? 0) - (means.min() ?? 0)
            XCTAssertLessThan(spread, 1e-4, "\(profile.name) spends a different budget depending on gaze")
        }
    }

    /// Metal rounds each cell independently, so the total still moves a little
    /// with the distribution and no single gaze is reliably the largest. What
    /// matters is that the allocated size bounds every position, including ones
    /// the sampling never tried.
    func testSafeSizeBoundsEveryGaze() throws {
        let device = try device()
        for profile in FoveationProfile.presets where profile != .off {
            let canonical = try RateMapFactory.safePhysicalSize(
                device: device, screenWidth: 3660, screenHeight: 3200, profile: profile
            )
            // Deliberately off the sampling grid used to pick the allocation.
            for gaze in stride(from: Float(0.02), through: 0.98, by: 0.037) {
                let size = try RateMapFactory.makeRateMap(
                    device: device, screenWidth: 3660, screenHeight: 3200,
                    profile: profile, gaze: SIMD2(gaze, 1 - gaze)
                ).physicalSize(layer: 0)

                XCTAssertLessThanOrEqual(
                    size.width, canonical.width,
                    "\(profile.name) at gaze \(gaze) is wider than the allocation"
                )
                XCTAssertLessThanOrEqual(size.height, canonical.height)
            }
        }
    }

    /// The waste from allocating at the canonical size has to stay small, or
    /// the fixed allocation costs more than the rebuilds it avoids.
    func testFixedAllocationWastesLittle() throws {
        let device = try device()
        let profile = FoveationProfile.aggressive
        let canonical = try RateMapFactory.safePhysicalSize(
            device: device, screenWidth: 3660, screenHeight: 3200, profile: profile
        )
        var smallest = canonical.width * canonical.height

        for gaze in stride(from: Float(0.05), through: 0.95, by: 0.05) {
            let size = try RateMapFactory.makeRateMap(
                device: device, screenWidth: 3660, screenHeight: 3200,
                profile: profile, gaze: SIMD2(gaze, 0.5)
            ).physicalSize(layer: 0)
            smallest = min(smallest, size.width * size.height)
        }

        let waste = 1 - Double(smallest) / Double(canonical.width * canonical.height)
        XCTAssertLessThan(waste, 0.10, "allocating at the canonical size wastes \(waste * 100)%")
    }
}
