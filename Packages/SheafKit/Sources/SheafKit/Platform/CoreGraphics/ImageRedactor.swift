import CoreGraphics
import Foundation
import ImageIO

/// Paints over parts of a picture for good.
///
/// The picture is drawn to a bitmap first, whatever format it is stored in, so every
/// kind of image a PDF can hold is handled the same way and nothing of the covered part
/// survives in the result.
enum ImageRedactor {
    /// - Parameters:
    ///   - document: A one-page PDF that shows the picture filling its page.
    ///   - width: The picture's size in pixels.
    ///   - regions: What to paint over, in fractions of the picture, from its bottom left.
    ///   - asJPEG: Stores the result as JPEG, for pictures that were photographs.
    /// - Returns: The new image object, or `nil` if the picture could not be drawn.
    static func redact(document: Data, width: Int, height: Int, regions: [PDFRectangle], color: PDFColor, asJPEG: Bool) -> PDFStream? {
        guard width > 0, height > 0, width * height <= 120_000_000,
              let provider = CGDataProvider(data: document as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        context.saveGState()
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.interpolationQuality = .none
        context.drawPDFPage(page)
        context.restoreGState()

        context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        for region in regions {
            // A pixel more on each side, so nothing shows at the edges.
            let rect = CGRect(
                x: (region.x * Double(width)).rounded(.down) - 1, y: (region.y * Double(height)).rounded(.down) - 1,
                width: (region.width * Double(width)).rounded(.up) + 2, height: (region.height * Double(height)).rounded(.up) + 2
            )
            context.fill(rect)
        }
        guard let image = context.makeImage(), let base = context.data else { return nil }

        var dictionary: PDFDictionary = [
            "Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(width), "Height": .integer(height),
            "BitsPerComponent": 8, "ColorSpace": .name("DeviceRGB"),
        ]
        if asJPEG, let jpeg = ImageReader.encodeJPEG(image, quality: 0.9) {
            dictionary["Filter"] = .name("DCTDecode")
            return PDFStream(dictionary: dictionary, data: ImageRecoder.withoutMetadata(jpeg: jpeg))
        }
        // Three bytes a pixel, rows from the top.
        let stride = context.bytesPerRow, bytes = base.assumingMemoryBound(to: UInt8.self)
        var samples = Data(count: width * height * 3)
        samples.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            let out = output.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let line = bytes + row * stride
                for column in 0..<width {
                    let target = (row * width + column) * 3
                    out[target] = line[column * 4]
                    out[target + 1] = line[column * 4 + 1]
                    out[target + 2] = line[column * 4 + 2]
                }
            }
        }
        dictionary["Filter"] = .name("FlateDecode")
        return PDFStream(dictionary: dictionary, data: Flate.deflate(samples))
    }
}
