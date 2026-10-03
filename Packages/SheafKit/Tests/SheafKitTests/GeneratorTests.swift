import CoreGraphics
import Foundation
import ImageIO
@testable import SheafKit
import Testing
import UniformTypeIdentifiers

@Suite struct GeneratorTests {
    @Test(arguments: [PageSize.letter, .a4, PageSize(width: 300, height: 144)])
    func blankDocumentHasRequestedPageSize(size: PageSize) throws {
        let data = try PDFGenerator.blankDocument(pageSize: size)
        let summary = try PDFInspector.summary(of: data)
        #expect(summary.pages == [.init(size: size, rotation: 0)])
        #expect(!summary.isEncrypted)
    }

    @Test func blankDocumentHonorsPageCount() throws {
        let data = try PDFGenerator.blankDocument(pageSize: .a4, pageCount: 5)
        #expect(try PDFInspector.summary(of: data).pageCount == 5)
    }

    @Test func imageBecomesOnePageAtPixelSize() throws {
        let png = try makeImage(width: 200, height: 100, type: .png)
        let summary = try PDFInspector.summary(of: PDFGenerator.document(fromImageData: png))
        #expect(summary.pages == [.init(size: PageSize(width: 200, height: 100), rotation: 0)])
    }

    @Test func imageDPIScalesPage() throws {
        let png = try makeImage(width: 600, height: 300, type: .png, properties: [
            kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300,
        ])
        let summary = try PDFInspector.summary(of: PDFGenerator.document(fromImageData: png))
        let size = try #require(summary.pages.first?.size)
        #expect(abs(size.width - 144) < 0.5)
        #expect(abs(size.height - 72) < 0.5)
    }

    @Test(arguments: [
        (CGImagePropertyOrientation.up, false), (.down, false), (.upMirrored, false), (.downMirrored, false),
        (.left, true), (.right, true), (.leftMirrored, true), (.rightMirrored, true),
    ])
    func imageOrientationSetsPageAxes(orientation: CGImagePropertyOrientation, swapped: Bool) throws {
        let jpeg = try makeImage(width: 200, height: 100, type: .jpeg, properties: [
            kCGImagePropertyOrientation: orientation.rawValue,
        ])
        let summary = try PDFInspector.summary(of: PDFGenerator.document(fromImageData: jpeg))
        let expected = swapped ? PageSize(width: 100, height: 200) : PageSize(width: 200, height: 100)
        #expect(summary.pages == [.init(size: expected, rotation: 0)])
    }

    /// An image with a red marker in its stored top-left corner must show that marker in
    /// the corner EXIF says is the visual top-left, for all eight orientations.
    @Test(arguments: [
        CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored,
        .leftMirrored, .right, .rightMirrored, .left,
    ])
    func imageOrientationPlacesPixelsUpright(orientation: CGImagePropertyOrientation) throws {
        let jpeg = try makeImage(width: 200, height: 100, type: .jpeg, markStoredTopLeft: true, properties: [
            kCGImagePropertyOrientation: orientation.rawValue,
        ])
        let pdf = try PDFGenerator.document(fromImageData: jpeg)
        let page = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)

        // Where the stored top-left pixel lands, as (fromLeft, fromTop) of the upright image.
        let expected: (left: Bool, top: Bool) = switch orientation {
        case .up: (true, true)
        case .upMirrored: (false, true)
        case .down: (false, false)
        case .downMirrored: (true, false)
        case .leftMirrored: (true, true)
        case .right: (false, true)
        case .rightMirrored: (false, false)
        case .left: (true, false)
        }

        let width = Int(box.width), height = Int(box.height)
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.drawPDFPage(page)
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)

        // Bitmap memory rows run top to bottom.
        func isRed(left: Bool, top: Bool) -> Bool {
            let x = left ? 10 : width - 11
            let y = top ? 10 : height - 11
            let p = pixels + (y * width + x) * 4
            return p[0] > 200 && p[1] < 80 && p[2] < 80
        }
        for corner in [(true, true), (false, true), (true, false), (false, false)] {
            #expect(isRed(left: corner.0, top: corner.1) == (corner == (expected.left, expected.top)),
                    "corner left=\(corner.0) top=\(corner.1)")
        }
    }

    @Test func jpegFilesGoInWithoutBeingRecompressed() throws {
        let jpeg = try makeImage(width: 320, height: 200, type: .jpeg)
        let pdf = try PDFGenerator.document(fromImageData: jpeg)
        #expect(pdf.range(of: jpeg) != nil)
        #expect(pdf.count < jpeg.count + 1500)
        // Lossless formats are stored exactly; formats that already lost detail become JPEG.
        let file = try PDFFile(data: PDFGenerator.document(fromImages: [
            try makeImage(width: 64, height: 64, type: .png), try makeImage(width: 64, height: 64, type: .heic),
        ]))
        let filters = try file.pageIDs().map { page -> PDFName? in
            try Self.image(onPage: page, of: file)?.dictionary["Filter"]?.nameValue
        }
        #expect(filters == ["FlateDecode", "DCTDecode"])
    }

    @Test func wideColorPhotosKeepTheirProfile() throws {
        let jpeg = try makeImage(width: 64, height: 64, type: .jpeg, colorSpace: CGColorSpace.displayP3)
        let file = try PDFFile(data: PDFGenerator.document(fromImageData: jpeg))
        let image = try #require(try Self.image(onPage: try file.pageIDs()[0], of: file))
        let space = try #require(file.resolve(image.dictionary["ColorSpace"] ?? .null).arrayValue)
        #expect(space.first?.nameValue == "ICCBased")
        let profile = try #require(file.resolve(space[1]).streamValue)
        #expect(profile.dictionary["N"]?.intValue == 3)
        #expect(try file.decodedData(of: profile).count > 200)
        // And Apple's renderer accepts it.
        #expect(try Reference(file.data).pageCount == 1)
    }

    @Test func transparentPicturesKeepTheirTransparency() throws {
        let png = try makeImage(width: 100, height: 100, type: .png, transparentRightHalf: true)
        let pdf = try PDFGenerator.document(fromImageData: png)
        let pixels = try #require(Reference(pdf).pixels(ofPage: 0, fullSize: true))
        // Gray on the left, the white page showing through on the right.
        #expect(pixels[(50 * 100 + 20) * 4] < 160)
        #expect(pixels[(50 * 100 + 80) * 4] > 250)
    }

    @Test func picturesAreFittedToPaperWithMargins() throws {
        let wide = try makeImage(width: 400, height: 100, type: .png, markStoredTopLeft: true)
        let tall = try makeImage(width: 100, height: 300, type: .png)
        var options = ImageDocumentOptions(paper: .fixed(.a4), margin: 50)
        let pdf = try PDFGenerator.document(fromImages: [wide, tall], options: options)
        let reference = try Reference(pdf)
        // The paper turns on its side for the wide picture.
        #expect(reference.shapes == ["842x595@0", "595x842@0"])
        let pixels = try #require(reference.pixels(ofPage: 0, fullSize: true))
        func isWhite(_ x: Int, _ y: Int) -> Bool { pixels[(y * 842 + x) * 4] > 250 && pixels[(y * 842 + x) * 4 + 1] > 250 }
        // 742 points wide and a quarter as tall, centered: from x 50 to 792, y 205 to 390.
        #expect(isWhite(45, 297) && !isWhite(55, 297) && !isWhite(787, 297) && isWhite(797, 297))
        #expect(isWhite(421, 200) && !isWhite(421, 210) && !isWhite(421, 385) && isWhite(421, 395))
        // The marker is still in the picture's top left corner.
        #expect(pixels[(215 * 842 + 60) * 4] > 200 && pixels[(215 * 842 + 60) * 4 + 1] < 80)

        options.turnsPaperToFit = false
        #expect(try Reference(PDFGenerator.document(fromImages: [wide], options: options)).shapes == ["595x842@0"])
        options = ImageDocumentOptions(margin: 10)
        #expect(try Reference(PDFGenerator.document(fromImages: [wide], options: options)).shapes == ["420x120@0"])
    }

    @Test func aPictureCanBeAddedToAnExistingDocument() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.insertImagePage(try makeImage(width: 200, height: 100, type: .jpeg), at: 1)
        let saved = try editor.serialized()
        #expect(try Reference(saved).shapes == ["612x792@0", "200x100@0", "612x792@0", "612x792@0"])
        #expect(saved.prefix(try Fixture.text3Pages.data.count) == (try Fixture.text3Pages.data))
    }

    @Test func undecodableImageThrows() {
        #expect(throws: SheafError.unreadableImage) {
            try PDFGenerator.document(fromImageData: Data("not an image".utf8))
        }
    }

    /// The picture a page made from an image shows.
    private static func image(onPage page: ObjectID, of file: PDFFile) throws -> PDFStream? {
        let resources = try file.value("Resources", in: file.object(page).dictionaryValue ?? [:]).dictionaryValue
        return try file.resolve(resources?["XObject"]?.dictionaryValue?["Im0"] ?? .null).streamValue
    }

    /// A gray image, optionally with a 40 by 40 red square in its stored top-left corner.
    private func makeImage(
        width: Int, height: Int, type: UTType, markStoredTopLeft: Bool = false, transparentRightHalf: Bool = false,
        colorSpace: CFString = CGColorSpace.sRGB, properties: [CFString: Any] = [:]
    ) throws -> Data {
        let alpha: CGImageAlphaInfo = transparentRightHalf ? .premultipliedLast : .noneSkipLast
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: colorSpace)!, bitmapInfo: alpha.rawValue
        ))
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: transparentRightHalf ? width / 2 : width, height: height))
        if markStoredTopLeft {
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: height - 40, width: 40, height: 40))
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
