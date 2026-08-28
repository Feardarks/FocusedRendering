import Foundation
import FoveationBenchmark
import Metal

public struct RoundTripConfiguration: Sendable {
    public var width = 3660
    public var height = 3200
    public var marchSteps = 96
    public var gaze = SIMD2<Float>(0.5, 0.5)
    /// Fixed so the reference and the foveated render draw the same instant;
    /// otherwise the comparison measures animation, not foveation.
    public var time: Float = 1.25
    /// Frames encoded before measuring, so the codec reaches steady state.
    ///
    /// The first frame of a sequence is always a keyframe and several times the
    /// size of the ones that follow. Measuring it reports an I-frame cost as if
    /// it were the stream's, and leaves the bitrate ceiling doing nothing.
    public var frameCount = 30
    /// Scene time advanced per frame, so successive frames differ and the
    /// encoder has real motion to predict.
    public var timeStep: Float = 0.016

    public init() {}
}

public struct RoundTripResult: Sendable {
    public let profile: FoveationProfile
    public let physicalPixels: Int
    public let screenPixels: Int
    public let quality: QualityReport
    public let unwarped: CapturedImage

    public var pixelRatio: Double { Double(physicalPixels) / Double(screenPixels) }
}

/// Renders a frame twice — once at full rate as a reference, once foveated —
/// then inverts the warp and measures what the round trip cost.
public struct RoundTrip {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let scenePipeline: any MTLRenderPipelineState
    private let unwarpPipeline: any MTLRenderPipelineState

    public var deviceName: String { device.name }

    public init(device: (any MTLDevice)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { throw BenchmarkError.noDevice }
        self.device = device
        self.queue = queue
        self.scenePipeline = try HeavyScene.makePipeline(device: device)
        self.unwarpPipeline = try UnwarpShader.makePipeline(device: device)
    }

    private func makeTexture(width: Int, height: Int, readable: Bool) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = readable ? .shared : .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BenchmarkError.textureCreationFailed
        }
        return texture
    }

    /// Draws the scene into `target`, foveated when `rateMap` is present.
    private func renderScene(
        into target: any MTLTexture,
        rateMap: (any MTLRasterizationRateMap)?,
        configuration: RoundTripConfiguration,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.rasterizationRateMap = rateMap

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw BenchmarkError.encodingFailed
        }
        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0,
            width: Double(configuration.width), height: Double(configuration.height),
            znear: 0, zfar: 1
        ))
        encoder.setRenderPipelineState(scenePipeline)
        var uniforms = HeavyScene.Uniforms(
            time: configuration.time,
            marchSteps: UInt32(configuration.marchSteps)
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HeavyScene.Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Expands a foveated render back to full screen resolution.
    private func unwarp(
        _ foveated: any MTLTexture,
        rateMap: any MTLRasterizationRateMap,
        into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        // The decoder in the shader reads the map's own parameter data, so the
        // inverse always matches the forward mapping exactly.
        let requirements = rateMap.parameterDataSizeAndAlign
        guard let parameterBuffer = device.makeBuffer(
            length: requirements.size, options: .storageModeShared
        ) else {
            throw BenchmarkError.textureCreationFailed
        }
        rateMap.copyParameterData(buffer: parameterBuffer, offset: 0)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw BenchmarkError.encodingFailed
        }
        encoder.setRenderPipelineState(unwarpPipeline)
        encoder.setFragmentTexture(foveated, index: 0)
        encoder.setFragmentBuffer(parameterBuffer, offset: 0, index: 0)
        var uniforms = UnwarpShader.Uniforms(
            screenSize: SIMD2(Float(target.width), Float(target.height)),
            textureSize: SIMD2(Float(foveated.width), Float(foveated.height))
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<UnwarpShader.Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Draws the scene into a caller-supplied target and waits for it.
    ///
    /// Used when the target is a Core Video buffer the encoder will read, so the
    /// render lands directly in the memory VideoToolbox picks up.
    public func renderScene(
        into target: any MTLTexture,
        rateMap: (any MTLRasterizationRateMap)?,
        configuration: RoundTripConfiguration
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw BenchmarkError.encodingFailed }
        try renderScene(into: target, rateMap: rateMap, configuration: configuration, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Submits the scene and returns without waiting for the GPU.
    ///
    /// The completion handler is what lets the next frame start rendering while
    /// this one is still being encoded; blocking here is what pins throughput to
    /// render plus encode instead of the larger of the two.
    public func renderSceneAsync(
        into target: any MTLTexture,
        rateMap: (any MTLRasterizationRateMap)?,
        configuration: RoundTripConfiguration,
        completion: @escaping @Sendable () -> Void
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw BenchmarkError.encodingFailed }
        try renderScene(into: target, rateMap: rateMap, configuration: configuration, commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { _ in completion() }
        commandBuffer.commit()
    }

    /// Inverts the warp on an arbitrary texture and reads the result back.
    public func unwarpToImage(
        _ foveated: any MTLTexture,
        rateMap: any MTLRasterizationRateMap,
        width: Int,
        height: Int
    ) throws -> CapturedImage {
        let restored = try makeTexture(width: width, height: height, readable: true)
        guard let commandBuffer = queue.makeCommandBuffer() else { throw BenchmarkError.encodingFailed }
        try unwarp(foveated, rateMap: rateMap, into: restored, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return CapturedImage.read(from: restored)
    }

    /// The full-rate render every foveated variant is measured against.
    public func renderReference(_ configuration: RoundTripConfiguration) throws -> CapturedImage {
        let target = try makeTexture(width: configuration.width, height: configuration.height, readable: true)
        guard let commandBuffer = queue.makeCommandBuffer() else { throw BenchmarkError.encodingFailed }
        try renderScene(into: target, rateMap: nil, configuration: configuration, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return CapturedImage.read(from: target)
    }

    public func run(
        profile: FoveationProfile,
        reference: CapturedImage,
        configuration: RoundTripConfiguration
    ) throws -> RoundTripResult {
        let rateMap = try RateMapFactory.makeRateMap(
            device: device,
            screenWidth: configuration.width,
            screenHeight: configuration.height,
            profile: profile,
            gaze: configuration.gaze
        )
        let physical = rateMap.physicalSize(layer: 0)

        let foveated = try makeTexture(width: physical.width, height: physical.height, readable: false)
        let restored = try makeTexture(width: configuration.width, height: configuration.height, readable: true)

        guard let commandBuffer = queue.makeCommandBuffer() else { throw BenchmarkError.encodingFailed }
        try renderScene(into: foveated, rateMap: rateMap, configuration: configuration, commandBuffer: commandBuffer)
        try unwarp(foveated, rateMap: rateMap, into: restored, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let unwarped = CapturedImage.read(from: restored)
        let fovea = NormalizedRect(center: configuration.gaze, size: profile.foveaRadius)
        let quality = try ImageMetrics.compare(reference, unwarped, fovea: fovea)

        return RoundTripResult(
            profile: profile,
            physicalPixels: physical.width * physical.height,
            screenPixels: configuration.width * configuration.height,
            quality: quality,
            unwarped: unwarped
        )
    }
}
