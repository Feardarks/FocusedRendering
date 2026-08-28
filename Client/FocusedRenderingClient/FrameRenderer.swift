import CoreVideo
import Foundation
import FoveatedStreamingProtocol
import FoveationBenchmark
import Metal
import Observation
import RealityKit

/// Expands a decoded, foveated frame back to full screen resolution.
///
/// The rate map is rebuilt here from the parameters the host sent rather than
/// replayed from its serialized form, which is specific to the GPU that made it.
/// Both ends run the same construction from the same numbers, so the inverse
/// still matches the forward mapping exactly.
@MainActor
@Observable
final class FrameRenderer {

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private(set) var output: LowLevelTexture?
    private(set) var textureResource: TextureResource?

    /// Cached because rebuilding it per frame would allocate at 90 Hz for a map
    /// that only changes when the gaze moves past the host's threshold.
    private var cachedMap: (any MTLRasterizationRateMap)?
    private var cachedGeneration: UInt32?
    private var parameterBuffer: (any MTLBuffer)?

    /// Surfaced for diagnostics: if this disagrees with what the host sent, the
    /// two devices rounded the rate map differently and the image will be
    /// subtly misaligned.
    private(set) var localPhysicalSize: SIMD2<Int> = .zero
    private(set) var hostPhysicalSize: SIMD2<Int> = .zero
    private(set) var lastError: String?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { throw RendererError.noDevice }
        self.device = device
        self.queue = queue
        self.pipeline = try UnwarpShader.makePipeline(device: device)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    enum RendererError: Error, CustomStringConvertible {
        case noDevice
        case textureFailed
        var description: String {
            switch self {
            case .noDevice: "no Metal device"
            case .textureFailed: "could not wrap the decoded frame as a texture"
            }
        }
    }

    /// Unwarps `frame` into the output texture, sizing it on first use.
    func render(_ frame: CVPixelBuffer, using description: RateMapDescription) {
        do {
            try prepareOutput(width: Int(description.screenWidth), height: Int(description.screenHeight))
            let map = try rateMap(for: description)
            guard let output, let parameterBuffer else { return }

            guard let cache = textureCache else { throw RendererError.textureFailed }
            var reference: CVMetalTexture?
            let width = CVPixelBufferGetWidth(frame)
            let height = CVPixelBufferGetHeight(frame)
            guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, frame, nil,
                .bgra8Unorm, width, height, 0, &reference
            ) == kCVReturnSuccess,
                let reference,
                let source = CVMetalTextureGetTexture(reference)
            else { throw RendererError.textureFailed }

            hostPhysicalSize = SIMD2(Int(description.physicalWidth), Int(description.physicalHeight))
            let physical = map.physicalSize(layer: 0)
            localPhysicalSize = SIMD2(physical.width, physical.height)

            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let target = output.replace(using: commandBuffer)

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBuffer(parameterBuffer, offset: 0, index: 0)
            var uniforms = UnwarpShader.Uniforms(
                screenSize: SIMD2(Float(target.width), Float(target.height)),
                // The decoded frame is the host's allocation, which is larger
                // than the rate map's own region for every gaze but one.
                textureSize: SIMD2(Float(width), Float(height))
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<UnwarpShader.Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.commit()

            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    private func prepareOutput(width: Int, height: Int) throws {
        if let output, output.descriptor.width == width, output.descriptor.height == height { return }

        var descriptor = LowLevelTexture.Descriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.textureUsage = [.renderTarget, .shaderRead]

        let texture = try LowLevelTexture(descriptor: descriptor)
        output = texture
        textureResource = try TextureResource(from: texture)
    }

    private func rateMap(for description: RateMapDescription) throws -> any MTLRasterizationRateMap {
        if let cachedMap, cachedGeneration == description.generation { return cachedMap }

        let profile = FoveationProfile(
            name: "remote",
            foveaRadius: description.foveaRadius,
            peripheralQuality: description.peripheralQuality
        )
        let map = try RateMapFactory.makeRateMap(
            device: device,
            screenWidth: Int(description.screenWidth),
            screenHeight: Int(description.screenHeight),
            profile: profile,
            gaze: SIMD2(description.gazeX, description.gazeY)
        )

        // The shader reads the map's own parameter data, so the inverse cannot
        // drift from the forward mapping.
        let requirements = map.parameterDataSizeAndAlign
        let buffer = device.makeBuffer(length: requirements.size, options: .storageModeShared)
        if let buffer { map.copyParameterData(buffer: buffer, offset: 0) }

        cachedMap = map
        cachedGeneration = description.generation
        parameterBuffer = buffer
        return map
    }
}
