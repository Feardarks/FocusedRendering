import Metal

public enum RateMapError: Error, CustomStringConvertible {
    case unsupported
    case creationFailed

    public var description: String {
        switch self {
        case .unsupported:
            "this GPU cannot create a single-layer rasterization rate map"
        case .creationFailed:
            "Metal refused the rasterization rate map descriptor"
        }
    }
}

public enum RateMapFactory {

    /// Cells per axis in the rate map grid.
    ///
    /// Finer grids track the falloff curve more closely but cost more to
    /// evaluate; 32 keeps each cell around 2-3 degrees of field of view at
    /// Apple Vision Pro's per-eye resolution.
    public static let cellsPerAxis = 32

    /// A physical size large enough for any gaze with this profile.
    ///
    /// Metal rounds each cell's extent independently, so the total depends on
    /// how the rates are distributed and not only on their mean — which means no
    /// single gaze position is reliably the maximum. This samples a grid and
    /// takes the largest, then adds a granularity step of margin for the
    /// positions it did not try.
    ///
    /// Allocating render targets and the compression session against this once
    /// means neither is rebuilt when the eye moves, at the cost of a few per
    /// cent of encoded area the client ignores.
    public static func safePhysicalSize(
        device: any MTLDevice,
        screenWidth: Int,
        screenHeight: Int,
        profile: FoveationProfile
    ) throws -> MTLSize {
        var widest = 0
        var tallest = 0
        var granularity = MTLSize(width: 1, height: 1, depth: 1)

        let samples = stride(from: Float(0.05), through: 0.95, by: 0.15)
        for x in samples {
            for y in samples {
                let map = try makeRateMap(
                    device: device,
                    screenWidth: screenWidth, screenHeight: screenHeight,
                    profile: profile, gaze: SIMD2(x, y)
                )
                let size = map.physicalSize(layer: 0)
                widest = max(widest, size.width)
                tallest = max(tallest, size.height)
                granularity = map.physicalGranularity
            }
        }

        return MTLSize(
            width: widest + max(granularity.width, 1),
            height: tallest + max(granularity.height, 1),
            depth: 1
        )
    }

    public static func makeRateMap(
        device: any MTLDevice,
        screenWidth: Int,
        screenHeight: Int,
        profile: FoveationProfile,
        gaze: SIMD2<Float> = SIMD2(0.5, 0.5)
    ) throws -> any MTLRasterizationRateMap {
        guard device.supportsRasterizationRateMap(layerCount: 1) else {
            throw RateMapError.unsupported
        }

        let horizontal = profile.rates(cells: cellsPerAxis, gaze: gaze.x)
        let vertical = profile.rates(cells: cellsPerAxis, gaze: gaze.y)

        let layer = MTLRasterizationRateLayerDescriptor(
            sampleCount: MTLSize(width: horizontal.count, height: vertical.count, depth: 0)
        )
        for (index, rate) in horizontal.enumerated() { layer.horizontal[index] = rate }
        for (index, rate) in vertical.enumerated() { layer.vertical[index] = rate }

        let descriptor = MTLRasterizationRateMapDescriptor()
        descriptor.label = "foveation.\(profile.name)"
        descriptor.screenSize = MTLSize(width: screenWidth, height: screenHeight, depth: 0)
        descriptor.setLayer(layer, at: 0)

        guard let map = device.makeRasterizationRateMap(descriptor: descriptor) else {
            throw RateMapError.creationFailed
        }
        return map
    }
}
