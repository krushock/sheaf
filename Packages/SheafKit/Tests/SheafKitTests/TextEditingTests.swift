import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct TextEditingTests {
    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The first page drawn at two pixels per point.
    private func pixels(_ data: Data) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let box = page.bounds(for: .cropBox)
        let width = Int(box.width * 2), height = Int(box.height * 2)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        page.draw(with: .cropBox, to: context)
        return (Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4)), width, height)
    }

    /// How many pixels differ between two renderings, inside and outside a rectangle
    /// given on the page as displayed.
    private func differences(_ a: Data, _ b: Data, around rect: PDFRectangle) throws -> (inside: Int, outside: Int) {
        let first = try pixels(a), second = try pixels(b)
        var inside = 0, outside = 0
        for y in 0..<first.height {
            for x in 0..<first.width {
                let offset = (y * first.width + x) * 4
                guard abs(Int(first.bytes[offset]) - Int(second.bytes[offset])) > 40 else { continue }
                let px = Double(x) / 2, py = Double(first.height - y) / 2
                if rect.contains(PDFPoint(x: px, y: py)) { inside += 1 } else { outside += 1 }
            }
        }
        return (inside, outside)
    }

    private func paragraph(_ editor: PDFEditor) throws -> TextBlock {
        try #require(try editor.pageContent(at: 0).blocks.first { $0.lines.count == 3 })
    }

    @Test func aWordChangesAndNothingElseDoes() throws {
        let data = try Fixture.text3Pages.data
        var editor = PDFEditor(try PDFFile(data: data))
        let block = try paragraph(editor)
        let text = block.flowingText
        #expect(text.contains("dolor sit amet"))
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: text.replacingOccurrences(of: "dolor sit", with: "color sit"))
        let saved = try editor.serialized()
        #expect(saved.prefix(data.count) == data)

        let after = try Reference(saved)
        #expect(normalized(after.texts[0]).contains("Lorem ipsum color sit amet"))
        #expect(!after.texts[0].contains("dolor sit"))
        // The rest of the page reads the same.
        #expect(after.texts[1] == (try Reference(data).texts[1]))
        #expect(normalized(after.texts[0]).contains("laboris nisi ut aliquip ex ea commodo consequat."))

        // Only the first line of the paragraph is drawn differently, and only a little of it.
        let line = block.lines[0].frame
        let changed = try differences(data, saved, around: PDFRectangle(x: line.x - 2, y: line.y - 2, width: line.width + 4, height: line.height + 4))
        #expect(changed.outside == 0, "\(changed.outside) pixels changed outside the edited line")
        // The words after the changed one shift by the difference in width of one letter.
        #expect(changed.inside > 10, "\(changed.inside) pixels changed in the edited line")

        // The engine reads its own result the same way, still as three lines.
        let again = try paragraph(PDFEditor(try PDFFile(data: saved)))
        #expect(again.lines.count == 3)
        #expect(again.lines[0].text.hasPrefix("Lorem ipsum color sit amet"))
        #expect(again.lines[1].text == block.lines[1].text && again.lines[2].text == block.lines[2].text)
        #expect(abs(again.lines[0].frame.x - block.lines[0].frame.x) < 0.5)
    }

    @Test func charactersTheFontLacksUseAnInstalledFont() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        let block = try paragraph(editor)
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: block.flowingText.replacingOccurrences(of: "Lorem ipsum", with: "Жизнь ipsum"))
        let saved = try editor.serialized()
        let text = normalized(try Reference(saved).texts[0])
        #expect(text.contains("Жизнь ipsum dolor sit amet"))
        // The new word is in a font made for it; the words around it keep theirs.
        let line = try paragraph(PDFEditor(try PDFFile(data: saved))).lines[0]
        let fonts = Set(line.glyphs.filter { !$0.isImplied }.map(\.font))
        #expect(fonts.count == 2)
    }

    @Test func longerTextRunsOnToNewLines() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        let block = try paragraph(editor)
        let addition = " and here come a good many more words than the line has room for, so that the rest has to move down"
        let edited = block.flowingText.replacingOccurrences(of: "dolor sit amet,", with: "dolor sit amet" + addition + ",")
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: edited)
        let saved = try editor.serialized()

        #expect(normalized(try Reference(saved).texts[0]).contains(normalized(edited)))
        let after = try paragraph0(PDFEditor(try PDFFile(data: saved)), startingWith: "Lorem")
        #expect(after.lines.count > block.lines.count)
        // No line runs past the paragraph's right edge, and lines keep their spacing.
        let right = block.frame.x + block.frame.width
        for line in after.lines { #expect(line.frame.x + line.frame.width <= right + 1) }
        let drops = zip(after.lines, after.lines.dropFirst()).map { $0.baseline - $1.baseline }
        let first = try #require(drops.first)
        #expect(drops.allSatisfy { abs($0 - first) < 0.5 })
        #expect(normalized(after.flowingText) == normalized(edited))
    }

    private func paragraph0(_ editor: PDFEditor, startingWith prefix: String) throws -> TextBlock {
        try #require(try editor.pageContent(at: 0).blocks.first { $0.text.hasPrefix(prefix) })
    }

    @Test func shorterTextLeavesLaterLinesAlone() throws {
        let data = try Fixture.text3Pages.data
        var editor = PDFEditor(try PDFFile(data: data))
        let block = try paragraph(editor)
        // Words go from the last line only.
        let last = block.lines[2].text
        let edited = block.flowingText.replacingOccurrences(of: last, with: String(last.prefix(12)))
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: edited)
        let after = try paragraph(PDFEditor(try PDFFile(data: editor.serialized())))
        #expect(after.lines[0].text == block.lines[0].text && after.lines[1].text == block.lines[1].text)
        #expect(after.lines[2].text == String(last.prefix(12)).trimmingCharacters(in: .whitespaces))
        // An edit that changes nothing writes nothing.
        var untouched = PDFEditor(try PDFFile(data: data))
        try untouched.replaceText(ofBlock: block.id, onPageAt: 0, with: block.flowingText)
        #expect(!untouched.hasChanges)
    }

    @Test func textCanBeEditedTwice() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        var block = try paragraph(editor)
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: block.flowingText.replacingOccurrences(of: "Lorem", with: "Lorem lorem"))
        block = try paragraph0(editor, startingWith: "Lorem lorem")
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: block.flowingText.replacingOccurrences(of: "Lorem lorem", with: "More"))
        let text = normalized(try Reference(editor.serialized()).texts[0])
        #expect(text.contains("More ipsum dolor sit amet") && !text.contains("Lorem"))
    }

    @Test func blocksCanBeMovedRecoloredAndRemoved() throws {
        let data = try Fixture.text3Pages.data
        var editor = PDFEditor(try PDFFile(data: data))
        let before = try editor.pageContent(at: 0)
        let heading = try #require(before.blocks.first { $0.text == "Page 1" })
        try editor.moveText(ofBlock: heading.id, onPageAt: 0, dx: 120, dy: -300)
        var content = try editor.pageContent(at: 0)
        var moved = try #require(content.blocks.first { $0.text == "Page 1" })
        #expect(abs(moved.frame.x - heading.frame.x - 120) < 0.01 && abs(moved.frame.y - heading.frame.y + 300) < 0.01)
        #expect(abs(moved.frame.width - heading.frame.width) < 0.01)

        try editor.setTextColor(.red, ofBlock: moved.id, onPageAt: 0)
        content = try editor.pageContent(at: 0)
        moved = try #require(content.blocks.first { $0.text == "Page 1" })
        #expect(moved.lines[0].glyphs.allSatisfy { $0.color == .red })
        let saved = try editor.serialized()
        // Where the heading was is empty; where it is now is red.
        let was = try differences(data, saved, around: heading.frame)
        #expect(was.inside > 200)
        #expect(normalized(try Reference(saved).texts[0]).contains("Page 1"))

        try editor.removeText(ofBlock: moved.id, onPageAt: 0)
        let text = try Reference(editor.serialized()).texts[0]
        #expect(!text.contains("Page 1") && text.contains("Lorem ipsum"))
        #expect(try editor.pageContent(at: 0).blocks.count == before.blocks.count - 1)
    }

    @Test func aBlockCanBeSetInAnotherFontAndSize() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        let block = try paragraph(editor)
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: block.flowingText, restyle: TextRestyle(fontName: "Georgia", fontSize: 16, color: .blue))
        let after = try paragraph0(editor, startingWith: "Lorem")
        #expect(after.lines.count > 3)
        #expect(after.lines.allSatisfy { abs($0.fontSize - 16) < 0.01 })
        #expect(after.lines[0].glyphs.allSatisfy { $0.color == .blue })
        #expect(normalized(after.flowingText) == normalized(block.flowingText))
        #expect(normalized(try Reference(editor.serialized()).texts[0]).contains(normalized(block.flowingText)))
    }

    /// The Bash manual that comes with macOS, set by TeX: no space characters, only
    /// gaps; paragraphs told apart by their first lines being set in; lines justified by
    /// stretching and squeezing.
    private static let manual = "/usr/share/doc/bash/bashref.pdf"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: manual)))
    func aChangeStaysInItsParagraphOnAPageSetByTeX() throws {
        var editor = PDFEditor(try PDFFile(data: try Data(contentsOf: URL(fileURLWithPath: Self.manual))))
        func block(_ editor: PDFEditor) throws -> TextBlock {
            try #require(try editor.pageContent(at: 11).blocks.first { $0.text.contains("Quoting is used") })
        }
        let before = try block(editor)
        #expect(before.lines.count == 10)
        #expect(before.alignment == .justified)
        #expect(before.paragraphStarts.enumerated().filter(\.element).map(\.offset) == [0, 3, 8])
        #expect(abs(before.indents.first - 14.94) < 0.1 && before.indents.rest < 0.1)
        #expect(before.installedFontName.contains("Times"))
        #expect(before.flowingText.components(separatedBy: "\n").count == 3)

        try editor.replaceText(ofBlock: before.id, onPageAt: 11, with: before.flowingText.replacingOccurrences(of: "to remove the", with: "to take the"))
        let after = try block(editor)
        // Words keep their spaces though the page never had any to copy.
        #expect(after.lines[0].text.hasPrefix("Quoting is used to take the special meaning"))
        // The paragraph is set again; the two after it are exactly as they were.
        #expect(after.lines.count == 10)
        for index in 3..<10 {
            #expect(after.lines[index].text == before.lines[index].text)
            #expect(abs(after.lines[index].baseline - before.lines[index].baseline) < 0.01)
            #expect(abs(after.lines[index].frame.width - before.lines[index].frame.width) < 0.01)
        }
        // And PDFKit reads the page the same but for the word.
        let page = try #require(PDFDocument(data: try editor.serialized())?.page(at: 11))
        #expect(normalized(page.string ?? "").contains("Quoting is used to take the special meaning of certain characters or words to the shell."))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: manual)))
    func aLongerParagraphMovesTheOnesBelowItDownWhole() throws {
        var editor = PDFEditor(try PDFFile(data: try Data(contentsOf: URL(fileURLWithPath: Self.manual))))
        let before = try #require(try editor.pageContent(at: 11).blocks.first { $0.text.contains("Quoting is used") })
        let longer = before.flowingText.replacingOccurrences(of: "parameter expansion.", with: "parameter expansion, which this sentence now goes on about at some length so that it needs another line.")
        try editor.replaceText(ofBlock: before.id, onPageAt: 11, with: longer)
        let after = try #require(try editor.pageContent(at: 11).blocks.first { $0.text.contains("Quoting is used") })
        // One more line. The heading below is now so close that it reads as part of the block.
        #expect(after.lines.count >= 11)
        // The later paragraphs keep their lines, one line lower.
        for index in 3..<10 {
            #expect(after.lines[index + 1].text == before.lines[index].text)
            #expect(abs(after.lines[index + 1].frame.width - before.lines[index].frame.width) < 0.01)
            #expect(abs(before.lines[index].baseline - after.lines[index + 1].baseline - before.leading) < 0.2)
        }
    }

    @Test func newTextIsAddedToThePage() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.addText("Added by hand\nВторая строка", toPageAt: 1, at: PDFPoint(x: 100, y: 300), fontName: "Helvetica", fontSize: 14, color: .blue)
        try editor.addText("A longer note that has to wrap because it is given a narrow column to fit in.", toPageAt: 1, at: PDFPoint(x: 100, y: 200), width: 150)
        let saved = try editor.serialized()
        let text = normalized(try Reference(saved).texts[1])
        #expect(text.contains("Added by hand") && text.contains("Вторая строка") && text.contains("narrow column to fit in."))
        let content = try PDFEditor(PDFFile(data: saved)).pageContent(at: 1)
        let added = try #require(content.blocks.first { $0.text.hasPrefix("Added by hand") })
        #expect(added.lines.count == 2)
        // The top of the first line sits at the point asked for.
        #expect(abs(added.frame.x - 100) < 1 && abs(added.frame.y + added.frame.height - 300) < 4)
        let wrapped = try #require(content.blocks.first { $0.text.hasPrefix("A longer note") })
        #expect(wrapped.lines.count >= 3 && wrapped.frame.width <= 151)
        // Added text can be edited like any other.
        var again = PDFEditor(try PDFFile(data: saved))
        try again.replaceText(ofBlock: added.id, onPageAt: 1, with: "Added by hand, then changed\nВторая строка")
        #expect(normalized(try Reference(again.serialized()).texts[1]).contains("Added by hand, then changed"))
    }

    @Test func shortLinesStayLinesOfTheirOwn() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        let address = "MS ALEX SAMPLE\n12 EXAMPLE ROAD\nSPRINGFIELD\n4300"
        try editor.addText(address, toPageAt: 1, at: PDFPoint(x: 100, y: 300), fontName: "Helvetica", fontSize: 12)
        let block = try #require(try editor.pageContent(at: 1).blocks.first { $0.text.hasPrefix("MS ALEX") })
        #expect(block.lines.count == 4)
        // An address is four lines, not a sentence that happens to be broken in three places.
        #expect(block.flowingText == address)
        // Changing a word leaves the other lines where they are.
        try editor.replaceText(ofBlock: block.id, onPageAt: 1, with: address.replacingOccurrences(of: "12 EXAMPLE", with: "27 EXAMPLE"))
        let changed = try #require(try editor.pageContent(at: 1).blocks.first { $0.text.hasPrefix("MS ALEX") })
        #expect(changed.lines.map(\.text) == ["MS ALEX SAMPLE", "27 EXAMPLE ROAD", "SPRINGFIELD", "4300"])
        // Running text still runs on: the three long lines of the page's paragraph are one.
        let prose = try paragraph(editor)
        #expect(!prose.flowingText.contains("\n"))
    }

    @Test func aBlockIsSetAgainInANarrowerOrWiderBox() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        let block = try paragraph(editor)
        let words = normalized(block.text)
        let left = block.frame.x, right = block.frame.x + block.frame.width
        // Half as wide: the same words on about twice as many lines, the top where it was.
        try editor.replaceText(ofBlock: block.id, onPageAt: 0, with: block.flowingText, restyle: TextRestyle(left: left, right: left + block.frame.width / 2))
        var narrow = try #require(try editor.pageContent(at: 0).blocks.first { normalized($0.text) == words })
        #expect(narrow.lines.count >= 5 && narrow.frame.width <= block.frame.width / 2 + 1)
        #expect(abs(narrow.frame.x - left) < 0.5 && abs(narrow.frame.y + narrow.frame.height - block.frame.y - block.frame.height) < 0.5)
        // The left side moved in as well.
        try editor.replaceText(ofBlock: narrow.id, onPageAt: 0, with: narrow.flowingText, restyle: TextRestyle(left: left + 60, right: left + 60 + block.frame.width / 2))
        narrow = try #require(try editor.pageContent(at: 0).blocks.first { normalized($0.text) == words })
        #expect(abs(narrow.frame.x - left - 60) < 0.5)
        // And back to the width it had: the lines it had.
        try editor.replaceText(ofBlock: narrow.id, onPageAt: 0, with: narrow.flowingText, restyle: TextRestyle(left: left, right: right))
        let wide = try #require(try editor.pageContent(at: 0).blocks.first { normalized($0.text) == words })
        #expect(wide.lines.count == 3 && abs(wide.frame.x - left) < 0.5 && abs(wide.frame.width - block.frame.width) < 2)
        #expect(normalized(try Reference(editor.serialized()).texts[0]).contains(words))
    }
}
