import CoreVideo
import Foundation
import Metal

public enum PixelBufferError: Error, CustomStringConvertible {
    case allocationFailed(OSStatus)
    case textureCacheFailed(OSStatus)
    case textureCreationFailed

    public var description: String {
        switch self {
        case .allocationFailed(let status): "could not allocate a pixel buffer (\(status))"
        case .textureCacheFailed(let status): "could not create the Metal texture cache (\(status))"
        case .textureCreationFailed: "could not wrap the pixel buffer as a Metal texture"
        }
    }
}

/// Bridges Metal render targets and Core Video buffers.
///
/// VideoToolbox works in `CVPixelBuffer`s and Metal works in textures. Rather
/// than copying between them each frame, this hands out pixel buffers that a
/// Metal texture points directly at, so a render pass writes straight into what
/// the encoder will read.
public final class PixelBufferBridge {
    private let device: any MTLDevice
    private let textureCache: CVMetalTextureCache

    public init(device: any MTLDevice) throws {
        self.device = device
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw PixelBufferError.textureCacheFailed(status)
        }
        self.textureCache = cache
    }

    public func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw PixelBufferError.allocationFailed(status)
        }
        return buffer
    }

    /// A Metal texture aliasing `pixelBuffer`'s memory — no copy.
    public func makeTexture(for pixelBuffer: CVPixelBuffer) throws -> any MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &reference
        )
        guard status == kCVReturnSuccess,
              let reference,
              let texture = CVMetalTextureGetTexture(reference)
        else { throw PixelBufferError.textureCreationFailed }
        return texture
    }

    public func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
