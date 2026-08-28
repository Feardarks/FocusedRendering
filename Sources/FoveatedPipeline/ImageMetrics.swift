import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// An 8-bit BGRA image read back from the GPU.
public struct CapturedImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]   // BGRA, 4 bytes per pixel

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public static func read(from texture: any MTLTexture) -> CapturedImage {
        let width = texture.width
        let height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return CapturedImage(width: width, height: height, pixels: pixels)
    }

    public func writePNG(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue
        var data = pixels
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { throw MetricsError.imageCreationFailed }
        data.removeAll()

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw MetricsError.imageCreationFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MetricsError.imageCreationFailed
        }
    }
}

public enum MetricsError: Error, CustomStringConvertible {
    case sizeMismatch
    case imageCreationFailed
    public var description: String {
        switch self {
        case .sizeMismatch: "the two images are different sizes"
        case .imageCreationFailed: "could not build a PNG"
        }
    }
}

/// A rectangle in normalized 0...1 image coordinates.
public struct NormalizedRect: Sendable {
    public var minX, minY, maxX, maxY: Float

    public init(center: SIMD2<Float>, size: Float) {
        let half = size / 2
        minX = center.x - half
        maxX = center.x + half
        minY = center.y - half
        maxY = center.y + half
    }

    func contains(x: Float, y: Float) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}

public struct QualityReport: Sendable {
    public let overallPSNR: Double
    public let fovealPSNR: Double
    public let peripheralPSNR: Double
    /// The worst tile outside the fovea.
    ///
    /// Averaging across the periphery buries the answer: most of a frame is
    /// background that undersampling leaves untouched, so the mean stays high
    /// even where detail has been destroyed. Visible artifacts are local, so
    /// the worst tile is the number that predicts them.
    public let worstPeripheralTilePSNR: Double
    public let worstTileOrigin: (x: Int, y: Int)
}

public enum ImageMetrics {

    /// Peak signal-to-noise ratio, reported separately inside and outside the
    /// full-rate region.
    ///
    /// Splitting it matters: a single number averages a fovea that should be
    /// near-perfect together with a periphery that is *supposed* to degrade,
    /// and hides whether the trade landed where it was aimed.
    public static func compare(
        _ reference: CapturedImage,
        _ candidate: CapturedImage,
        fovea: NormalizedRect
    ) throws -> QualityReport {
        guard reference.width == candidate.width,
              reference.height == candidate.height
        else { throw MetricsError.sizeMismatch }

        var overall = 0.0, foveal = 0.0, peripheral = 0.0
        var overallCount = 0, fovealCount = 0, peripheralCount = 0

        for y in 0..<reference.height {
            let normalizedY = (Float(y) + 0.5) / Float(reference.height)
            for x in 0..<reference.width {
                let index = (y * reference.width + x) * 4
                // Blue, green, red; alpha carries no signal here.
                var squared = 0.0
                for channel in 0..<3 {
                    let difference = Double(reference.pixels[index + channel])
                        - Double(candidate.pixels[index + channel])
                    squared += difference * difference
                }

                overall += squared
                overallCount += 3

                let normalizedX = (Float(x) + 0.5) / Float(reference.width)
                if fovea.contains(x: normalizedX, y: normalizedY) {
                    foveal += squared
                    fovealCount += 3
                } else {
                    peripheral += squared
                    peripheralCount += 3
                }
            }
        }

        func psnr(_ sumOfSquares: Double, _ count: Int) -> Double {
            guard count > 0 else { return .nan }
            let meanSquaredError = sumOfSquares / Double(count)
            guard meanSquaredError > 0 else { return .infinity }
            return 10 * log10(255 * 255 / meanSquaredError)
        }

        let worst = worstPeripheralTile(reference, candidate, fovea: fovea)

        return QualityReport(
            overallPSNR: psnr(overall, overallCount),
            fovealPSNR: psnr(foveal, fovealCount),
            peripheralPSNR: psnr(peripheral, peripheralCount),
            worstPeripheralTilePSNR: worst.psnr,
            worstTileOrigin: worst.origin
        )
    }

    /// Side of the square tiles the worst-case search uses, in pixels.
    public static let tileSize = 128

    private static func worstPeripheralTile(
        _ reference: CapturedImage,
        _ candidate: CapturedImage,
        fovea: NormalizedRect
    ) -> (psnr: Double, origin: (x: Int, y: Int)) {
        var worstPSNR = Double.infinity
        var worstOrigin = (x: 0, y: 0)

        for tileY in stride(from: 0, to: reference.height, by: tileSize) {
            for tileX in stride(from: 0, to: reference.width, by: tileSize) {
                let maxY = min(tileY + tileSize, reference.height)
                let maxX = min(tileX + tileSize, reference.width)

                // Skip any tile that overlaps the fovea; those are full rate by
                // construction and would not be the worst case anyway.
                let centreX = (Float(tileX + maxX) / 2) / Float(reference.width)
                let centreY = (Float(tileY + maxY) / 2) / Float(reference.height)
                if fovea.contains(x: centreX, y: centreY) { continue }

                var sumOfSquares = 0.0
                var count = 0
                for y in tileY..<maxY {
                    for x in tileX..<maxX {
                        let index = (y * reference.width + x) * 4
                        for channel in 0..<3 {
                            let difference = Double(reference.pixels[index + channel])
                                - Double(candidate.pixels[index + channel])
                            sumOfSquares += difference * difference
                        }
                        count += 3
                    }
                }

                guard count > 0 else { continue }
                let meanSquaredError = sumOfSquares / Double(count)
                // A tile with no error at all is untouched background, not a
                // candidate for the worst case.
                guard meanSquaredError > 0 else { continue }
                let tilePSNR = 10 * log10(255 * 255 / meanSquaredError)
                if tilePSNR < worstPSNR {
                    worstPSNR = tilePSNR
                    worstOrigin = (tileX, tileY)
                }
            }
        }
        return (worstPSNR, worstOrigin)
    }
}
