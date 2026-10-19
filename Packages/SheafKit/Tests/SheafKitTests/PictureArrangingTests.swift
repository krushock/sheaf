import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import SheafKit
import Testing
import UniformTypeIdentifiers

/// Stacking order, masks, opacity, mirroring and copies of the pictures on a page.
@Suite struct PictureArrangingTests {
    private typealias Color = (r: Double, g: Double, b: Double)
    private let red: Color = (1, 0, 0), green: Color = (0, 1, 0), blue: Color = (0, 0, 1)

    /// A picture file: one color, or one color on its left half and another on its right.
    private func picture(_ left: Color, _ right: Color? = nil, width: Int = 80, height: Int = 40) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: left.r, green: left.g, blue: left.b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let right {
            context.setFillColor(red: right.r, green: right.g, blue: right.b, alpha: 1)
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func blankPage(_ side: Double = 400) throws -> PDFEditor {
        PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: side, height: side)])))
    }

    /// Which of red, green, blue or white a point of the first page mostly is, on the page as displayed.
    private func color(at x: Double, _ y: Double, of editor: PDFEditor) throws -> String {
        let (r, g, b) = try pixel(at: x, y, of: editor)
        if r > 200, g > 200, b > 200 { return "white" }
        if r > 200, g < 80, b < 80 { return "red" }
        if g > 200, r < 80, b < 80 { return "green" }
        if b > 200, r < 80, g < 80 { return "blue" }
        return "\(r),\(g),\(b)"
    }

    private func pixel(at x: Double, _ y: Double, of editor: PDFEditor) throws -> (Int, Int, Int) {
        let reference = try Reference(try editor.serialized())
        let page = try #require(reference.document.page(at: 0))
        let box = page.bounds(for: .cropBox)
        let pixels = try #require(reference.pixels(ofPage: 0, fullSize: true))
        let offset = (Int(box.height - y) * Int(box.width) + Int(x)) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private func found(at x: Double, _ y: Double, in editor: PDFEditor) throws -> PageImage {
        try #require(try editor.pageContent(at: 0).images.last { $0.contains(PDFPoint(x: x, y: y)) })
    }

    // MARK: Stacking

    @Test func picturesGoInFrontOfAndBehindEachOther() throws {
        var editor = try blankPage()
        try editor.addImage(try picture(red), toPageAt: 0, in: PDFRectangle(x: 50, y: 50, width: 200, height: 100))
        try editor.addImage(try picture(blue), toPageAt: 0, in: PDFRectangle(x: 150, y: 100, width: 200, height: 100))
        try editor.addImage(try picture(green), toPageAt: 0, in: PDFRectangle(x: 20, y: 300, width: 40, height: 20))
        // Blue was added last and covers red where they meet.
        #expect(try color(at: 200, 125, of: editor) == "blue")
        var lower = try found(at: 60, 60, in: editor)
        #expect(try editor.stackingMoves(forImage: lower.id, onPageAt: 0) == [.toFront, .forward])
        // The green one touches nothing, so it has nowhere to go.
        #expect(try editor.stackingMoves(forImage: try found(at: 30, 310, in: editor).id, onPageAt: 0).isEmpty)
        #expect(try editor.restack(image: try found(at: 30, 310, in: editor).id, onPageAt: 0, .toFront) == false)

        #expect(try editor.restack(image: lower.id, onPageAt: 0, .toFront))
        #expect(try color(at: 200, 125, of: editor) == "red")
        #expect(try color(at: 300, 150, of: editor) == "blue" && color(at: 30, 310, of: editor) == "green")
        lower = try found(at: 60, 60, in: editor)
        #expect(try editor.stackingMoves(forImage: lower.id, onPageAt: 0) == [.backward, .toBack])
        #expect(try editor.restack(image: lower.id, onPageAt: 0, .toFront) == false)

        #expect(try editor.restack(image: lower.id, onPageAt: 0, .backward))
        #expect(try color(at: 200, 125, of: editor) == "blue" && color(at: 60, 60, of: editor) == "red")
        // One step at a time, back to the front again.
        #expect(try editor.restack(image: try found(at: 60, 60, in: editor).id, onPageAt: 0, .forward))
        #expect(try color(at: 200, 125, of: editor) == "red")
        #expect(try editor.restack(image: try found(at: 60, 60, in: editor).id, onPageAt: 0, .toBack))
        #expect(try color(at: 200, 125, of: editor) == "blue")
        #expect(try editor.pageContent(at: 0).images.count == 3)
        #expect(try Reference(editor.serialized()).pageCount == 1)
    }

    /// A page whose own content is written by hand, around a picture that is in its resources.
    private func page(drawing content: (String) -> String) throws -> PDFEditor {
        var editor = try blankPage()
        try editor.addImage(try picture(red), toPageAt: 0, in: PDFRectangle(x: 0, y: 0, width: 10, height: 10))
        let name = try #require(try editor.pageContent(at: 0).images.first?.name)
        var stream = try editor.contentStream(forPageAt: 0)
        stream.operations = ContentStream.operations(parsing: content("/\(name.rawValue) Do"))
        try editor.setContentStream(stream, forPageAt: 0)
        return editor
    }

    @Test func aPictureTakesItsClipAlongAndLeavesTheRestAsItWas() throws {
        // Everything is drawn at twice its size, set once and never undone. The picture
        // is clipped to the bottom left of the page; a green square is drawn over it.
        var editor = try page { picture in
            "2 0 0 2 0 0 cm q 0 0 100 100 re W n q 100 0 0 100 25 25 cm \(picture) Q Q 0 1 0 rg 50 50 100 100 re f"
        }
        #expect(try color(at: 150, 150, of: editor) == "green" && color(at: 75, 75, of: editor) == "red")
        // Clipped: the picture would reach 250, but stops at 200.
        #expect(try color(at: 75, 225, of: editor) == "white")

        #expect(try editor.restack(image: try found(at: 75, 75, in: editor).id, onPageAt: 0, .toFront))
        #expect(try color(at: 150, 150, of: editor) == "red")
        // Still clipped where it was, and the square is where it was.
        #expect(try color(at: 75, 225, of: editor) == "white" && color(at: 225, 225, of: editor) == "green" && color(at: 280, 280, of: editor) == "green")

        #expect(try editor.restack(image: try found(at: 75, 75, in: editor).id, onPageAt: 0, .toBack))
        #expect(try color(at: 150, 150, of: editor) == "green" && color(at: 75, 75, of: editor) == "red")
        #expect(try color(at: 75, 225, of: editor) == "white" && color(at: 280, 280, of: editor) == "green")
    }

    @Test func aStepBackGoesBetweenTwoThings() throws {
        // A blue square, a green square, and the picture on top of both. The scale and
        // the colors are set outside any saved state.
        var editor = try page { picture in
            "2 0 0 2 0 0 cm 0 0 1 rg 0 0 60 60 re f 0 1 0 rg 50 50 100 100 re f q 100 0 0 100 25 25 cm \(picture) Q 0 0 1 rg 180 180 10 10 re f"
        }
        #expect(try color(at: 150, 150, of: editor) == "red" && color(at: 75, 75, of: editor) == "red")
        #expect(try editor.restack(image: try found(at: 75, 75, in: editor).id, onPageAt: 0, .backward))
        // Behind the green square, still over the blue one.
        #expect(try color(at: 150, 150, of: editor) == "green" && color(at: 75, 75, of: editor) == "red")
        // What came after it is drawn as before: same scale, same colors.
        #expect(try color(at: 280, 280, of: editor) == "green" && color(at: 370, 370, of: editor) == "blue" && color(at: 30, 30, of: editor) == "blue")
        #expect(try editor.stackingMoves(forImage: try found(at: 75, 75, in: editor).id, onPageAt: 0) == [.toFront, .forward, .backward, .toBack])

        #expect(try editor.restack(image: try found(at: 75, 75, in: editor).id, onPageAt: 0, .toBack))
        #expect(try color(at: 75, 75, of: editor) == "blue" && color(at: 200, 60, of: editor) == "red")
        #expect(try color(at: 280, 280, of: editor) == "green" && color(at: 370, 370, of: editor) == "blue")
        // Doing it again changes nothing, and does not pile up saved states.
        let count = try editor.contentStream(forPageAt: 0).operations.count
        #expect(try editor.restack(image: try found(at: 200, 60, in: editor).id, onPageAt: 0, .toBack) == false)
        #expect(try editor.contentStream(forPageAt: 0).operations.count == count)
    }

    @Test func nothingGoesBehindWhatCoversThePage() throws {
        var editor = try page { picture in
            "1 1 1 rg 0 0 400 400 re f q 100 0 0 100 50 50 cm \(picture) Q"
        }
        #expect(try editor.stackingMoves(forImage: try found(at: 75, 75, in: editor).id, onPageAt: 0).isEmpty)
        #expect(try editor.restack(image: try found(at: 75, 75, in: editor).id, onPageAt: 0, .toBack) == false)
        #expect(try color(at: 75, 75, of: editor) == "red")
    }

    @Test func textGoesBehindAPictureAndBack() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        let block = try #require(try editor.pageContent(at: 0).blocks.first { $0.isEditable })
        let words = block.text
        #expect(try editor.stackingMoves(forBlock: block.id, onPageAt: 0).isEmpty)
        // A picture over the text: the text is now under something.
        try editor.addImage(try picture(red), toPageAt: 0, in: block.frame)
        var found = try #require(try editor.pageContent(at: 0).blocks.first { $0.text == words })
        #expect(try editor.stackingMoves(forBlock: found.id, onPageAt: 0) == [.toFront, .forward])
        #expect(try editor.restack(block: found.id, onPageAt: 0, .toFront))
        found = try #require(try editor.pageContent(at: 0).blocks.first { $0.text == words })
        #expect(abs(found.frame.x - block.frame.x) < 0.5 && abs(found.frame.y - block.frame.y) < 0.5)
        #expect(try editor.stackingMoves(forBlock: found.id, onPageAt: 0) == [.backward, .toBack])
        #expect(try editor.restack(block: found.id, onPageAt: 0, .toBack))
        found = try #require(try editor.pageContent(at: 0).blocks.first { $0.text == words })
        #expect(try editor.stackingMoves(forBlock: found.id, onPageAt: 0) == [.toFront, .forward])
        // The other text on the page reads as it did.
        let before = try PDFEditor(try PDFFile(data: Fixture.text3Pages.data)).pageContent(at: 0).blocks.map(\.text).sorted()
        #expect(try editor.pageContent(at: 0).blocks.map(\.text).sorted() == before)
        #expect(try Reference(editor.serialized()).pageCount == 3)
    }

    // MARK: Looks

    @Test func aPictureCanBeSeenThrough() throws {
        var editor = try blankPage()
        try editor.addImage(try picture(red), toPageAt: 0, in: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        var image = try found(at: 150, 150, in: editor)
        #expect(image.opacity == 1)
        try editor.setImageOpacity(0.5, ofImage: image.id, onPageAt: 0)
        image = try found(at: 150, 150, in: editor)
        #expect(abs(image.opacity - 0.5) < 0.001)
        let (r, g, b) = try pixel(at: 150, 150, of: editor)
        #expect(r > 240 && abs(g - 128) < 12 && abs(b - 128) < 12)
        // It stays see-through when it is moved, and can be made solid again.
        try editor.setImageFrame(PDFRectangle(x: 20, y: 20, width: 100, height: 50), ofImage: image.id, onPageAt: 0)
        image = try found(at: 50, 40, in: editor)
        #expect(abs(image.opacity - 0.5) < 0.001)
        try editor.setImageOpacity(1, ofImage: image.id, onPageAt: 0)
        #expect(try color(at: 50, 40, of: editor) == "red" && found(at: 50, 40, in: editor).opacity == 1)
    }

    @Test func aPictureIsMaskedAndShownWholeAgain() throws {
        var editor = try blankPage()
        // Red on the left, blue on the right.
        try editor.addImage(try picture(red, blue), toPageAt: 0, in: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        var image = try found(at: 150, 150, in: editor)
        #expect(image.shownPart == nil)
        // Only the right half, and of that the lower half.
        try editor.setImageMask(PDFRectangle(x: 0.5, y: 0, width: 0.5, height: 0.5), ofImage: image.id, onPageAt: 0)
        #expect(try color(at: 150, 125, of: editor) == "white" && color(at: 250, 125, of: editor) == "blue" && color(at: 250, 175, of: editor) == "white")
        image = try found(at: 250, 125, in: editor)
        #expect(image.shownPart == PDFRectangle(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(abs(image.frame.x - 200) < 0.01 && abs(image.frame.width - 100) < 0.01 && abs(image.frame.height - 50) < 0.01)
        #expect(abs(image.unmaskedPlacement.width - 200) < 0.01 && abs(image.unmaskedPlacement.center.x - 200) < 0.01)

        // What shows is what moves, resizes and turns; the mask goes along.
        var placement = image.placement
        placement.center = PDFPoint(x: 100, y: 300)
        placement.width = 50
        placement.height = 25
        placement.rotation = 90
        try editor.setImagePlacement(placement, ofImage: image.id, onPageAt: 0)
        image = try found(at: 100, 300, in: editor)
        #expect(image.isEditable && image.shownPart == PDFRectangle(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(abs(image.frame.width - 25) < 0.01 && abs(image.frame.height - 50) < 0.01)
        #expect(try color(at: 100, 300, of: editor) == "blue" && color(at: 100, 340, of: editor) == "white" && color(at: 130, 300, of: editor) == "white")

        // All of it again: the picture is still whole in the file.
        try editor.setImageMask(nil, ofImage: image.id, onPageAt: 0)
        image = try found(at: 100, 300, in: editor)
        #expect(image.shownPart == nil && abs(image.placement.width - 100) < 0.01 && abs(image.placement.height - 50) < 0.01)
        #expect(try editor.pageContent(at: 0).images.count == 1)
    }

    @Test func aPictureIsMirrored() throws {
        var editor = try blankPage()
        try editor.addImage(try picture(red, blue), toPageAt: 0, in: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        var image = try found(at: 150, 150, in: editor)
        try editor.flipImage(image.id, onPageAt: 0, horizontally: true)
        #expect(try color(at: 150, 150, of: editor) == "blue" && color(at: 250, 150, of: editor) == "red")
        image = try found(at: 150, 150, in: editor)
        #expect(image.isEditable && image.placement.isMirrored && image.placement.rotation < 0.01)
        #expect(abs(image.frame.x - 100) < 0.01 && abs(image.frame.width - 200) < 0.01)
        // Turned a quarter while mirrored, it stays mirrored.
        var placement = image.placement
        placement.rotation = 90
        try editor.setImagePlacement(placement, ofImage: image.id, onPageAt: 0)
        image = try found(at: 200, 150, in: editor)
        #expect(image.placement.isMirrored && abs(image.placement.rotation - 90) < 0.01)
        // Blue was on the left, so a quarter turn puts it at the bottom.
        #expect(try color(at: 200, 80, of: editor) == "blue" && color(at: 200, 220, of: editor) == "red")
        // Top to bottom swaps them, and twice the same way puts things back.
        try editor.flipImage(image.id, onPageAt: 0, horizontally: false)
        #expect(try color(at: 200, 80, of: editor) == "blue" && color(at: 200, 220, of: editor) == "red")
        try editor.flipImage(try found(at: 200, 150, in: editor).id, onPageAt: 0, horizontally: true)
        #expect(try color(at: 200, 80, of: editor) == "red" && color(at: 200, 220, of: editor) == "blue")
        // A mask on a mirrored picture is given the way the picture shows.
        try editor.setImageMask(PDFRectangle(x: 0, y: 0, width: 0.5, height: 1), ofImage: try found(at: 200, 150, in: editor).id, onPageAt: 0)
        // It is turned three quarters by now, so its own left half is the top half on the page.
        image = try found(at: 200, 200, in: editor)
        #expect(image.shownPart == PDFRectangle(x: 0, y: 0, width: 0.5, height: 1))
        #expect(try color(at: 200, 200, of: editor) == "blue" && color(at: 200, 100, of: editor) == "white")
    }

    @Test func aPictureIsCopiedWithoutCopyingItsData() throws {
        var editor = try blankPage()
        try editor.addImage(try picture(red, blue), toPageAt: 0, in: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        let image = try found(at: 150, 150, in: editor)
        try editor.setImageOpacity(0.5, ofImage: image.id, onPageAt: 0)
        let frame = try editor.duplicateImage(try found(at: 150, 150, in: editor).id, onPageAt: 0, dx: 20, dy: -150)
        #expect(abs(frame.x - 120) < 0.01 && abs(frame.y + 50) < 0.01)
        let images = try editor.pageContent(at: 0).images
        #expect(images.count == 2 && images[0].objectID == images[1].objectID && images.allSatisfy { abs($0.opacity - 0.5) < 0.001 && $0.isEditable })
        #expect(abs(images[1].frame.x - 120) < 0.01 && abs(images[1].frame.width - 200) < 0.01)
    }

    @Test func changesAreMadeInPlace() throws {
        var editor = try blankPage()
        try editor.addImage(try picture(red), toPageAt: 0, in: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        try editor.setImageFrame(PDFRectangle(x: 10, y: 10, width: 100, height: 50), ofImage: 0, onPageAt: 0)
        let count = try editor.contentStream(forPageAt: 0).operations.count
        for step in 1...12 {
            var placement = try #require(try editor.pageContent(at: 0).images.first).placement
            placement.rotation = Double(step) * 30
            placement.center.x += 5
            try editor.setImagePlacement(placement, ofImage: 0, onPageAt: 0)
        }
        // A dozen changes later the page draws it with as many operations as before,
        // and nothing has drifted.
        #expect(try editor.contentStream(forPageAt: 0).operations.count == count)
        let placement = try #require(try editor.pageContent(at: 0).images.first).placement
        #expect(abs(placement.width - 100) < 0.001 && abs(placement.height - 50) < 0.001 && abs(placement.center.x - 120) < 0.001)
        #expect(placement.rotation < 0.001 || placement.rotation > 359.999)
    }

    @Test func aPictureComesOutAsADocumentOfItsOwn() throws {
        var editor = try blankPage()
        try editor.addImage(try picture(red, blue, width: 60, height: 30), toPageAt: 0, in: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        var placement = try #require(try editor.pageContent(at: 0).images.first).placement
        placement.rotation = 40
        try editor.setImagePlacement(placement, ofImage: 0, onPageAt: 0)
        let data = try #require(try editor.pictureDocument(forImage: 0, onPageAt: 0))
        let alone = PDFEditor(try PDFFile(data: data))
        // Upright, whole, a point to a pixel.
        #expect(try alone.pageBox(at: 0) == PDFRectangle(x: 0, y: 0, width: 60, height: 30))
        #expect(try color(at: 10, 15, of: alone) == "red" && color(at: 50, 15, of: alone) == "blue")
    }

    // MARK: Annotations

    @Test func annotationsGoInFrontOfAndBehindEachOther() throws {
        var editor = try blankPage()
        let first = Annotation(kind: .square, rect: PDFRectangle(x: 50, y: 50, width: 100, height: 100))
        let second = Annotation(kind: .square, rect: PDFRectangle(x: 100, y: 100, width: 100, height: 100))
        let lower = try editor.addAnnotation(first, toPageAt: 0), upper = try editor.addAnnotation(second, toPageAt: 0)
        let apart = try editor.addAnnotation(Annotation(kind: .square, rect: PDFRectangle(x: 300, y: 300, width: 50, height: 50)), toPageAt: 0)
        #expect(try editor.stackingMoves(forAnnotation: lower, onPageAt: 0) == [.toFront, .forward])
        #expect(try editor.stackingMoves(forAnnotation: upper, onPageAt: 0) == [.backward, .toBack])
        #expect(try editor.stackingMoves(forAnnotation: apart, onPageAt: 0).isEmpty)
        #expect(try editor.restack(annotation: lower, onPageAt: 0, .forward))
        #expect(try editor.annotations(onPageAt: 0).map(\.objectID) == [upper, lower, apart])
        #expect(try editor.restack(annotation: lower, onPageAt: 0, .toFront) == false)
        #expect(try editor.restack(annotation: lower, onPageAt: 0, .toBack))
        #expect(try editor.annotations(onPageAt: 0).map(\.objectID) == [lower, upper, apart])
    }

    @Test func aGeneratedPictureSaysSoInItsMetadata() throws {
        var editor = try blankPage()
        try editor.addImage(try picture(red), toPageAt: 0, in: PDFRectangle(x: 50, y: 50, width: 200, height: 100), generatedBy: "Image Playground")
        try editor.addImage(try picture(blue), toPageAt: 0, in: PDFRectangle(x: 50, y: 200, width: 200, height: 100))
        let saved = try editor.rewritten()
        let text = String(decoding: saved, as: UTF8.self)
        // Once, for the one picture a model made, and readable as it is.
        #expect(text.components(separatedBy: "digitalsourcetype/trainedAlgorithmicMedia").count == 2)
        #expect(text.contains("<xmp:CreatorTool>Image Playground</xmp:CreatorTool>"))
        // It stays with the picture through another save.
        var again = try PDFEditor(PDFFile(data: saved))
        try again.addImage(try picture(green), toPageAt: 0, in: PDFRectangle(x: 50, y: 320, width: 40, height: 20))
        #expect(String(decoding: try again.rewritten(), as: UTF8.self).contains("trainedAlgorithmicMedia"))
        // And the page still shows both pictures.
        #expect(try editor.pageContent(at: 0).images.count == 2)
    }
}

extension CorpusTests {
    /// Pictures in real files are taken out of the page's drawing and put back at the
    /// very same place in the order, which must leave the page looking exactly as it did:
    /// whatever clipped, placed and colored the picture has to go along with it, and
    /// everything drawn after it has to find the state it expects. Then every move in
    /// the stacking order is made, which must leave a page with the same things on it.
    @Test(.enabled(if: listPath != nil))
    func everyPictureRestacks() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8).split(separator: "\n").map(String.init)
        var files = 0, pictures = 0, moves = 0, textMoves = 0
        var problems: [String] = []
        func pixels(_ data: Data, page: Int) -> Data? {
            Reference.pixels(of: PDFDocument(data: data)?.page(at: page), fullSize: true)
        }
        func differing(_ a: Data, _ b: Data) -> Int {
            guard a.count == b.count else { return max(a.count, b.count) }
            var count = 0
            a.withUnsafeBytes { first in
                b.withUnsafeBytes { second in
                    for offset in 0..<a.count where abs(Int(first[offset]) - Int(second[offset])) > 24 { count += 1 }
                }
            }
            return count
        }
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let original = PDFDocument(data: data), !original.isLocked, original.pageCount > 0, original.pageCount <= 40,
                  let editor = try? PDFEditor(PDFFile(data: data))
            else { continue }
            var touched = false
            for page in 0..<min(original.pageCount, 3) {
                do {
                    let interpretation = try editor.interpret(pageAt: page)
                    let content = PDFEditor.content(from: interpretation, source: editor)
                    let images = content.images.filter(\.isEditable).prefix(2)
                    // Text that lies over or under something is moved each way too.
                    for block in content.blocks.filter(\.isEditable).prefix(40) {
                        let offered = try editor.stackingMoves(forBlock: block.id, onPageAt: page)
                        guard !offered.isEmpty, textMoves < 600 else { continue }
                        touched = true
                        for move in offered {
                            textMoves += 1
                            var moved = editor
                            guard try moved.restack(block: block.id, onPageAt: page, move) else {
                                problems.append("\(path) page \(page + 1): \(move) was offered for text but did nothing")
                                continue
                            }
                            let after = try moved.pageContent(at: page)
                            if PageTextTests.squeezed(after.text).count != PageTextTests.squeezed(content.text).count {
                                problems.append("\(path) page \(page + 1): the text reads differently after its \(move)")
                            }
                            if after.images.count != content.images.count { problems.append("\(path) page \(page + 1): text \(move) left \(after.images.count) pictures of \(content.images.count)") }
                            if PDFDocument(data: try moved.serialized())?.pageCount != original.pageCount { problems.append("\(path) page \(page + 1): PDFKit cannot open the file after text \(move)") }
                        }
                        break
                    }
                    guard !images.isEmpty else { continue }
                    let operations = interpretation.streams[0].content.operations
                    let boundaries = ContentStream.boundaries(in: operations)
                    // As saved by this engine before any change, so only the change shows.
                    guard let before = pixels(try editor.serialized(), page: page) else { continue }
                    let texts = content.blocks.map(\.text).sorted()
                    for image in images {
                        pictures += 1
                        touched = true
                        let range = PictureGroup(around: image.source.operation, in: operations)?.range ?? image.source.operation...image.source.operation
                        if boundaries[range.upperBound + 1] {
                            var same = editor
                            var replacements: [Int: [ContentStream.Operation]] = [:]
                            for position in range { replacements[position] = [] }
                            let block = ContentStream.lifted(Array(operations[range]), from: ContentStream.drawingState(before: range.lowerBound, in: operations))
                            try same.rewritePage(at: page, interpretation, replacing: replacements, inserting: block, at: range.upperBound + 1 < operations.count ? range.upperBound + 1 : nil)
                            guard let after = pixels(try same.serialized(), page: page) else {
                                problems.append("\(path) page \(page + 1): cannot be drawn after a picture is put back")
                                continue
                            }
                            let changed = differing(before, after)
                            if changed > max(before.count / 20_000, 8) { problems.append("\(path) page \(page + 1): \(changed) of \(before.count) samples differ after picture \(image.id) is put back where it was") }
                        }
                        for move in try editor.stackingMoves(forImage: image.id, onPageAt: page) {
                            moves += 1
                            var moved = editor
                            guard try moved.restack(image: image.id, onPageAt: page, move) else {
                                problems.append("\(path) page \(page + 1): \(move) was offered for picture \(image.id) but did nothing")
                                continue
                            }
                            let after = try moved.pageContent(at: page)
                            if after.images.count != content.images.count { problems.append("\(path) page \(page + 1): \(move) left \(after.images.count) pictures of \(content.images.count)") }
                            if after.blocks.map(\.text).sorted() != texts { problems.append("\(path) page \(page + 1): the text reads differently after \(move)") }
                            if PDFDocument(data: try moved.serialized())?.pageCount != original.pageCount { problems.append("\(path) page \(page + 1): PDFKit cannot open the file after \(move)") }
                        }
                    }
                } catch {
                    problems.append("\(path) page \(page + 1): \(error)")
                }
            }
            if touched { files += 1 }
        }
        print("corpus: \(pictures) pictures put back in place and restacked \(moves) times, text restacked \(textMoves) times, in \(files) files, \(problems.count) problems")
        for problem in problems.prefix(40) { print("  \(problem)") }
        #expect(problems.isEmpty)
    }
}
