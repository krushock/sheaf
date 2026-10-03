import CoreGraphics
import Foundation
import ImageIO

extension StampImage {
    /// Decodes a PNG, JPEG, HEIC or other system-readable image.
    ///
    /// - Parameter maxPixelSize: Larger images are scaled down to this on their long side.
    public init(encodedImageData data: Data, maxPixelSize: Int = 1600) throws(SheafError) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { throw .unreadableImage }
        try self.init(image)
    }

    public init(_ image: CGImage) throws(SheafError) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw .unreadableImage }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw .unreadableImage }

        var rgb = Data(count: width * height * 3)
        var alpha = Data(count: width * height)
        var isOpaque = true
        rgb.withUnsafeMutableBytes { rgbBytes in
            alpha.withUnsafeMutableBytes { alphaBytes in
                for index in 0..<width * height {
                    let a = pixels[index * 4 + 3]
                    alphaBytes[index] = a
                    if a != 255 { isOpaque = false }
                    // Undo the premultiplication the bitmap context applied.
                    for channel in 0..<3 {
                        let value = pixels[index * 4 + channel]
                        rgbBytes[index * 3 + channel] = a == 0 ? 255 : UInt8(min(255, Int(value) * 255 / Int(a)))
                    }
                }
            }
        }
        self.init(width: width, height: height, rgb: rgb, alpha: isOpaque ? nil : alpha)
    }
}
