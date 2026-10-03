import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import SheafKit
import Testing
import UniformTypeIdentifiers

@Suite struct AnnotationTests {
    private func editor(_ fixture: Fixture = .text3Pages) throws -> PDFEditor {
        PDFEditor(try PDFFile(data: fixture.data))
    }

    /// One of each kind this engine creates, placed on a Letter page.
    static func samples() -> [Annotation] {
        var highlight = Annotation(kind: .highlight, rect: PDFRectangle(x: 72, y: 600, width: 200, height: 30))
        highlight.quads = [PDFRectangle(x: 72, y: 615, width: 200, height: 14), PDFRectangle(x: 72, y: 600, width: 120, height: 14)]
        highlight.color = .yellow

        var underline = Annotation(kind: .underline, rect: PDFRectangle(x: 72, y: 560, width: 150, height: 14))
        underline.quads = [underline.rect]
        underline.color = .green

        var strike = Annotation(kind: .strikeOut, rect: PDFRectangle(x: 72, y: 540, width: 150, height: 14))
        strike.quads = [strike.rect]
        strike.color = .red

        var note = Annotation(kind: .note, rect: PDFRectangle(x: 400, y: 700, width: 20, height: 20))
        note.contents = "Remember this"
        note.color = .yellow

        var text = Annotation(kind: .freeText, rect: PDFRectangle(x: 300, y: 500, width: 220, height: 60))
        text.contents = "Текст и text"
        text.color = .blue
        text.fillColor = PDFColor(red: 1, green: 1, blue: 0.8)
        text.fontSize = 18
        text.alignment = .center
        text.fontName = "Helvetica-Bold"

        var square = Annotation(kind: .square, rect: PDFRectangle(x: 100, y: 300, width: 120, height: 80))
        square.color = .red
        square.fillColor = .orange
        square.lineWidth = 4
        square.opacity = 0.5

        var circle = Annotation(kind: .circle, rect: PDFRectangle(x: 260, y: 300, width: 100, height: 80))
        circle.color = .purple
        circle.lineWidth = 2

        var line = Annotation(kind: .line, rect: PDFRectangle(x: 100, y: 200, width: 200, height: 50))
        line.lineStart = PDFPoint(x: 100, y: 200)
        line.lineEnd = PDFPoint(x: 300, y: 250)
        line.endEnding = .closedArrow
        line.color = .blue
        line.lineWidth = 3

        var ink = Annotation(kind: .ink, rect: PDFRectangle(x: 400, y: 200, width: 100, height: 60))
        ink.paths = [[PDFPoint(x: 400, y: 200), PDFPoint(x: 430, y: 260), PDFPoint(x: 460, y: 210), PDFPoint(x: 500, y: 255)], [PDFPoint(x: 450, y: 230)]]
        ink.color = .black
        ink.lineWidth = 2.5

        var stamp = Annotation(kind: .stamp, rect: PDFRectangle(x: 350, y: 100, width: 180, height: 50))
        stamp.stamp = .text("Approved")
        stamp.color = .green

        var link = Annotation(kind: .link, rect: PDFRectangle(x: 72, y: 100, width: 100, height: 20))
        link.link = .url("https://example.com/path?q=1")

        return [highlight, underline, strike, note, text, square, circle, line, ink, stamp, link]
    }

    @Test func everyKindIsSavedAndReadBack() throws {
        var editor = try editor()
        let samples = Self.samples().map { sample -> Annotation in
            var copy = sample
            copy.author = "Tester"
            copy.modified = Date(timeIntervalSince1970: 1_790_000_000)
            return copy
        }
        var ids: [ObjectID] = []
        for sample in samples { ids.append(try editor.addAnnotation(sample, toPageAt: 0)) }
        let saved = try editor.serialized()
        #expect(saved.prefix(try Fixture.text3Pages.data.count) == (try Fixture.text3Pages.data))

        // The engine reads back what it wrote.
        let file = try PDFFile(data: saved)
        let read = try file.annotations(forPage: try file.pageIDs()[0])
        #expect(read.count == samples.count)
        for (original, (found, id)) in zip(samples, zip(read, ids)) {
            var expected = original
            expected.objectID = id
            // A stamp's picture is kept in the file, not rebuilt from a description.
            if expected.kind == .stamp { expected.stamp = nil }
            // Frames of lines, drawings and text marks come from their geometry.
            if let frame = PDFRectangle(enclosing: expected.paths.flatMap { $0 } + [expected.lineStart, expected.lineEnd].compactMap { $0 }) {
                expected.rect = frame
            }
            #expect(found.kind == expected.kind)
            #expect(found.objectID == id)
            #expect(found.contents == expected.contents)
            #expect(found.author == "Tester")
            #expect(found.modified == expected.modified)
            #expect(found.color == expected.color, "\(expected.kind)")
            #expect(found.fillColor == expected.fillColor, "\(expected.kind)")
            #expect(found.opacity == expected.opacity)
            #expect(found.quads == expected.quads)
            #expect(found.paths == expected.paths)
            #expect(found.lineStart == expected.lineStart && found.lineEnd == expected.lineEnd)
            #expect(found.endEnding == expected.endEnding)
            #expect(found.link == expected.link)
            if expected.kind == .freeText {
                #expect(found.fontSize == 18 && found.alignment == .center && found.fontName == "Helvetica-Bold")
            }
            if [.square, .circle, .line, .ink].contains(expected.kind) { #expect(found.lineWidth == expected.lineWidth) }
            if !expected.isTextMarkup { #expect(found.rect == expected.rect, "\(expected.kind)") }
        }

        // PDFKit sees the same annotations, in order, where they were put.
        let page = try #require(try Reference(saved).document.page(at: 0))
        #expect(page.annotations.map { $0.type ?? "" } == ["Highlight", "Underline", "StrikeOut", "Text", "FreeText", "Square", "Circle", "Line", "Ink", "Stamp", "Link"])
        #expect(page.annotations[3].contents == "Remember this")
        #expect(page.annotations[4].contents == "Текст и text")
        #expect(page.annotations[10].url?.absoluteString == "https://example.com/path?q=1")
        #expect(page.annotations[5].bounds == CGRect(x: 100, y: 300, width: 120, height: 80))
        #expect(page.annotations[0].userName == "Tester")
    }

    @Test func everyVisibleKindActuallyDraws() throws {
        let blank = try PDFGenerator.blankDocument(pageSize: .letter)
        let empty = try #require(try Reference(blank).pixels(ofPage: 0))
        for sample in Self.samples() where sample.kind != .link {
            var editor = PDFEditor(try PDFFile(data: blank))
            try editor.addAnnotation(sample, toPageAt: 0)
            let drawn = try #require(try Reference(editor.serialized()).pixels(ofPage: 0))
            #expect(drawn != empty, "\(sample.kind) drew nothing")
        }
    }

    @Test func appearancePreviewMatchesTheSavedPage() throws {
        // The app draws annotations being edited from the preview, so it has to look like
        // the saved document does.
        for sample in Self.samples() {
            guard let appearance = sample.appearance() else {
                #expect(sample.kind == .link)
                continue
            }
            let preview = try #require(PDFDocument(data: appearance.previewPDF()))
            #expect(preview.pageCount == 1)
            let box = try #require(preview.page(at: 0)).bounds(for: .mediaBox)
            #expect(abs(box.width - max(appearance.bounds.width, 1)) < 0.01 && abs(box.height - max(appearance.bounds.height, 1)) < 0.01)
            #expect(Reference.pixels(of: preview.page(at: 0)) != nil)
        }
    }

    @Test func annotationsCanBeChangedAndRemoved() throws {
        var editor = try editor()
        var square = Self.samples()[5]
        let id = try editor.addAnnotation(square, toPageAt: 1)
        var note = Self.samples()[3]
        let noteID = try editor.addAnnotation(note, toPageAt: 1)
        var reply = Annotation(kind: .note, rect: note.rect)
        reply.contents = "Agreed"
        reply.replyTo = noteID
        let replyID = try editor.addAnnotation(reply, toPageAt: 1)
        var second = reply
        second.contents = "Me too"
        second.replyTo = replyID
        try editor.addAnnotation(second, toPageAt: 1)
        #expect(try editor.annotations(onPageAt: 1).count == 4)
        #expect(try editor.annotations(onPageAt: 1)[2].replyTo == noteID)

        square = try editor.annotations(onPageAt: 1)[0]
        square.translate(dx: 50, dy: -20)
        square.color = .blue
        square.contents = "A comment on the box"
        try editor.updateAnnotation(square, onPageAt: 1)
        note = try editor.annotations(onPageAt: 1)[1]
        note.contents = "Changed"
        try editor.updateAnnotation(note, onPageAt: 1)

        let afterUpdate = try #require(try Reference(editor.serialized()).document.page(at: 1))
        #expect(afterUpdate.annotations[0].bounds == CGRect(x: 150, y: 280, width: 120, height: 80))
        #expect(afterUpdate.annotations[0].contents == "A comment on the box")
        #expect(afterUpdate.annotations[1].contents == "Changed")
        #expect(try editor.annotations(onPageAt: 1)[0].objectID == id)

        // Removing the note takes the whole thread of replies with it.
        try editor.removeAnnotation(noteID, fromPageAt: 1)
        #expect(try editor.annotations(onPageAt: 1).map(\.objectID) == [id])
        try editor.removeAnnotation(id, fromPageAt: 1)
        #expect(try editor.annotations(onPageAt: 1).isEmpty)
        #expect(try Reference(editor.serialized()).document.page(at: 1)?.annotations.isEmpty == true)
    }

    @Test func resizingScalesWhatIsInside() {
        var ink = Self.samples()[8]
        ink.rect = PDFRectangle(x: 400, y: 200, width: 100, height: 60)
        ink.resize(to: PDFRectangle(x: 0, y: 0, width: 200, height: 30))
        #expect(ink.paths[0].first == PDFPoint(x: 0, y: 0))
        #expect(ink.paths[0].last == PDFPoint(x: 200, y: 27.5))
        var line = Self.samples()[7]
        line.resize(to: PDFRectangle(x: 100, y: 200, width: 400, height: 50))
        #expect(line.lineEnd == PDFPoint(x: 500, y: 250))
    }

    @Test func existingAnnotationsAreUnderstood() throws {
        let file = try PDFFile(data: Fixture.outlineAnnotations.data)
        let pages = try file.pageIDs()
        let first = try file.annotations(forPage: pages[0])
        #expect(first.map(\.kind) == [.highlight, .link])
        #expect(first[0].quads.count == 1)
        #expect(first[0].color == PDFColor(red: 1, green: 1, blue: 0))
        #expect(first[1].link == .url("https://example.com"))
        let fourth = try file.annotations(forPage: pages[3])
        #expect(fourth.first?.kind == .note)
        #expect(fourth.first?.contents == "Check this heading with the editor.")
        #expect(fourth.contains { $0.kind == .other && $0.subtype == "Popup" })
        let sixth = try file.annotations(forPage: pages[5])
        #expect(sixth.first?.kind == .freeText)
        #expect(sixth.first?.contents == "Draft, do not distribute")
        let textColor = try #require(sixth.first?.color)
        #expect(textColor.red > 0.9 && textColor.green < 0.1 && textColor.blue < 0.1)
        #expect(sixth.first?.fontSize == 14)
        #expect(try file.annotations(forPage: pages[1]).first?.kind == .underline)
        #expect(try file.annotations(forPage: pages[4]).first?.kind == .strikeOut)
    }

    @Test func linksCanPointAtPages() throws {
        var editor = try editor()
        var link = Annotation(kind: .link, rect: PDFRectangle(x: 10, y: 10, width: 50, height: 20))
        link.link = .page(2)
        try editor.addAnnotation(link, toPageAt: 0)
        let saved = try editor.serialized()
        #expect(try PDFFile(data: saved).annotations(forPage: try PDFFile(data: saved).pageIDs()[0]).first?.link == .page(2))
        let reference = try Reference(saved)
        let annotation = try #require(reference.document.page(at: 0)?.annotations.first)
        #expect(annotation.destination?.page == reference.document.page(at: 2))
        link.link = .page(9)
        #expect(throws: SheafError.pageOutOfRange(9)) { try editor.addAnnotation(link, toPageAt: 0) }
    }

    @Test func stampsCanShowImagesAndSignatures() throws {
        // A 40 by 20 image: red on the left half, see-through on the right.
        let context = try #require(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let image = try StampImage(encodedImageData: png as Data)
        #expect((image.width, image.height) == (40, 20))
        #expect(image.alpha != nil)
        #expect(image.rgb.prefix(3) == Data([255, 0, 0]))

        var picture = Annotation(kind: .stamp, rect: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        picture.stamp = .image(image)
        var signature = Annotation(kind: .stamp, rect: PDFRectangle(x: 100, y: 300, width: 200, height: 80))
        signature.stamp = .strokes([[PDFPoint(x: 0, y: 0), PDFPoint(x: 0.5, y: 1), PDFPoint(x: 1, y: 0.2)]], lineWidth: 0.03)

        var typed = Annotation(kind: .stamp, rect: PDFRectangle(x: 100, y: 450, width: 200, height: 60))
        typed.stamp = .shapes(TextOutliner.outline(line: "Signed", fontName: "Snell Roundhand", fitting: PDFRectangle(x: 0, y: 0, width: 1, height: 1)))

        var editor = PDFEditor(try PDFFile(data: PDFGenerator.blankDocument(pageSize: .letter)))
        let pictureID = try editor.addAnnotation(picture, toPageAt: 0)
        try editor.addAnnotation(signature, toPageAt: 0)
        let onlyTwo = try Reference(editor.serialized()).pixels(ofPage: 0, fullSize: true)
        try editor.addAnnotation(typed, toPageAt: 0)
        let saved = try editor.serialized()
        let page = try #require(try Reference(saved).document.page(at: 0))
        #expect(page.annotations.map { $0.type ?? "" } == ["Stamp", "Stamp", "Stamp"])
        #expect(try Reference(saved).pixels(ofPage: 0, fullSize: true) != onlyTwo)

        // Render and look at the middle of each half of the picture.
        let bitmap = try #require(CGContext(
            data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        page.draw(with: .mediaBox, to: bitmap)
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        func color(x: Int, y: Int) -> [UInt8] {
            let offset = ((791 - y) * 612 + x) * 4
            return [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
        }
        #expect(color(x: 150, y: 150) == [255, 0, 0] || color(x: 150, y: 150)[0] > 230 && color(x: 150, y: 150)[1] < 40)
        #expect(color(x: 250, y: 150) == [255, 255, 255])

        // What the document stores for each stamp can be drawn on its own.
        for (index, id) in try editor.annotations(onPageAt: 0).compactMap(\.objectID).enumerated() {
            let preview = try #require(try editor.storedAppearancePreview(of: id))
            let previewPage = try #require(PDFDocument(data: preview)?.page(at: 0))
            let expected = [CGSize(width: 200, height: 100), CGSize(width: 200, height: 80), CGSize(width: 200, height: 60)][index]
            #expect(previewPage.bounds(for: .mediaBox).size == expected)
            let blank = try #require(PDFDocument(data: try PDFGenerator.blankDocument(pageSize: PageSize(width: expected.width, height: expected.height)))?.page(at: 0))
            #expect(Reference.pixels(of: previewPage, fullSize: true) != Reference.pixels(of: blank, fullSize: true))
        }
        var link = Annotation(kind: .link, rect: PDFRectangle(x: 0, y: 0, width: 10, height: 10))
        link.link = .url("https://example.com")
        #expect(try editor.storedAppearancePreview(of: try editor.addAnnotation(link, toPageAt: 0)) == nil)

        // Moving a stamp that was read from the file keeps its picture.
        let file = try PDFFile(data: saved)
        var reopened = PDFEditor(file)
        var moved = try reopened.annotations(onPageAt: 0)[0]
        #expect(moved.objectID == pictureID && moved.stamp == nil)
        moved.translate(dx: 100, dy: 0)
        try reopened.updateAnnotation(moved, onPageAt: 0)
        let after = try #require(try Reference(reopened.serialized()).document.page(at: 0))
        #expect(after.annotations[0].bounds == CGRect(x: 200, y: 100, width: 200, height: 100))
        #expect(try reopened.object(pictureID).dictionaryValue?["AP"] != nil)
    }

    @Test func textOutlinesStayInTheirBox() {
        let rect = PDFRectangle(x: 50, y: 400, width: 200, height: 100)
        for text in ["Hello, world", "Привет, мир", "日本語のテキスト", "A long line that has to wrap around because it does not fit"] {
            let outline = TextOutliner.outline(text, fontName: "Helvetica", fontSize: 14, in: rect, alignment: .left)
            #expect(!outline.elements.isEmpty, "\(text) produced no shapes")
            #expect(outline.height > 10)
            let points = outline.elements.flatMap { element -> [PDFPoint] in
                switch element {
                case .move(let point), .line(let point): [point]
                case .curve(_, _, let end): [end]
                case .close: []
                }
            }
            let frame = PDFRectangle(enclosing: points)!
            #expect(frame.x >= rect.x - 2 && frame.x + frame.width <= rect.x + rect.width + 2)
            #expect(frame.y + frame.height <= rect.y + rect.height + 1)
        }
        let wrapped = TextOutliner.outline(String(repeating: "word ", count: 30), fontName: "Helvetica", fontSize: 14, in: rect, alignment: .left)
        let single = TextOutliner.outline("word", fontName: "Helvetica", fontSize: 14, in: rect, alignment: .left)
        #expect(wrapped.height > single.height * 3)
        #expect(TextOutliner.outline("", fontName: "Helvetica", fontSize: 14, in: rect, alignment: .left).elements.isEmpty)
        #expect(!TextOutliner.outline(line: "DRAFT", fontName: "Helvetica-Bold", fitting: rect).isEmpty)
    }

    // MARK: Flattening

    // With a live document, PDFKit draws highlights, underlines and strikethroughs itself,
    // a pixel or two tighter than the stored appearance. Notes keep a fixed size on screen.
    // So those kinds can only be compared loosely; every other kind must match exactly.

    @Test func flatteningKeepsTheLookAndRemovesTheAnnotations() throws {
        var editor = try editor()
        let samples = Self.samples().filter { !$0.isTextMarkup && $0.kind != .note }
        for sample in samples { try editor.addAnnotation(sample, toPageAt: 0) }
        let before = try Reference(editor.serialized())
        #expect(try editor.flattenAnnotations(onPageAt: 0) == samples.count - 1)
        let after = try Reference(editor.serialized())
        // Only the link is left, and the page looks exactly the same.
        #expect(after.document.page(at: 0)?.annotations.map { $0.type ?? "" } == ["Link"])
        #expect(after.pixels(ofPage: 0, fullSize: true) == before.pixels(ofPage: 0, fullSize: true))
        #expect(after.texts == before.texts)
        // The other pages, which share fonts with this one, are untouched.
        #expect(after.pixels(ofPage: 1, fullSize: true) == before.pixels(ofPage: 1, fullSize: true))
        #expect(try editor.flattenAnnotations(onPageAt: 0) == 0)
    }

    @Test func flattenedTextMarksStayWhereTheyWere() throws {
        var editor = try editor()
        let samples = Self.samples().filter(\.isTextMarkup)
        for sample in samples { try editor.addAnnotation(sample, toPageAt: 0) }
        let before = try Reference(editor.serialized())
        #expect(try editor.flattenAnnotations(onPageAt: 0) == 3)
        let after = try Reference(editor.serialized())
        #expect(after.document.page(at: 0)?.annotations.isEmpty == true)
        #expect(Self.difference(before.pixels(ofPage: 0, fullSize: true), after.pixels(ofPage: 0, fullSize: true)) < 0.005)
        #expect(after.pixels(ofPage: 0, fullSize: true) != (try Reference(Fixture.text3Pages.data)).pixels(ofPage: 0, fullSize: true))
    }

    @Test func flatteningWorksOnAnnotationsFromOtherApps() throws {
        let data = try Fixture.outlineAnnotations.data
        let before = try Reference(data)
        var editor = PDFEditor(try PDFFile(data: data))
        for index in 0..<12 { try editor.flattenAnnotations(onPageAt: index) }
        let after = try Reference(editor.serialized())
        for index in 0..<12 {
            let left = after.document.page(at: index)?.annotations.map { $0.type ?? "" } ?? []
            #expect(left.allSatisfy { $0 == "Link" }, "page \(index + 1) still has \(left)")
            let change = Self.difference(before.pixels(ofPage: index, fullSize: true), after.pixels(ofPage: index, fullSize: true))
            #expect(change < 0.005, "page \(index + 1) looks different")
        }
    }

    /// The share of bytes that differ between two renderings.
    static func difference(_ a: Data?, _ b: Data?) -> Double {
        guard let a, let b, a.count == b.count, !a.isEmpty else { return 1 }
        let differing = zip(a, b).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
        return Double(differing) / Double(a.count)
    }

    @Test func aFlattenedNoteStillShows() throws {
        var editor = PDFEditor(try PDFFile(data: PDFGenerator.blankDocument(pageSize: .letter)))
        let empty = try Reference(editor.serialized()).pixels(ofPage: 0, fullSize: true)
        try editor.addAnnotation(Self.samples()[3], toPageAt: 0)
        #expect(try editor.flattenAnnotations(onPageAt: 0) == 1)
        let flattened = try Reference(editor.serialized())
        #expect(flattened.document.page(at: 0)?.annotations.isEmpty == true)
        #expect(flattened.pixels(ofPage: 0, fullSize: true) != empty)
    }

    @Test func onlyChosenAnnotationsAreFlattened() throws {
        var editor = try editor()
        let samples = Self.samples()
        let square = try editor.addAnnotation(samples[5], toPageAt: 2)
        let circle = try editor.addAnnotation(samples[6], toPageAt: 2)
        #expect(try editor.flattenAnnotations(onPageAt: 2, only: [square]) == 1)
        #expect(try editor.annotations(onPageAt: 2).map(\.objectID) == [circle])
    }

    // MARK: Bookmarks

    @Test func theTableOfContentsIsRead() throws {
        let outline = try PDFFile(data: Fixture.outlineAnnotations.data).outline()
        #expect(outline.map(\.title) == ["Introduction", "Getting Started", "Editing Text", "Working with Pages"])
        #expect(outline.map(\.pageIndex) == [0, 3, 6, 9])
        #expect(outline[1].children.map(\.title) == ["Section 2.1", "Section 2.2", "Section 2.3"])
        #expect(outline[1].children.map(\.pageIndex) == [3, 4, 5])
        #expect(outline[0].top == 792 && outline[1].children[0].top == 700)
        #expect(try PDFFile(data: Fixture.text3Pages.data).outline().isEmpty)
    }

    @Test func bookmarksCanBeAddedRenamedAndRemoved() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.outlineAnnotations.data))
        var outline = try editor.outline()
        outline[0].title = "Вступление"
        outline.remove(at: 2)
        outline[1].children.append(OutlineItem(title: "My bookmark", pageIndex: 8))
        outline[1].isExpanded = true
        outline.append(OutlineItem(title: "The end", pageIndex: 11))
        try editor.setOutline(outline)
        let saved = try editor.serialized()

        let read = try PDFFile(data: saved).outline()
        #expect(read.map(\.title) == ["Вступление", "Getting Started", "Working with Pages", "The end"])
        #expect(read.map(\.pageIndex) == [0, 3, 9, 11])
        #expect(read[1].children.map(\.title) == ["Section 2.1", "Section 2.2", "Section 2.3", "My bookmark"])
        #expect(read[1].isExpanded && !read[2].isExpanded)

        let reference = try Reference(saved)
        let root = try #require(reference.document.outlineRoot)
        #expect(root.numberOfChildren == 4)
        #expect(root.child(at: 0)?.label == "Вступление")
        #expect(root.child(at: 3)?.destination?.page == reference.document.page(at: 11))
        #expect(root.child(at: 1)?.child(at: 3)?.destination?.page == reference.document.page(at: 8))
        // An entry nobody touched still lands where it used to.
        #expect(root.child(at: 1)?.child(at: 0)?.destination?.point.y == 700)
    }

    @Test func bookmarksCanBeCreatedFromNothingAndCleared() throws {
        var editor = try editor()
        try editor.setOutline([OutlineItem(title: "Start", pageIndex: 0), OutlineItem(title: "Finish", pageIndex: 2)])
        let saved = try editor.serialized()
        let root = try #require(try Reference(saved).document.outlineRoot)
        #expect((0..<root.numberOfChildren).map { root.child(at: $0)?.label } == ["Start", "Finish"])

        var second = PDFEditor(try PDFFile(data: saved))
        try second.setOutline([])
        #expect(try PDFFile(data: second.serialized()).outline().isEmpty)
        #expect(try Reference(second.serialized()).document.outlineRoot == nil)
    }

    @Test func namedDestinationsAreFollowed() throws {
        var editor = try editor()
        let pages = try editor.pageIDs()
        let catalog = try #require(editor.catalogID)
        let leaf = editor.add(["Names": [.string(Data("chapter-2".utf8)), [.reference(pages[1]), .name("Fit")], .string(Data("chapter-3".utf8)), ["D": [.reference(pages[2]), .name("Fit")]]]])
        try editor.update(catalog) {
            $0["Names"] = ["Dests": ["Kids": [.reference(leaf)]]]
            $0["Dests"] = ["old-style": [.reference(pages[0]), .name("Fit")]]
        }
        #expect(try editor.resolveDestination(.string(Data("chapter-2".utf8)))?.first == .reference(pages[1]))
        #expect(try editor.resolveDestination(.string(Data("chapter-3".utf8)))?.first == .reference(pages[2]))
        #expect(try editor.resolveDestination(.name("old-style"))?.first == .reference(pages[0]))
        #expect(try editor.resolveDestination(.string(Data("missing".utf8))) == nil)
    }
}
