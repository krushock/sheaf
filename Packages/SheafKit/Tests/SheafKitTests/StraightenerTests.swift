import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SheafKit
import Testing

@Suite struct StraightenerTests {
    /// A white sheet with lines of text, lying askew on a dark desk.
    private func photograph() throws -> Data {
        let width = 1200, height = 900
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.22, green: 0.16, blue: 0.12, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // An A4 sheet, turned a little and seen from one side.
        context.translateBy(x: 600, y: 450)
        context.rotate(by: 0.2)
        context.concatenate(CGAffineTransform(a: 1, b: 0.06, c: -0.12, d: 0.92, tx: 0, ty: 0))
        context.setFillColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
        context.fill(CGRect(x: -230, y: -325, width: 460, height: 650))
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        for line in 0..<22 {
            context.fill(CGRect(x: -190, y: 270 - Double(line) * 25, width: line % 5 == 4 ? 220 : 380, height: 7))
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func aSheetIsCutOutAndSquaredUp() throws {
        let straightened = try #require(DocumentStraightener.straightened(try photograph()))
        let source = try #require(CGImageSourceCreateWithData(straightened as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // The sheet's proportions, give or take, and nearly all sheet: light with dark lines.
        let ratio = Double(image.width) / Double(image.height)
        #expect(abs(ratio - 460.0 / 650) < 0.08, "ratio \(ratio)")
        #expect(image.width > 300)

        let context = try #require(CGContext(
            data: nil, width: 50, height: 70, bitsPerComponent: 8, bytesPerRow: 200,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 50, height: 70))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // The corners, which were desk in the photograph, are now paper.
        for (x, y) in [(2, 2), (47, 2), (2, 67), (47, 67)] {
            #expect(pixels[(y * 50 + x) * 4] > 170, "corner \(x),\(y) is \(pixels[(y * 50 + x) * 4])")
        }
    }

    @Test func picturesWithoutASheetAreLeftAlone() throws {
        #expect(DocumentStraightener.straightened(Data("not a picture".utf8)) == nil)
        let context = try #require(CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(DocumentStraightener.straightened(output as Data) == nil)
    }
}
