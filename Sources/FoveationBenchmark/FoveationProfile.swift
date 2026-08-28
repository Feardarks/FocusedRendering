import Foundation

/// How aggressively rasterization rate falls off away from the gaze point.
///
/// Metal's rate map is *separable*: one rate array for columns, one for rows.
/// A truly radial fovea can't be expressed, so the high-quality region is a
/// rounded rectangle rather than a disc. Apple's own foveation works the same
/// way, so this is the shape the hardware actually supports rather than a
/// simplification made here.
public struct FoveationProfile: Sendable, Equatable {
    public var name: String
    /// Fraction of the axis kept at full quality, centred on the gaze
    /// (0.25 means the middle quarter of the screen keeps every pixel).
    public var foveaRadius: Float
    /// Rasterization rate at the far edge, where 1.0 is full resolution.
    public var peripheralQuality: Float

    public init(name: String, foveaRadius: Float, peripheralQuality: Float) {
        self.name = name
        self.foveaRadius = foveaRadius
        self.peripheralQuality = peripheralQuality
    }

    /// Quality for a cell whose centre sits `offset` away from the gaze point,
    /// measured as a fraction of the screen along one axis.
    ///
    /// A centred gaze is at most 0.5 from either edge, so the offset is scaled
    /// against that half-extent rather than the full axis. Skipping that step
    /// silently caps the falloff around two thirds of the way down and makes
    /// every profile look far weaker than it is.
    ///
    /// Falloff is smooth: a hard edge between quality levels reads as a seam
    /// even in the periphery.
    public func quality(atOffset offset: Float) -> Float {
        let distance = min(abs(offset) / 0.5, 1)
        guard distance > foveaRadius else { return 1 }
        let t = (distance - foveaRadius) / max(1 - foveaRadius, .ulpOfOne)
        let eased = t * t * (3 - 2 * t)                  // smoothstep
        return 1 + (peripheralQuality - 1) * eased
    }

    /// Rate arrays for a grid of `cells` cells, with the gaze at `gaze`
    /// (0...1 across the axis).
    ///
    /// Normalized so the mean rate — and therefore the physical size Metal
    /// derives from it — does not depend on where the gaze sits. A size that
    /// drifted with the eye would rebuild the compression session, and emit a
    /// keyframe, on every glance.
    ///
    /// An off-centre gaze puts more of the axis far away, which lowers the raw
    /// mean, so the correction blends the rates toward full quality. The budget
    /// stays fixed and the spare capacity goes to the periphery, which is
    /// strictly better than leaving it unspent.
    public func rates(cells: Int, gaze: Float) -> [Float] {
        precondition(cells > 0, "a rate axis needs at least one cell")
        let raw = rawRates(cells: cells, gaze: gaze)
        let rawMean = raw.reduce(0, +) / Float(cells)
        let target = centredMean(cells: cells)

        // Blending toward 1 is linear in the blend factor, so the factor that
        // lands exactly on the target is closed-form — and can never push a rate
        // above 1, which the API would reject.
        guard rawMean < target, rawMean < 1 else { return raw }
        let blend = (target - rawMean) / (1 - rawMean)
        return raw.map { $0 + blend * (1 - $0) }
    }

    private func rawRates(cells: Int, gaze: Float) -> [Float] {
        (0..<cells).map { index in
            let centre = (Float(index) + 0.5) / Float(cells)
            return quality(atOffset: centre - gaze)
        }
    }

    /// The mean rate for a centred gaze, which is the largest a gaze can produce
    /// and therefore the budget every other position is held to.
    private func centredMean(cells: Int) -> Float {
        let raw = rawRates(cells: cells, gaze: 0.5)
        return raw.reduce(0, +) / Float(cells)
    }

    // Progressively more aggressive presets. `off` is the baseline: no rate map
    // at all, every pixel rasterized.
    public static let off = FoveationProfile(name: "off", foveaRadius: 1, peripheralQuality: 1)
    public static let conservative = FoveationProfile(name: "conservative", foveaRadius: 0.25, peripheralQuality: 0.60)
    public static let balanced = FoveationProfile(name: "balanced", foveaRadius: 0.18, peripheralQuality: 0.45)
    public static let aggressive = FoveationProfile(name: "aggressive", foveaRadius: 0.12, peripheralQuality: 0.30)
    public static let extreme = FoveationProfile(name: "extreme", foveaRadius: 0.10, peripheralQuality: 0.20)

    public static let presets: [FoveationProfile] = [off, conservative, balanced, aggressive, extreme]
}
