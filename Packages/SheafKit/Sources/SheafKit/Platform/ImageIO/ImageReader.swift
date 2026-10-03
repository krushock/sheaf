import CoreGraphics
import Foundation
import ImageIO

/// A picture in the form a PDF stores it.
struct PDFImage {
    /// The image object, without its color space when `profile` is set.
    var stream: PDFStream
    /// Opacity, for pictures with transparent parts.
    var mask: PDFStream?
    /// The ICC profile that says what the picture's colors mean.
    var profile: Data?
    var components: Int
    /// The stored pixels' size in points, from the picture's resolution.
    var storedSize: PageSize
    /// The EXIF orientation, 1 through 8, that turns the stored pixels upright.
    var orientation: Int

    var swapsAxes: Bool { orientation >= 5 }
    var uprightSize: PageSize {
        swapsAxes ? PageSize(width: storedSize.height, height: storedSize.width) : storedSize
    }

    /// Maps the stored pixel rectangle onto the upright picture.
    var uprightTransform: Affine {
        let w = uprightSize.width, h = uprightSize.height
        return switch orientation {
        case 2: Affine(a: -1, b: 0, c: 0, d: 1, e: w, f: 0)
        case 3: Affine(a: -1, b: 0, c: 0, d: -1, e: w, f: h)
        case 4: Affine(a: 1, b: 0, c: 0, d: -1, e: 0, f: h)
        case 5: Affine(a: 0, b: -1, c: -1, d: 0, e: w, f: h)
        case 6: Affine(a: 0, b: -1, c: 1, d: 0, e: 0, f: h)
        case 7: Affine(a: 0, b: 1, c: 1, d: 0, e: 0, f: 0)
        case 8: Affine(a: 0, b: 1, c: -1, d: 0, e: w, f: 0)
        default: .identity
        }
    }
}

/// Reads picture files for placing in a PDF.
enum ImageReader {
    /// Formats that throw detail away when saving. Storing their pixels exactly would make
    /// a much larger file for no visible gain, so they are stored as JPEG.
    private static let lossyTypes: Set<String> = ["public.heic", "public.heif", "public.avif", "org.webmproject.webp", "public.jpeg"]

    /// - JPEG files go in as they are: no decoding, no loss, no growth.
    /// - HEIC, AVIF and WebP photos are stored as high-quality JPEG.
    /// - Everything else, such as PNG and TIFF, is stored exactly, with any transparency.
    static func read(_ data: Data) throws(SheafError) -> PDFImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0
        else { throw .unreadableImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        func resolution(_ key: CFString) -> Double {
            (properties[key] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        }
        let storedSize = PageSize(
            width: Double(image.width) * 72 / resolution(kCGImagePropertyDPIWidth),
            height: Double(image.height) * 72 / resolution(kCGImagePropertyDPIHeight)
        )
        let orientation = (properties[kCGImagePropertyOrientation] as? Int).flatMap { (1...8).contains($0) ? $0 : nil } ?? 1
        let type = CGImageSourceGetType(source) as String? ?? ""
        let model = properties[kCGImagePropertyColorModel] as? String
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)

        var jpeg: Data?
        if type == "public.jpeg", depth == 8, model == (kCGImagePropertyColorModelRGB as String) || model == (kCGImagePropertyColorModelGray as String) {
            jpeg = data
        } else if lossyTypes.contains(type), !hasAlpha {
            jpeg = encodeJPEG(image, quality: 0.9)
        }

        if let jpeg, let space = image.colorSpace, space.model == .rgb || space.model == .monochrome {
            let components = space.model == .rgb ? 3 : 1
            var dictionary: PDFDictionary = [
                "Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(image.width), "Height": .integer(image.height),
                "BitsPerComponent": 8, "Filter": .name("DCTDecode"),
                "ColorSpace": .name(components == 3 ? "DeviceRGB" : "DeviceGray"),
            ]
            // A photo from a phone is usually in a wider color space than sRGB. Without its
            // profile the colors would come out duller.
            let isPlain = space.name == CGColorSpace.sRGB || space.name == CGColorSpace.genericGrayGamma2_2
            let profile = isPlain ? nil : space.copyICCData() as Data?
            if profile != nil { dictionary["ColorSpace"] = nil }
            return PDFImage(
                stream: PDFStream(dictionary: dictionary, data: jpeg), mask: nil, profile: profile,
                components: components, storedSize: storedSize, orientation: orientation
            )
        }

        let pixels = try StampImage(image)
        let (stream, mask) = Appearance.imageObjects(for: pixels)
        return PDFImage(stream: stream, mask: mask, profile: nil, components: 3, storedSize: storedSize, orientation: orientation)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
