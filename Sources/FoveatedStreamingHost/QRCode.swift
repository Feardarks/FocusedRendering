import CoreImage
import Foundation

public enum QRCodeError: Error {
    case generationFailed
    case rasterizationFailed
    case encodingFailed
}

/// Renders the pairing payload as a QR code.
public enum QRCode {

    /// Apple's reference endpoint uses error-correction level L, which keeps the
    /// code small enough to scan comfortably at arm's length.
    private static let correctionLevel = "L"

    private static func makeImage(_ payload: Data) throws -> CIImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw QRCodeError.generationFailed
        }
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw QRCodeError.generationFailed }
        return image
    }

    /// A PNG scaled so each module is `moduleSize` pixels.
    public static func png(_ payload: Data, moduleSize: Int = 12) throws -> Data {
        let image = try makeImage(payload)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(moduleSize), y: CGFloat(moduleSize)))
        let context = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace)
        else { throw QRCodeError.encodingFailed }
        return data
    }

    /// A terminal-renderable QR code.
    ///
    /// Modules are drawn with explicit ANSI background colours rather than glyphs
    /// so the code stays scannable whatever colour scheme the terminal uses, and
    /// two columns per module keep it roughly square in a monospaced grid.
    public static func ansiArt(_ payload: Data, quietZone: Int = 2) throws -> String {
        let image = try makeImage(payload)
        let context = CIContext()
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let cgImage = context.createCGImage(image, from: extent)
        else { throw QRCodeError.rasterizationFailed }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let bitmap = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: gray,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw QRCodeError.rasterizationFailed }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let dark = "\u{1B}[40m  \u{1B}[0m"
        let light = "\u{1B}[47m  \u{1B}[0m"
        let blankRow = String(repeating: light, count: width + quietZone * 2)

        var lines = Array(repeating: blankRow, count: quietZone)
        for y in 0..<height {
            var line = String(repeating: light, count: quietZone)
            for x in 0..<width {
                line += pixels[y * width + x] < 128 ? dark : light
            }
            line += String(repeating: light, count: quietZone)
            lines.append(line)
        }
        lines.append(contentsOf: Array(repeating: blankRow, count: quietZone))
        return lines.joined(separator: "\n")
    }
}
