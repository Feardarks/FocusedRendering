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
