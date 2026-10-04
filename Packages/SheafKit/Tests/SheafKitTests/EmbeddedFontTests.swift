import CoreGraphics
import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct EmbeddedFontTests {
    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every font on the first page, by the kind of font it is.
    private func fontKinds(_ data: Data) throws -> [String] {
        let editor = PDFEditor(try PDFFile(data: data))
        return try editor.interpret(pageAt: 0).fonts.map { "\($0.kind)" }
    }

    @Test func aCutDownFontFileIsStillAFont() throws {
        let tables = try #require(FontProgram.trueTypeTables(fontName: "Georgia"))
        let source = TrueTypeTables(tables: tables)
        #expect(source.unitsPerEm == 2048)
        #expect(source.glyphCount > 200)

        let shaped = TextOutliner.shape("Sheaf", fontName: "Georgia", fontSize: 12)
        let wanted = Set(shaped.glyphs.map { Int($0.index) })
        let subset = try #require(source.subset(keeping: wanted))
        let whole = try #require(source.subset(keeping: Set(0..<source.glyphCount)))
        #expect(subset.count < whole.count / 5)

        // The system reads it as a font with the same glyphs in the same places.
        let provider = try #require(CGDataProvider(data: subset as CFData))
        let font = try #require(CGFont(provider))
        #expect(font.numberOfGlyphs == source.glyphCount)
        #expect(font.unitsPerEm == 2048)
        var glyphs = shaped.glyphs.map { CGGlyph($0.index) }
        var boxes = [CGRect](repeating: .zero, count: glyphs.count)
        #expect(font.getGlyphBBoxes(glyphs: &glyphs, count: glyphs.count, bboxes: &boxes))
        #expect(boxes.allSatisfy { $0.width > 0 && $0.height > 0 })
        // A glyph that was left out is there but empty.
        let other = TextOutliner.shape("Q", fontName: "Georgia", fontSize: 12).glyphs[0].index
        var left = [CGGlyph(other)]
        var leftBox = [CGRect.zero]
        _ = font.getGlyphBBoxes(glyphs: &left, count: 1, bboxes: &leftBox)
        #expect(leftBox[0].width == 0)
    }

    @Test func fontsOfOtherKindsAreNotCutDown() {
        // A font that is not installed, and the system font, which varies along axes.
        #expect(FontProgram.trueTypeTables(fontName: "NoSuchFont-Regular") == nil)
        #expect(EmbeddedFont(fontName: ".SFNS-Regular") == nil)
    }

    @Test func newTextCarriesItsFont() throws {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 400, height: 300)])))
        try editor.addText("Zażółć gęślą jaźń, said the fox.", toPageAt: 0, at: PDFPoint(x: 40, y: 250), fontName: "Georgia", fontSize: 14)
        let saved = try editor.serialized()

        // The font is in the file as a font, not as drawings of letters.
        let reopened = PDFEditor(try PDFFile(data: saved))
        let fonts = try reopened.interpret(pageAt: 0).fonts
        #expect(fonts.count == 1)
        #expect(fonts.allSatisfy { $0.kind == .composite && $0.isEmbedded && $0.isReliable })
        #expect(fonts[0].baseName == "Georgia")

        // Both readers get the text back, accents and all.
        let page = try #require(PDFDocument(data: saved)?.page(at: 0))
        #expect(normalized(page.string ?? "") == "Zażółć gęślą jaźń, said the fox.")
        let block = try #require(try reopened.pageContent(at: 0).blocks.first)
        #expect(block.text == "Zażółć gęślą jaźń, said the fox.")
        #expect(block.isEditable)
        #expect(block.installedFontName == "Georgia")
        #expect(abs(block.fontSize - 14) < 0.01)

        // And it draws: there is ink where the text is.
        let image = try #require(Reference.pixels(of: page, fullSize: true))
        #expect(image.contains { $0 < 90 })
    }

    @Test func textInACarriedFontCanBeChangedAgain() throws {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 400, height: 300)])))
        try editor.addText("One two three", toPageAt: 0, at: PDFPoint(x: 40, y: 250), fontName: "Georgia", fontSize: 14)
        var block = try #require(try editor.pageContent(at: 0).blocks.first)
        // Letters the cut-down font has are set in it; the word with new letters brings its own.
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: "One two three, then quickly six")
        block = try #require(try editor.pageContent(at: 0).blocks.first)
        #expect(block.text == "One two three, then quickly six")
        let page = try #require(PDFDocument(data: try editor.serialized())?.page(at: 0))
        #expect(normalized(page.string ?? "") == "One two three, then quickly six")
    }

    @Test func moreTextInAFontAddsToTheFontThatIsThere() throws {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [
            PDFRectangle(x: 0, y: 0, width: 400, height: 300), PDFRectangle(x: 0, y: 0, width: 400, height: 300),
        ])))
        try editor.addText("First words", toPageAt: 0, at: PDFPoint(x: 40, y: 250), fontName: "Georgia", fontSize: 14)
        let first = try #require(editor.typedFonts["Georgia"]?.objects)
        // More text, with letters the font did not have yet, on another page.
        try editor.addText("Quite a jumble of extra glyphs", toPageAt: 1, at: PDFPoint(x: 40, y: 250), fontName: "Georgia", fontSize: 14)
        let second = try #require(editor.typedFonts["Georgia"]?.objects)
        #expect(second.font == first.font && second.file == first.file && second.name == first.name)
        #expect(second.codeCount > first.codeCount)

        // One font in the file, and both pages read right with it.
        let saved = try editor.rewritten()
        let reopened = PDFEditor(try PDFFile(data: saved))
        let fonts = Set(try (0..<2).flatMap { try reopened.interpret(pageAt: $0).fontIDs.compactMap(\.self) })
        #expect(fonts.count == 1)
        let reference = try Reference(saved)
        #expect(reference.texts == ["First words", "Quite a jumble of extra glyphs"])
        // An earlier state of the document, as Undo keeps it, still reads right too.
        var earlier = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 400, height: 300)])))
        try earlier.addText("First words", toPageAt: 0, at: PDFPoint(x: 40, y: 250), fontName: "Georgia", fontSize: 14)
        let undone = earlier
        try earlier.addText("Second", toPageAt: 0, at: PDFPoint(x: 40, y: 200), fontName: "Georgia", fontSize: 14)
        #expect(try Reference(undone.serialized()).texts == ["First words"])
    }

    @Test func oneGlyphCanStandForDifferentCharacters() throws {
        // A space and a no-break space share a glyph but must copy as what they are.
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 400, height: 300)])))
        try editor.addText("a b\u{00A0}c", toPageAt: 0, at: PDFPoint(x: 40, y: 250), fontName: "Georgia", fontSize: 14)
        let glyphs = try editor.interpret(pageAt: 0).glyphs
        #expect(glyphs.compactMap(\.text).joined() == "a b\u{00A0}c")
    }
}
