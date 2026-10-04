import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct PageTextTests {
    /// Text with everything but letters, digits and punctuation taken out, for comparing
    /// what two readers make of a page without caring where they put spaces and breaks.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !$0.properties.isWhitespace && $0.value > 0x20 }.map(Character.init))
    }

    @Test(arguments: [Fixture.text3Pages, .outlineAnnotations, .handwritten, .form, .paperForm])
    func textReadsAsPDFKitReadsIt(fixture: Fixture) throws {
        let data = try fixture.data
        let editor = PDFEditor(try PDFFile(data: data))
        let reference = try Reference(data)
        for index in 0..<reference.pageCount {
            let content = try editor.pageContent(at: index)
            let expected = reference.document.page(at: index)?.string ?? ""
            #expect(Self.squeezed(content.text) == Self.squeezed(expected), "page \(index + 1) of \(fixture.rawValue)")
        }
    }

    @Test func glyphsAreWhereTheReaderDrawsThem() throws {
        let data = try Fixture.text3Pages.data
        let content = try PDFEditor(PDFFile(data: data)).pageContent(at: 0)
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        var compared = 0
        // Each character's box, against the box PDFKit gives the character at the same place.
        for glyph in content.blocks.flatMap(\.lines).flatMap(\.glyphs) where !glyph.isImplied && glyph.text != " " {
            let middle = CGPoint(x: glyph.origin.x + glyph.advance / 2, y: glyph.origin.y + glyph.fontSize * 0.25)
            let found = page.characterIndex(at: middle)
            guard found >= 0, found != NSNotFound else { continue }
            let bounds = page.characterBounds(at: found)
            // PDFKit's box hugs the ink; the glyph's own box runs from pen position to pen position.
            let slack = glyph.fontSize * 0.15
            #expect(bounds.minX >= glyph.origin.x - slack && bounds.maxX <= glyph.origin.x + glyph.advance + slack, "\(glyph.text) is at \(glyph.origin.x)+\(glyph.advance), PDFKit says \(bounds)")
            #expect(abs(bounds.midX - (glyph.origin.x + glyph.advance / 2)) < glyph.fontSize * 0.12)
            compared += 1
        }
        #expect(compared > 100)
    }

    @Test func linesAndBlocksFollowTheLayout() throws {
        let content = try PDFEditor(PDFFile(data: Fixture.text3Pages.data)).pageContent(at: 0)
        // A heading, then a paragraph of three lines.
        #expect(content.blocks.count == 2)
        #expect(content.blocks[0].text == "Page 1")
        #expect(content.blocks[1].lines.count == 3)
        #expect(content.blocks[1].lines[0].text.hasPrefix("Lorem ipsum dolor sit amet"))
        #expect(content.blocks[1].flowingText.hasPrefix("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore"))
        let allEditable = content.blocks.allSatisfy { $0.isEditable }
        #expect(allEditable)
        #expect(content.blocks[0].lines[0].fontSize > content.blocks[1].lines[0].fontSize)
        let heading = try #require(content.blocks[0].lines[0].glyphs.first)
        #expect(heading.isBold && heading.fontName.contains("Helvetica"))
        let hit = content.block(at: PDFPoint(x: 100, y: content.blocks[1].frame.y + 5))
        #expect(hit?.id == 1)
    }

    @Test func picturesAreFoundWithTheirFrames() throws {
        let content = try PDFEditor(PDFFile(data: Fixture.image1Page.data)).pageContent(at: 0)
        #expect(content.images.count == 1)
        let image = try #require(content.images.first)
        #expect(image.isEditable && image.pixelWidth > 0)
        #expect(image.frame.width > 50 && image.frame.height > 50)
    }
}

extension CorpusTests {
    /// Reads the text of every file and compares it with what PDFKit reads.
    @Test(.enabled(if: listPath != nil))
    func everyFileReadsTheSameTextAsPDFKit() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8).split(separator: "\n").map(String.init)
        var pages = 0, same = 0, close = 0, withText = 0
        var worst: [(Double, String)] = []
        var problems: [String] = []
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let original = PDFDocument(data: data), !original.isLocked, original.pageCount > 0
            else { continue }
            do {
                let editor = PDFEditor(try PDFFile(data: data))
                for index in 0..<min(original.pageCount, 3) {
                    pages += 1
                    let mine = Array(PageTextTests.squeezed(try editor.pageContent(at: index).text)).sorted()
                    let theirs = Array(PageTextTests.squeezed(original.page(at: index)?.string ?? "")).sorted()
                    guard !theirs.isEmpty || !mine.isEmpty else { continue }
                    withText += 1
                    // The share of characters both readers found.
                    var common = 0, i = 0, j = 0
                    while i < mine.count, j < theirs.count {
                        if mine[i] == theirs[j] { common += 1; i += 1; j += 1 } else if mine[i] < theirs[j] { i += 1 } else { j += 1 }
                    }
                    let share = Double(common) / Double(max(mine.count, theirs.count))
                    if share == 1 { same += 1 } else if share > 0.95 { close += 1 } else { worst.append((share, "\(path) page \(index + 1): \(mine.count) vs \(theirs.count)")) }
                }
            } catch {
                problems.append("\(path): \(error)")
            }
        }
        print("corpus: \(pages) pages read, \(withText) with text, \(same) identical to PDFKit, \(close) within 5%, \(worst.count) further off, \(problems.count) problems")
        var seenFiles: Set<String> = []
        for entry in worst.sorted(by: { $0.0 < $1.0 }) {
            // One line per file is enough to see what kind of file it is.
            let file = entry.1.components(separatedBy: " page ").first.map { ($0 as NSString).lastPathComponent + "/" + (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent } ?? ""
            guard seenFiles.insert(file).inserted, seenFiles.count <= 40 else { continue }
            print("  \(String(format: "%.2f", entry.0)) \(entry.1.suffix(110))")
        }
        #expect(problems.isEmpty)
    }

    /// Changes, moves and redacts text on the first page of every file, and checks the
    /// results with PDFKit.
    @Test(.enabled(if: listPath != nil))
    func everyFileSurvivesContentEditing() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8).split(separator: "\n").map(String.init)
        var edited = 0, redacted = 0, skipped = 0
        var problems: [String] = []
        func squeeze(_ text: String) -> String { PageTextTests.squeezed(text) }
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let original = PDFDocument(data: data), !original.isLocked, original.pageCount > 0
            else { continue }
            do {
                let editor = PDFEditor(try PDFFile(data: data))
                let content = try editor.pageContent(at: 0)
                // A block the engine and PDFKit read the same way, so PDFKit can judge the result.
                let pageText = squeeze(original.page(at: 0)?.string ?? "")
                guard let block = content.blocks.first(where: { block in
                    // A real line of words, wholly on the page: scraps at a page's edge prove nothing.
                    block.isEditable && block.text.count >= 8 && !block.text.contains("\u{FFFD}") && squeeze(block.lines[0].text).count >= 6
                        && pageText.contains(squeeze(block.lines[0].text))
                        && block.frame.y >= 0 && block.frame.y + block.frame.height <= content.geometry.displaySize.height
                        && block.frame.x >= 0 && block.frame.x + block.frame.width <= content.geometry.displaySize.width
                }) else {
                    skipped += 1
                    continue
                }

                // A word typed at the front, in letters the font is sure to have.
                var typing = editor
                let word = String(block.lines[0].text.filter(\.isLetter).prefix(4))
                try typing.replaceText(ofBlock: block.id, onPageAt: 0, with: word + " " + block.flowingText)
                guard let reopened = PDFDocument(data: try typing.serialized()), let page = reopened.page(at: 0) else {
                    problems.append("\(path): PDFKit cannot open the file after editing text")
                    continue
                }
                let after = squeeze(page.string ?? "")
                if !after.contains(squeeze(word + block.lines[0].text.prefix(6))) {
                    problems.append("\(path): the typed word is not where it should be")
                }
                // Nothing else on the page lost its text.
                if after.count < pageText.count { problems.append("\(path): text went missing after an edit (\(pageText.count) to \(after.count))") }
                edited += 1

                // Moved, the block reads the same.
                var moving = editor
                try moving.moveText(ofBlock: block.id, onPageAt: 0, dx: 7, dy: -5)
                let staysOnPage = block.frame.x + block.frame.width + 7 <= content.geometry.displaySize.width && block.frame.y - 5 >= 0
                if staysOnPage, squeeze(try moving.pageContent(at: 0).text).count != squeeze(content.text).count {
                    problems.append("\(path): moving a block changed the page's text")
                }

                // Redacted, the block's first line is gone for both readers, when nothing else says the same.
                let line = squeeze(block.lines[0].text)
                let occurrences = pageText.components(separatedBy: line).count - 1
                if line.count >= 6, occurrences == 1 {
                    var redacting = editor
                    try redacting.redact([block.lines[0].frame], onPageAt: 0)
                    let saved = try redacting.rewritten()
                    guard let cleaned = PDFDocument(data: saved) else {
                        problems.append("\(path): PDFKit cannot open the redacted file")
                        continue
                    }
                    if squeeze(cleaned.page(at: 0)?.string ?? "").contains(line) { problems.append("\(path): PDFKit still reads redacted text") }
                    if squeeze(try PDFEditor(PDFFile(data: saved)).pageContent(at: 0).text).contains(line) { problems.append("\(path): the engine still reads redacted text") }
                    redacted += 1
                }
            } catch {
                problems.append("\(path): \(error)")
            }
        }
        print("corpus: text edited in \(edited) files, redacted in \(redacted), \(skipped) with no text to edit, \(problems.count) problems")
        for problem in problems.prefix(40) { print("  " + problem.suffix(170)) }
        #expect(problems.isEmpty)
    }
}
