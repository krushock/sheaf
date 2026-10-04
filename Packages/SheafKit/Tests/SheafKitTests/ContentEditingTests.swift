import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import SheafKit
import Testing
import UniformTypeIdentifiers

@Suite struct ContentEditingTests {
    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A solid picture file.
    private func picture(red: Double, green: Double, blue: Double, width: Int = 80, height: Int = 40, type: UTType = .png) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The color at a point of the first page, given on the page as displayed.
    private func color(at point: PDFPoint, of data: Data, page index: Int = 0) throws -> (r: Int, g: Int, b: Int) {
        let reference = try Reference(data)
        let page = try #require(reference.document.page(at: index))
        let box = page.bounds(for: .cropBox)
        let pixels = try #require(reference.pixels(ofPage: index, fullSize: true))
        let x = Int(point.x), y = Int(box.height - point.y)
        let offset = (y * Int(box.width) + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    // MARK: Pictures

    @Test func picturesMoveResizeAndGo() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.image1Page.data))
        let image = try #require(try editor.pageContent(at: 0).images.first)
        let target = PDFRectangle(x: 300, y: 100, width: 120, height: 60)
        try editor.setImageFrame(target, ofImage: image.id, onPageAt: 0)
        var content = try editor.pageContent(at: 0)
        let moved = try #require(content.images.first)
        #expect(abs(moved.frame.x - 300) < 0.01 && abs(moved.frame.y - 100) < 0.01 && abs(moved.frame.width - 120) < 0.01 && abs(moved.frame.height - 60) < 0.01)
        let saved = try editor.serialized()
        // Something is drawn in the new place and nothing in the old.
        let inside = try color(at: PDFPoint(x: 360, y: 130), of: saved)
        #expect(inside.r < 250 || inside.g < 250 || inside.b < 250)
        let old = try color(at: PDFPoint(x: image.frame.x + image.frame.width / 2, y: image.frame.y + image.frame.height - 10), of: saved)
        #expect(old.r > 250 && old.g > 250 && old.b > 250)
        // It can be moved again, and removed.
        try editor.setImageFrame(PDFRectangle(x: 50, y: 50, width: 60, height: 30), ofImage: moved.id, onPageAt: 0)
        let again = try #require(try editor.pageContent(at: 0).images.first)
        #expect(abs(again.frame.width - 60) < 0.01)
        try editor.removeImage(again.id, onPageAt: 0)
        content = try editor.pageContent(at: 0)
        #expect(content.images.isEmpty)
        #expect(try Reference(editor.serialized()).pageCount == 1)
    }

    @Test func picturesTurnAndStayEditable() throws {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 400, height: 400)])))
        try editor.addImage(try picture(red: 1, green: 0, blue: 0), toPageAt: 0, in: PDFRectangle(x: 100, y: 150, width: 200, height: 100))
        var image = try #require(try editor.pageContent(at: 0).images.first)
        #expect(image.placement == ImagePlacement(center: PDFPoint(x: 200, y: 200), width: 200, height: 100, rotation: 0))

        // A quarter turn about its center: now tall where it was wide.
        var turned = image.placement
        turned.rotation = 90
        try editor.setImagePlacement(turned, ofImage: image.id, onPageAt: 0)
        image = try #require(try editor.pageContent(at: 0).images.first)
        #expect(image.isEditable)
        #expect(abs(image.placement.rotation - 90) < 0.01 && abs(image.placement.width - 200) < 0.01 && abs(image.placement.height - 100) < 0.01)
        #expect(abs(image.frame.width - 100) < 0.01 && abs(image.frame.height - 200) < 0.01)
        #expect(abs(image.placement.center.x - 200) < 0.01 && abs(image.placement.center.y - 200) < 0.01)
        let saved = try editor.serialized()
        // Red where the turned picture is, white where it was and is no more.
        #expect(try color(at: PDFPoint(x: 200, y: 290), of: saved).r > 200 && color(at: PDFPoint(x: 200, y: 290), of: saved).g < 60)
        #expect(try color(at: PDFPoint(x: 290, y: 200), of: saved).g > 200)

        // Turned by an odd angle, moved and made smaller, it can still be picked by where it is.
        try editor.setImagePlacement(ImagePlacement(center: PDFPoint(x: 150, y: 250), width: 100, height: 40, rotation: 30), ofImage: image.id, onPageAt: 0)
        image = try #require(try editor.pageContent(at: 0).images.first)
        #expect(image.isEditable && abs(image.placement.rotation - 30) < 0.01 && abs(image.placement.width - 100) < 0.01)
        #expect(image.contains(PDFPoint(x: 150, y: 250)))
        // A corner of its upright box that the turned picture itself does not reach.
        let box = image.frame
        #expect(!image.contains(PDFPoint(x: box.x + 2, y: box.y + box.height - 2)))
        #expect(try editor.pageContent(at: 0).image(at: PDFPoint(x: box.x + 2, y: box.y + box.height - 2)) == nil)
        // The picture's own corners are where the placement says.
        let corner = image.placement.point(atFractionX: 1, y: 0.5)
        #expect(abs(corner.x - (150 + 50 * cos(Double.pi / 6))) < 0.01 && abs(corner.y - (250 + 50 * sin(Double.pi / 6))) < 0.01)
        let local = image.placement.local(corner)
        #expect(abs(local.x - 50) < 0.01 && abs(local.y) < 0.01)

        // Another picture put in its place is turned the same way, about the same center.
        try editor.replaceImage(image.id, onPageAt: 0, with: try picture(red: 0, green: 0, blue: 1))
        let replaced = try #require(try editor.pageContent(at: 0).images.first)
        #expect(replaced.isEditable && abs(replaced.placement.rotation - 30) < 0.01)
        #expect(abs(replaced.placement.center.x - 150) < 0.01 && abs(replaced.placement.center.y - 250) < 0.01)
        #expect(replaced.placement.width <= 100.01 && replaced.placement.height <= 40.01)
    }

    @Test func picturesAreReplacedInPlaceAndAdded() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.image1Page.data))
        let image = try #require(try editor.pageContent(at: 0).images.first)
        try editor.replaceImage(image.id, onPageAt: 0, with: try picture(red: 1, green: 0, blue: 0))
        let replaced = try #require(try editor.pageContent(at: 0).images.first)
        // Twice as wide as tall, fitted inside the old frame and centered in it.
        #expect(abs(replaced.frame.width / replaced.frame.height - 2) < 0.01)
        #expect(replaced.frame.x >= image.frame.x - 0.01 && replaced.frame.width <= image.frame.width + 0.01)
        #expect(abs((replaced.frame.x + replaced.frame.width / 2) - (image.frame.x + image.frame.width / 2)) < 0.01)
        var saved = try editor.serialized()
        let middle = try color(at: PDFPoint(x: replaced.frame.x + replaced.frame.width / 2, y: replaced.frame.y + replaced.frame.height / 2), of: saved)
        #expect(middle.r > 240 && middle.g < 20 && middle.b < 20)

        let placed = try editor.addImage(try picture(red: 0, green: 0, blue: 1, type: .jpeg), toPageAt: 0, in: PDFRectangle(x: 400, y: 600, width: 100, height: 100))
        #expect(placed == PDFRectangle(x: 400, y: 625, width: 100, height: 50))
        saved = try editor.serialized()
        let blue = try color(at: PDFPoint(x: 450, y: 650), of: saved)
        #expect(blue.b > 240 && blue.r < 20)
        #expect(try editor.pageContent(at: 0).images.count == 2)
        // With no frame it lands in the middle of the page.
        let centered = try editor.addImage(try picture(red: 0, green: 1, blue: 0), toPageAt: 0)
        let size = try editor.geometry(ofPageAt: 0).displaySize
        #expect(abs(centered.x + centered.width / 2 - size.width / 2) < 0.01)
    }

    // MARK: Find and replace

    @Test func textIsFoundAcrossLineEnds() throws {
        let editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        let found = try editor.findText("ipsum", onPageAt: 0)
        #expect(found.count == 1 && found[0].text == "ipsum" && found[0].frames.count == 1 && found[0].isReplaceable)
        let frame = found[0].frames[0]
        #expect(frame.width > 20 && frame.width < 40 && frame.height > 8)
        // PDFKit finds it in the same place.
        let document = try #require(PDFDocument(data: try Fixture.text3Pages.data))
        let page = try #require(document.page(at: 0))
        let selection = try #require(document.findString("ipsum", withOptions: []).first)
        let theirs = selection.bounds(for: page)
        #expect(abs(theirs.midX - (frame.x + frame.width / 2)) < 2 && abs(theirs.midY - (frame.y + frame.height / 2)) < 4)

        // The first line ends "… incididunt ut" and the second starts "labore".
        let wrapped = try editor.findText("incididunt ut labore", onPageAt: 0)
        #expect(wrapped.count == 1 && wrapped[0].frames.count == 2)
        #expect(try editor.findText("LOREM", onPageAt: 0).count == 1)
        #expect(try editor.findText("LOREM", onPageAt: 0, options: TextSearchOptions(isCaseSensitive: true)).isEmpty)
        #expect(try editor.findText("dolor", onPageAt: 0).count == 2)
        #expect(try editor.findText("dolor", onPageAt: 0, options: TextSearchOptions(matchesWholeWords: true)).count == 1)
        #expect(try editor.findText("[a-z]+or\\b", onPageAt: 0, options: TextSearchOptions(isRegularExpression: true)).map(\.text) == ["dolor", "tempor"])
    }

    @Test func replacingChangesEveryMatch() throws {
        let data = try Fixture.text3Pages.data
        var editor = PDFEditor(try PDFFile(data: data))
        let outcome = try editor.replaceAll("Lorem ipsum", with: "Mauris")
        #expect(outcome.count == 3 && outcome.pages == [0, 1, 2])
        let reference = try Reference(editor.serialized())
        for index in 0..<3 {
            let text = normalized(reference.texts[index])
            #expect(text.contains("Mauris dolor sit amet") && !text.contains("Lorem"))
            #expect(text.contains("Page \(index + 1)"))
        }
        // Several matches in one block, and a replacement that contains what was searched for.
        var again = PDFEditor(try PDFFile(data: data))
        let found = try again.findText("ut", onPageAt: 0, options: TextSearchOptions(matchesWholeWords: true))
        #expect(found.map(\.text) == ["ut", "Ut", "ut"])
        #expect(try again.replace(found, onPageAt: 0, with: "ut ut") == 3)
        #expect(try again.findText("ut ut", onPageAt: 0).count == 3)
    }

    // MARK: Redaction

    @Test func redactedTextIsGoneFromThePage() throws {
        let data = try Fixture.text3Pages.data
        var editor = PDFEditor(try PDFFile(data: data))
        let target = try #require(try editor.findText("consectetur adipiscing", onPageAt: 0).first)
        let result = try editor.redact(target.frames, onPageAt: 0)
        // The two words and the space between them.
        #expect(result.glyphs == 22 && result.images == 0)
        let saved = try editor.rewritten()

        let text = normalized(try Reference(saved).texts[0])
        #expect(!text.contains("consectetur") && !text.contains("adipiscing"))
        #expect(text.contains("Lorem ipsum dolor sit amet,") && text.contains("elit, sed do eiusmod"))
        let mine = try PDFEditor(PDFFile(data: saved)).pageContent(at: 0).text
        #expect(!mine.contains("consectetur") && !mine.contains("adipiscing") && mine.contains("elit"))
        // A black box where the words were, and the words after it where they were.
        let frame = target.frames[0]
        let middle = try color(at: PDFPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2), of: saved)
        #expect(middle.r < 10 && middle.g < 10 && middle.b < 10)
        let before = try PDFEditor(PDFFile(data: data)).findText("elit", onPageAt: 0)[0].frames[0]
        let after = try PDFEditor(PDFFile(data: saved)).findText("elit", onPageAt: 0)[0].frames[0]
        #expect(abs(before.x - after.x) < 0.01 && abs(before.y - after.y) < 0.01)
        #expect(try Reference(saved).texts[1] == (try Reference(data).texts[1]))
    }

    @Test func redactionLeavesNothingBehindInTheFile() throws {
        // A page whose text is written in plain letters, so it can be looked for byte by byte.
        var editor = PDFEditor(try PDFFile(data: TestPDF.paperForm()))
        let target = try #require(try editor.findText("Office use only", onPageAt: 0).first)
        try editor.redact(target.frames, onPageAt: 0)

        func holdsTheText(_ data: Data) throws -> Bool {
            let file = try PDFFile(data: data)
            return try file.objectNumbers.contains { number in
                guard let stream = try file.object(ObjectID(number)).streamValue, let decoded = try? file.decodedData(of: stream) else { return false }
                return decoded.range(of: Data("Office use only".utf8)) != nil
            }
        }
        // Saved by appending, the old instructions are still earlier in the file. Written
        // out afresh, they are not.
        #expect(try holdsTheText(editor.serialized()))
        #expect(try !holdsTheText(editor.rewritten()))
        #expect(try !Reference(editor.rewritten()).texts[0].contains("Office"))
        #expect(try Reference(editor.rewritten()).texts[0].contains("Comments"))
    }

    @Test func marksAreAppliedAndRemoved() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.outlineAnnotations.data))
        let heading = try #require(try editor.findText("Chapter 1", onPageAt: 0).first)
        let geometry = try editor.geometry(ofPageAt: 0)
        try editor.addAnnotation(Annotation(kind: .redact, rect: geometry.pageRect(heading.frames[0])), toPageAt: 0)
        #expect(try editor.redactionMarks(onPageAt: 0).count == 1)
        // Until applied, a mark removes nothing.
        #expect(try Reference(editor.serialized()).texts[0].contains("Chapter 1"))
        #expect(try Reference(editor.serialized()).document.page(at: 0)?.annotations.contains { $0.type == "Redact" } == true)

        let annotationsBefore = try editor.annotations(onPageAt: 0).count
        let result = try editor.applyRedactions()
        #expect(result.glyphs == 9)
        #expect(try editor.redactionMarks(onPageAt: 0).isEmpty)
        #expect(try editor.annotations(onPageAt: 0).count == annotationsBefore - 1)
        #expect(try !Reference(editor.rewritten()).texts[0].contains("Chapter 1"))
        #expect(try Reference(editor.rewritten()).texts[0].contains("Introduction"))
    }

    @Test func textInsideARepeatedFormIsRemovedOnlyWhereMarked() throws {
        // One form with a word in it, drawn twice on one page and once on another.
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: Array(repeating: PDFRectangle(x: 0, y: 0, width: 400, height: 300), count: 2))))
        let font = editor.add(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding")])
        let form = editor.add(.stream(PDFStream(
            dictionary: ["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": [0, 0, 200, 40], "Resources": ["Font": ["F1": .reference(font)]]],
            data: Data("BT /F1 20 Tf 0 10 Td (SECRET code) Tj ET".utf8)
        )))
        let pages = try editor.pageIDs()
        for (page, drawing) in zip(pages, ["q 1 0 0 1 50 200 cm /Fm Do Q q 1 0 0 1 50 100 cm /Fm Do Q", "q 1 0 0 1 50 200 cm /Fm Do Q"]) {
            let content = editor.add(.stream(PDFStream(data: Data(drawing.utf8))))
            try editor.update(page) { dictionary in
                dictionary["Contents"] = .reference(content)
                dictionary["Resources"] = ["XObject": ["Fm": .reference(form)]]
            }
        }
        let found = try editor.findText("SECRET", onPageAt: 0)
        #expect(found.count == 2 && !found[0].isReplaceable)
        let upper = try #require(found.max { $0.frames[0].y < $1.frames[0].y })
        try editor.redact(upper.frames, onPageAt: 0)
        let saved = try editor.rewritten()
        let reference = try Reference(saved)
        // The upper one is gone, with the rest of its line kept; the lower one and the other page are whole.
        #expect(normalized(reference.texts[0]) == "code SECRET code")
        #expect(normalized(reference.texts[1]) == "SECRET code")
    }

    @Test func picturesArePaintedOverWhereMarked() throws {
        var editor = PDFEditor.empty()
        try editor.insertImagePage(try picture(red: 0, green: 1, blue: 0, width: 200, height: 100), options: ImageDocumentOptions(paper: .fixed(PageSize(width: 400, height: 200))))
        editor = PDFEditor(try PDFFile(data: editor.rewritten()))
        // The right half of the picture.
        let result = try editor.redact([PDFRectangle(x: 200, y: 0, width: 200, height: 200)], onPageAt: 0)
        #expect(result.images == 1)
        let saved = try editor.rewritten()
        let left = try color(at: PDFPoint(x: 100, y: 100), of: saved), right = try color(at: PDFPoint(x: 300, y: 100), of: saved)
        #expect(left.g > 240 && left.r < 20)
        #expect(right.r < 10 && right.g < 10 && right.b < 10)
        // The picture itself no longer holds what was covered: its own right half is black.
        let file = try PDFFile(data: saved)
        let image = try #require(try PDFEditor(file).pageContent(at: 0).images.first)
        let imageID = try #require(image.objectID)
        let stream = try #require(try file.object(imageID).streamValue)
        let samples = try file.decodedData(of: stream)
        let width = try #require(stream.dictionary["Width"]?.intValue)
        let rightPixel = (50 * width + 150) * 3, leftPixel = (50 * width + 50) * 3
        #expect(samples[rightPixel] < 5 && samples[rightPixel + 1] < 5)
        #expect(samples[leftPixel + 1] > 240)

        // Wholly covered, a picture is removed.
        var whole = PDFEditor(try PDFFile(data: Fixture.image1Page.data))
        let frame = try #require(try whole.pageContent(at: 0).images.first).frame
        try whole.redact([PDFRectangle(x: frame.x - 5, y: frame.y - 5, width: frame.width + 10, height: frame.height + 10)], onPageAt: 0)
        #expect(try whole.pageContent(at: 0).images.isEmpty)
    }

    // MARK: Text for scanned pages

    @Test func aScannedPageBecomesSearchable() throws {
        // A page of text as a picture, the way a scanner would deliver it.
        let source = try #require(PDFDocument(data: try Fixture.text3Pages.data)?.page(at: 0))
        let scale = 2.0
        let size = source.bounds(for: .cropBox).size
        let context = try #require(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        source.draw(with: .cropBox, to: context)
        let scan = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, scan, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        var editor = PDFEditor(try PDFFile(data: try PDFGenerator.document(fromImageData: output as Data)))
        #expect(try !editor.hasText(onPageAt: 0))
        let before = try editor.serialized()
        let lines = TextRecognizer.recognize(in: scan, languages: ["en"])
        #expect(lines.count >= 4)
        try editor.addTextLayer(lines, toPageAt: 0)
        #expect(try editor.hasText(onPageAt: 0))
        let saved = try editor.serialized()

        let reference = try Reference(saved)
        let text = normalized(reference.texts[0])
        #expect(text.contains("Page 1") && text.contains("Lorem ipsum dolor sit amet") && text.contains("commodo consequat"))
        // The page looks exactly as before: the text is there but shows nothing.
        #expect(reference.pixels(ofPage: 0) == (try Reference(before).pixels(ofPage: 0)))
        // And it is found where the words are in the picture.
        let original = try #require(try PDFEditor(PDFFile(data: Fixture.text3Pages.data)).findText("consectetur", onPageAt: 0).first?.frames.first)
        let found = try #require(try editor.findText("consectetur", onPageAt: 0).first?.frames.first)
        #expect(abs(found.x - original.x) < 12 && abs(found.y - original.y) < 6)
        let selection = try #require(reference.document.findString("consectetur", withOptions: []).first)
        let bounds = selection.bounds(for: try #require(reference.document.page(at: 0)))
        #expect(abs(bounds.midX - (original.x + original.width / 2)) < 12)
    }
}
