import CoreGraphics
import Foundation
import ImageIO

/// Makes the pictures inside a document smaller: fewer pixels, stronger compression.
///
/// Pixel values pass through as numbers. No color conversion happens here; the document
/// keeps saying what the numbers mean.
enum ImageRecoder {
    enum Source {
        case jpeg(Data)
        /// Unpacked samples, one byte each, rows from the top.
        case raw(Data, width: Int, height: Int)
    }

    struct Output {
        var data: Data
        /// JPEG, or else deflated samples.
        var isJPEG: Bool
        var width: Int
        var height: Int
    }

    /// - Parameters:
    ///   - components: One for gray pictures, three for color.
    ///   - width: The size to bring the picture to. Never larger than it is.
    ///   - quality: JPEG quality from 0 to 1, or `nil` to keep every pixel value exact.
    /// - Returns: `nil` when the picture cannot be read or there is nothing to do.
    static func recode(_ source: Source, components: Int, width: Int, height: Int, quality: Double?) -> Output? {
        guard components == 1 || components == 3, width > 0, height > 0 else { return nil }
        let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()

        var image: CGImage
        var wasJPEG = false
        switch source {
        case .jpeg(let data):
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  decoded.colorSpace?.numberOfComponents == components,
                  // The same numbers under a plain color space, so that drawing converts nothing.
                  let plain = decoded.copy(colorSpace: space)
            else { return nil }
            image = plain
            wasJPEG = true
        case .raw(let data, let sourceWidth, let sourceHeight):
            guard sourceWidth > 0, sourceHeight > 0, data.count >= sourceWidth * sourceHeight * components,
                  let provider = CGDataProvider(data: data as CFData),
                  let made = CGImage(
                      width: sourceWidth, height: sourceHeight, bitsPerComponent: 8, bitsPerPixel: 8 * components,
                      bytesPerRow: sourceWidth * components, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                  )
            else { return nil }
            image = made
        }

        let shrinks = width < image.width || height < image.height
        let targetWidth = min(width, image.width), targetHeight = min(height, image.height)
        // Drawn into a bitmap either to shrink it or to get at its samples.
        var samples: Data?
        if shrinks || !wasJPEG {
            let alpha: CGImageAlphaInfo = components == 1 ? .none : .noneSkipLast
            guard let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let drawn = context.makeImage(), let base = context.data else { return nil }
            image = drawn
            let stride = context.bytesPerRow, bytes = base.assumingMemoryBound(to: UInt8.self)
            var packed = Data(count: targetWidth * targetHeight * components)
            packed.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                let out = output.bindMemory(to: UInt8.self)
                for row in 0..<targetHeight {
                    let line = bytes + row * stride
                    if components == 1 {
                        for column in 0..<targetWidth { out[row * targetWidth + column] = line[column] }
                    } else {
                        for column in 0..<targetWidth {
                            let target = (row * targetWidth + column) * 3
                            out[target] = line[column * 4]
                            out[target + 1] = line[column * 4 + 1]
                            out[target + 2] = line[column * 4 + 2]
                        }
                    }
                }
            }
            samples = packed
        }

        // Drawings, screenshots and the like have few colors and sharp edges, which JPEG
        // smears. Those stay exact.
        let isPhotographic = wasJPEG || !(samples.map { hasFewColors($0, components: components) } ?? false)
        if let quality, isPhotographic {
            guard let jpeg = ImageReader.encodeJPEG(image, quality: quality) else { return nil }
            return Output(data: withoutMetadata(jpeg: jpeg), isJPEG: true, width: targetWidth, height: targetHeight)
        }
        guard shrinks, !wasJPEG, let samples else { return nil }
        return Output(data: Flate.deflate(samples), isJPEG: false, width: targetWidth, height: targetHeight)
    }

    /// Whether a sampling of the pixels finds no more colors than a palette would hold.
    private static func hasFewColors(_ samples: Data, components: Int) -> Bool {
        let pixelCount = samples.count / components
        guard pixelCount > 0 else { return true }
        let step = max(pixelCount / 20_000, 1)
        var seen = Set<UInt32>()
        return samples.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var index = 0
            while index < pixelCount {
                var value: UInt32 = 0
                for component in 0..<components { value = value << 8 | UInt32(bytes[index * components + component]) }
                seen.insert(value)
                if seen.count > 256 { return false }
                index += step
            }
            return true
        }
    }

    /// A JPEG without its EXIF, color profile and comment segments. Inside a PDF nothing
    /// reads them, and a profile alone can be larger than a small picture.
    static func withoutMetadata(jpeg data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return data }
        var output = Data([0xFF, 0xD8])
        var position = 2
        while position + 4 <= bytes.count {
            guard bytes[position] == 0xFF else { return data }
            let marker = bytes[position + 1]
            // The start of the picture data: everything from here on is kept as it is.
            if marker == 0xDA {
                output.append(contentsOf: bytes[position...])
                return output
            }
            let length = Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            let end = position + 2 + length
            guard length >= 2, end <= bytes.count else { return data }
            if ![0xE1, 0xE2, 0xED, 0xFE].contains(marker) { output.append(contentsOf: bytes[position..<end]) }
            position = end
        }
        return data
    }
}
