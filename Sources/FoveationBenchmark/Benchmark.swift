import Foundation
import Metal

public struct BenchmarkResult: Sendable {
    public let profile: FoveationProfile
    public let marchSteps: Int
    /// Pixels the GPU actually rasterizes.
    public let physicalPixels: Int
    /// Pixels the scene covers in logical screen space.
    public let screenPixels: Int
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double

    public var pixelRatio: Double { Double(physicalPixels) / Double(screenPixels) }
}

public struct BenchmarkConfiguration: Sendable {
    /// Defaults to Apple Vision Pro's per-eye panel resolution.
    public var width: Int = 3660
    public var height: Int = 3200
    public var marchSteps: [Int] = [48, 96, 160]
    public var profiles: [FoveationProfile] = FoveationProfile.presets
    public var warmupFrames: Int = 20
    public var measuredFrames: Int = 90
    /// Where the fovea sits, in 0...1 screen coordinates.
    public var gaze: SIMD2<Float> = SIMD2(0.5, 0.5)

    public init() {}
}

public enum BenchmarkError: Error, CustomStringConvertible {
    case noDevice
    case textureCreationFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .noDevice: "no Metal device available"
        case .textureCreationFailed: "could not allocate the render target"
        case .encodingFailed: "could not encode the render pass"
        }
    }
}

public struct Benchmark {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState

    public var deviceName: String { device.name }

    public init(device: (any MTLDevice)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw BenchmarkError.noDevice
        }
        guard let queue = device.makeCommandQueue() else { throw BenchmarkError.noDevice }
        self.device = device
        self.queue = queue
        self.pipeline = try HeavyScene.makePipeline(device: device)
    }

    public func run(_ configuration: BenchmarkConfiguration) throws -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        for steps in configuration.marchSteps {
            for profile in configuration.profiles {
                results.append(try measure(profile: profile, steps: steps, configuration: configuration))
            }
        }
        return results
    }

    private func measure(
        profile: FoveationProfile,
        steps: Int,
        configuration: BenchmarkConfiguration
    ) throws -> BenchmarkResult {
        // The `off` baseline uses no rate map at all, so it also measures the
        // cost of having the feature switched off rather than a rate map that
        // happens to be all-ones.
        let rateMap: (any MTLRasterizationRateMap)? = profile == .off
            ? nil
            : try RateMapFactory.makeRateMap(
                device: device,
                screenWidth: configuration.width,
                screenHeight: configuration.height,
                profile: profile,
                gaze: configuration.gaze
            )

        // With a rate map the render target only needs the physical size, which
        // is where the memory and bandwidth savings come from.
        let physical = rateMap?.physicalSize(layer: 0)
            ?? MTLSize(width: configuration.width, height: configuration.height, depth: 1)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: physical.width,
            height: physical.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: textureDescriptor) else {
            throw BenchmarkError.textureCreationFailed
        }

        var samples: [Double] = []
        samples.reserveCapacity(configuration.measuredFrames)

        let total = configuration.warmupFrames + configuration.measuredFrames
        for frame in 0..<total {
            let uniforms = HeavyScene.Uniforms(
                // Animate so the scene isn't identical every frame, which would
                // let caches flatter the result.
                time: Float(frame) * 0.017,
                marchSteps: UInt32(steps)
            )

            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = target
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            passDescriptor.rasterizationRateMap = rateMap

            guard let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else { throw BenchmarkError.encodingFailed }

            // The viewport is in logical screen space; the rate map maps it down
            // to the smaller physical target.
            encoder.setViewport(MTLViewport(
                originX: 0, originY: 0,
                width: Double(configuration.width), height: Double(configuration.height),
                znear: 0, zfar: 1
            ))
            encoder.setRenderPipelineState(pipeline)
            withUnsafeBytes(of: uniforms) { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if frame >= configuration.warmupFrames {
                let elapsed = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
                if elapsed > 0 { samples.append(elapsed) }
            }
        }

        samples.sort()
        return BenchmarkResult(
            profile: profile,
            marchSteps: steps,
            physicalPixels: physical.width * physical.height,
            screenPixels: configuration.width * configuration.height,
            medianMilliseconds: percentile(samples, 0.50),
            p95Milliseconds: percentile(samples, 0.95)
        )
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }
}
