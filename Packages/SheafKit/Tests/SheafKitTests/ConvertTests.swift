import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct ConvertTests {
    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Runs a command-line tool that comes with macOS and gives back what it prints.
    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func temporaryFile(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url)
        return url
    }

    /// One file out of a zip archive, as the system's own unzip reads it.
    private func entry(_ name: String, in archive: URL) throws -> Data {
        // Brackets mean a set of characters to unzip unless escaped.
        let pattern = name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let result = try run("/usr/bin/unzip", ["-p", archive.path, pattern])
        #expect(result.status == 0)
        return result.output
    }

    @Test func archivesAreReadByTheSystem() throws {
        var archive = ZipArchive()
        let long = String(repeating: "A line of text that packs well. ", count: 400)
        archive.add("folder/long.txt", long)
        archive.add("short.txt", "hi")
        archive.add("raw bytes.bin", Data((0..<255).map { UInt8($0) }), compresses: false)
        let data = archive.data()
        #expect(data.count < long.utf8.count / 4)
        let url = try temporaryFile(data, extension: "zip")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try run("/usr/bin/unzip", ["-tq", url.path]).status == 0)
        #expect(try entry("folder/long.txt", in: url) == Data(long.utf8))
        #expect(try entry("short.txt", in: url) == Data("hi".utf8))
        #expect(try entry("raw bytes.bin", in: url).count == 255)
    }

    @Test func textIsEscapedForXML() {
        #expect(xmlEscaped("a < b & \"c\" > d\u{1}") == "a &lt; b &amp; &quot;c&quot; &gt; d")
    }

    // MARK: Word

    @Test func aDocumentBecomesAWordFile() throws {
        var editor = PDFEditor(try PDFFile(data: try Fixture.text3Pages.data))
        // A second paragraph in color, and a picture, to carry over.
        try editor.addText("Signed & sealed <today>", toPageAt: 0, at: PDFPoint(x: 72, y: 400), fontName: "Georgia-Bold", fontSize: 16, color: .red)
        let picture = try Fixture.image1Page.data
        let source = PDFEditor(try PDFFile(data: picture))
        if let image = try source.pageContent(at: 0).images.first?.objectID, let file = try source.pictureFile(image) {
            try editor.addImage(file.data, toPageAt: 1, in: PDFRectangle(x: 100, y: 300, width: 200, height: 150))
        }
        let word = try editor.wordDocument(title: "Three Pages")
        let url = try temporaryFile(word, extension: "docx")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try run("/usr/bin/unzip", ["-tq", url.path]).status == 0)

        // Well-formed parts, with a section for each page.
        let document = try XMLDocument(data: try entry("word/document.xml", in: url))
        _ = try XMLDocument(data: try entry("[Content_Types].xml", in: url))
        _ = try XMLDocument(data: try entry("word/styles.xml", in: url))
        let relationships = try XMLDocument(data: try entry("word/_rels/document.xml.rels", in: url))
        #expect(try document.nodes(forXPath: "//*[local-name()='sectPr']").count == 3)
        let sizes = try document.nodes(forXPath: "//*[local-name()='pgSz']").compactMap { ($0 as? XMLElement)?.attribute(forName: "w:w")?.stringValue }
        #expect(sizes == ["12240", "12240", "12240"])

        // The paragraph is one paragraph, not three lines, and keeps its font.
        let paragraphs = try document.nodes(forXPath: "//*[local-name()='p']").map { $0.stringValue ?? "" }
        #expect(paragraphs.contains { normalized($0).hasPrefix("Lorem ipsum dolor sit amet") && normalized($0).hasSuffix("commodo consequat.") })
        let xml = document.xmlString
        #expect(xml.contains("w:ascii=\"Times New Roman\""))
        #expect(xml.contains("w:ascii=\"Georgia\"") && xml.contains("<w:color w:val=\"FF3B30\"") && xml.contains("<w:b"))
        #expect(xml.contains("Signed &amp; sealed &lt;today&gt;"))

        // The picture is in the archive and the document points at it.
        if xml.contains("rIdImage1") {
            let relationship = try relationships.nodes(forXPath: "//*[@Id='rIdImage1']").first as? XMLElement
            let target = try #require(relationship?.attribute(forName: "Target")?.stringValue)
            #expect(try entry("word/\(target)", in: url).count > 100)
        }

        // The system's own converter reads it back as text.
        let text = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
        #expect(text.status == 0)
        let read = normalized(String(decoding: text.output, as: UTF8.self))
        #expect(read.contains("Page 1") && read.contains("Lorem ipsum dolor sit amet, consectetur") && read.contains("Signed & sealed <today>") && read.contains("Page 3"))
    }

    @Test func runsOfOneLookAreJoined() throws {
        let editor = PDFEditor(try PDFFile(data: try Fixture.text3Pages.data))
        let block = try #require(try editor.pageContent(at: 0).blocks.first { $0.lines.count == 3 })
        let paragraphs = block.styledParagraphs
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].runs.count == 1)
        #expect(paragraphs[0].runs[0].text.hasPrefix("Lorem ipsum") && !paragraphs[0].runs[0].text.contains("\n"))
        #expect(paragraphs[0].runs[0].fontSize == 12)
    }

    // MARK: Excel

    /// A page with a small table set in columns.
    private func table() throws -> PDFEditor {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 612, height: 792)])))
        let rows = [["Item", "Qty", "Price"], ["Paper, A4", "12", "4.50"], ["Ink", "3", "1,250.00"], ["Discount", "", "10%"], ["Ref", "0042", "(15.5)"]]
        for (row, cells) in rows.enumerated() {
            for (column, text) in cells.enumerated() where !text.isEmpty {
                try editor.addText(text, toPageAt: 0, at: PDFPoint(x: 72 + Double(column) * 160, y: 700 - Double(row) * 24), fontName: "Helvetica", fontSize: 12)
            }
        }
        try editor.addText("Order 7 for the spring term, to be delivered to the front office", toPageAt: 0, at: PDFPoint(x: 72, y: 740), fontName: "Helvetica", fontSize: 12)
        return editor
    }

    @Test func aTableIsReadAsAGrid() throws {
        let grid = try table().pageContent(at: 0).grid
        #expect(grid.columnCount == 3)
        #expect(grid.rows.count == 6)
        // The heading above the table sits in the first column and does not join the columns.
        #expect(grid.rows[0][0].hasPrefix("Order 7"))
        #expect(grid.rows[1] == ["Item", "Qty", "Price"])
        #expect(grid.rows[2] == ["Paper, A4", "12", "4.50"])
        #expect(grid.rows[4] == ["Discount", "", "10%"])
    }

    @Test func numbersAreToldFromText() {
        #expect(PDFEditor.number(from: "12") == 12)
        #expect(PDFEditor.number(from: "1,250.00") == 1250)
        #expect(PDFEditor.number(from: "(15.5)") == -15.5)
        #expect(PDFEditor.number(from: "10%") == 0.1)
        #expect(PDFEditor.number(from: "−3") == -3)
        // Codes, dates, phone numbers and words stay as they are.
        for text in ["0042", "2026-10-03", "12/31", "555-1234", "1,25", "A4", "Paper, A4", "", "4111111111111111111"] {
            #expect(PDFEditor.number(from: text) == nil, "\(text)")
        }
    }

    @Test func aDocumentBecomesAnExcelFile() throws {
        let workbook = try table().spreadsheet()
        let url = try temporaryFile(workbook, extension: "xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try run("/usr/bin/unzip", ["-tq", url.path]).status == 0)
        _ = try XMLDocument(data: try entry("xl/workbook.xml", in: url))
        _ = try XMLDocument(data: try entry("xl/styles.xml", in: url))
        let sheet = try XMLDocument(data: try entry("xl/worksheets/sheet1.xml", in: url))
        func cell(_ reference: String) throws -> XMLElement? {
            try sheet.nodes(forXPath: "//*[local-name()='c'][@r='\(reference)']").first as? XMLElement
        }
        // Text as text, numbers as numbers, each in its column.
        #expect(try cell("A2")?.stringValue == "Item")
        #expect(try cell("A3")?.attribute(forName: "t")?.stringValue == "inlineStr")
        #expect(try cell("B3")?.attribute(forName: "t") == nil)
        #expect(try cell("B3")?.stringValue == "12")
        #expect(try cell("C4")?.stringValue == "1250")
        #expect(try cell("C5")?.stringValue == "0.1")
        #expect(try cell("C5")?.attribute(forName: "s")?.stringValue == "1")
        #expect(try cell("B5") == nil)
        #expect(try cell("B6")?.stringValue == "0042")
        #expect(try cell("C6")?.stringValue == "-15.5")
    }

    @Test func everyPageGetsASheet() throws {
        let workbook = try PDFEditor(try PDFFile(data: try Fixture.text3Pages.data)).spreadsheet()
        let url = try temporaryFile(workbook, extension: "xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try XMLDocument(data: try entry("xl/workbook.xml", in: url))
        #expect(try book.nodes(forXPath: "//*[local-name()='sheet']").count == 3)
        #expect(try entry("xl/worksheets/sheet3.xml", in: url).count > 100)
    }

    // MARK: Comparing

    @Test func theShortestListOfEditsIsFound() throws {
        func describe(_ a: [String], _ b: [String]) -> String {
            (DocumentComparer.difference(a, b) ?? []).map { step in
                switch step {
                case .same(let i, _): a[i]
                case .removed(let i): "-\(a[i])"
                case .added(let j): "+\(b[j])"
                }
            }.joined(separator: " ")
        }
        #expect(describe(["a", "b", "c"], ["a", "b", "c"]) == "a b c")
        #expect(describe(["a", "b", "c"], ["a", "x", "c"]) == "a -b +x c")
        #expect(describe([], ["a"]) == "+a")
        #expect(describe(["a", "b", "c", "d"], ["b", "d", "e"]) == "-a b -c d +e")
        #expect(describe(["a", "b"], []) == "-a -b")
        // Every step accounts for every element, in order.
        let a = (0..<400).map { "w\($0 % 37)" }, b = (0..<420).map { "w\(($0 * 3) % 41)" }
        let steps = try #require(DocumentComparer.difference(a, b))
        var nextA = 0, nextB = 0
        for step in steps {
            switch step {
            case .same(let i, let j):
                #expect(i == nextA && j == nextB && a[i] == b[j])
                nextA += 1
                nextB += 1
            case .removed(let i):
                #expect(i == nextA)
                nextA += 1
            case .added(let j):
                #expect(j == nextB)
                nextB += 1
            }
        }
        #expect(nextA == a.count && nextB == b.count)
        // Too different to be worth listing.
        #expect(DocumentComparer.difference((0..<500).map { "a\($0)" }, (0..<500).map { "b\($0)" }, limit: 100) == nil)
    }

    @Test func changedWordsAreFoundWhereTheyAre() throws {
        let original = PDFEditor(try PDFFile(data: try Fixture.text3Pages.data))
        var revised = original
        let block = try #require(try revised.pageContent(at: 0).blocks.first { $0.lines.count == 3 })
        try revised.replaceText(ofBlock: block.id, onPageAt: 0, with: block.flowingText
            .replacingOccurrences(of: "dolor sit", with: "color sits")
            .replacingOccurrences(of: "magna ", with: "")
            .replacingOccurrences(of: "consequat.", with: "consequat. Added words."))

        let comparison = try DocumentComparer.compare(original, revised)
        #expect(comparison.pagePairs.count == 3)
        #expect(comparison.pagePairs.allSatisfy { $0.a == $0.b })
        #expect(comparison.changes.map(\.kind) == [.replaced, .deleted, .inserted])
        let replaced = comparison.changes[0]
        #expect(replaced.textA == "dolor sit" && replaced.textB == "color sits")
        #expect(replaced.pageA == 0 && replaced.pageB == 0)
        // The boxes are on the words: on the paragraph's first line, after "Lorem ipsum".
        let line = block.lines[0]
        let frame = try #require(replaced.framesA.first)
        #expect(abs(frame.y - line.frame.y) < 1 && frame.x > line.frame.x + 40 && frame.x < line.frame.x + 120 && frame.width > 30 && frame.width < 70)
        #expect(comparison.changes[1].textA == "magna" && comparison.changes[1].framesB.isEmpty)
        #expect(comparison.changes[2].textB == "Added words." && comparison.changes[2].framesA.isEmpty)

        // The same document against itself has no differences.
        #expect(try DocumentComparer.compare(original, original).changes.isEmpty)
    }

    @Test func addedAndRemovedPagesDoNotThrowTheRestOff() throws {
        let original = PDFEditor(try PDFFile(data: try Fixture.outlineAnnotations.data))
        var revised = original
        try revised.removePages(at: [3])
        _ = try revised.insertBlankPage(size: PageSize(width: 612, height: 792), at: 7)
        try revised.addText("A page that was not there before", toPageAt: 7, at: PDFPoint(x: 72, y: 700))
        let comparison = try DocumentComparer.compare(original, revised)
        let kinds = comparison.changes.map(\.kind)
        #expect(kinds == [.pageRemoved, .pageAdded])
        #expect(comparison.changes[0].pageA == 3 && comparison.changes[0].pageB == nil)
        #expect(comparison.changes[1].pageA == nil && comparison.changes[1].pageB == 7)
        // Every other page is paired with itself.
        #expect(comparison.pagePairs.filter { $0.a != nil && $0.b != nil }.count == 11)
        #expect(comparison.pagePairs.contains { $0.a == 11 && $0.b == 11 })
    }

    @Test func aComparisonIsWrittenUpAsAReport() throws {
        let original = PDFEditor(try PDFFile(data: try Fixture.text3Pages.data))
        var revised = original
        for index in 0..<3 {
            let block = try #require(try revised.pageContent(at: index).blocks.first { $0.lines.count >= 2 })
            try revised.replaceText(ofBlock: block.id, onPageAt: index, with: block.flowingText.replacingOccurrences(of: "ipsum", with: "IPSUM"))
        }
        var comparison = try DocumentComparer.compare(original, revised)
        // Enough changes to run onto a second page.
        for number in 0..<60 {
            comparison.changes.append(DocumentChange(id: 100 + number, kind: .inserted, pageA: 1, pageB: 1, textB: "Extra change number \(number)"))
        }
        let report = try comparison.report(nameA: "Before.pdf", nameB: "After.pdf", pageSize: PageSize(width: 612, height: 792), date: "3 October 2026")
        let reference = try Reference(report)
        #expect(reference.pageCount >= 2)
        let text = normalized(reference.texts.joined(separator: " "))
        #expect(text.contains("Comparison Report") && text.contains("Original: Before.pdf") && text.contains("Revised: After.pdf"))
        #expect(text.contains("Changed: 3") && text.contains("Added: 60"))
        #expect(text.contains("− ipsum") && text.contains("+ IPSUM") && text.contains("Extra change number 59"))
    }

    // MARK: Archiving

    @Test func aDocumentIsMadeFitForArchiving() throws {
        // A font that is only named, a script that runs on opening, and no metadata.
        var editor = PDFEditor(try PDFFile(data: MinimalPage.document(content: "BT /F1 24 Tf 72 700 Td (Archive me, please) Tj ET")))
        let script = editor.add(["S": .name("JavaScript"), "JS": .string(Data("app.alert('hi')".utf8))])
        try editor.update(try #require(editor.catalogID)) { $0["OpenAction"] = .reference(script) }
        let before = try editor.serialized()

        let result = try editor.archival()
        #expect(result.fixed.contains(.embeddedFont("Helvetica")))
        #expect(result.fixed.contains(.addedColorProfile) && result.fixed.contains(.addedMetadata) && result.fixed.contains(.removedScripts(1)))
        #expect(result.remaining.isEmpty)

        let archived = PDFEditor(try PDFFile(data: result.data))
        let catalog = try archived.catalog()
        #expect(catalog["OpenAction"] == nil)
        let firstIntent = try #require(try archived.value("OutputIntents", in: catalog).arrayValue?.first)
        let intent = try #require(try archived.resolve(firstIntent).dictionaryValue)
        #expect(intent["S"]?.nameValue == "GTS_PDFA1")
        let profile = try #require(try archived.value("DestOutputProfile", in: intent).streamValue)
        #expect(profile.dictionary["N"]?.intValue == 3)
        let metadata = try #require(try archived.metadataPacket())
        let packet = String(decoding: metadata, as: UTF8.self)
        #expect(packet.contains("<pdfaid:part>2</pdfaid:part>") && packet.contains("<pdfaid:conformance>B</pdfaid:conformance>"))
        #expect(result.data.range(of: Data("app.alert".utf8)) == nil)

        // The font is inside the file now, and the page reads and looks as it did.
        let fonts = try archived.interpret(pageAt: 0).fonts
        #expect(fonts.count == 1 && fonts[0].isEmbedded && fonts[0].baseName == "Helvetica")
        let reference = try Reference(result.data)
        #expect(reference.texts[0] == "Archive me, please")
        let earlier = try Reference(before)
        let was = try #require(Reference.pixels(of: earlier.document.page(at: 0), fullSize: true))
        let now = try #require(Reference.pixels(of: reference.document.page(at: 0), fullSize: true))
        let different = zip(was, now).filter { abs(Int($0) - Int($1)) > 48 }.count
        #expect(different < was.count / 2000)

        // Done twice, nothing more is found to do but the metadata is written again.
        let again = try archived.archival()
        #expect(again.remaining.isEmpty && !again.fixed.contains(.addedColorProfile) && !again.fixed.contains { if case .embeddedFont = $0 { true } else { false } })
    }

    @Test func whatCannotBePutRightIsListed() throws {
        // A font that is not installed, and colors given as printing inks.
        var editor = PDFEditor(try PDFFile(data: MinimalPage.document(content: "0 1 1 0 k BT /F1 24 Tf 72 700 Td (Inks) Tj ET")))
        let font = try #require(try editor.pageContent(at: 0).blocks.first).lines[0].glyphs[0].font
        let fontIDs = try editor.interpret(pageAt: 0).fontIDs
        let id = try #require(fontIDs[font])
        try editor.update(id) { $0["BaseFont"] = .name("NoSuchFontAnywhere-Regular") }
        let result = try editor.archival()
        #expect(result.remaining.contains(.fontNotEmbedded("NoSuchFontAnywhere-Regular")))
        #expect(result.remaining.contains(.usesPrintingColors(pages: 1)))
        #expect(try Reference(result.data).pageCount == 1)
    }

    @Test func aProtectedDocumentLosesItsPassword() throws {
        let file = try PDFFile(data: try Fixture.encrypted.data, password: "sheaf")
        let result = try PDFEditor(file).archival()
        #expect(result.fixed.contains(.removedPassword))
        let reopened = try #require(PDFDocument(data: result.data))
        #expect(!reopened.isEncrypted)
    }
}

/// Reads a zip archive written by `ZipArchive`, to check what went into it.
enum ZipReader {
    static func entries(of archive: Data) -> [String: Data]? {
        let bytes = [UInt8](archive)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        var result: [String: Data] = [:]
        var offset = 0
        while offset + 30 <= bytes.count, bytes[offset] == 0x50, bytes[offset + 1] == 0x4B, bytes[offset + 2] == 3, bytes[offset + 3] == 4 {
            let method = u16(offset + 8), stored = u32(offset + 18), size = u32(offset + 22), nameLength = u16(offset + 26), extra = u16(offset + 28)
            let start = offset + 30 + nameLength + extra
            guard start + stored <= bytes.count else { return nil }
            let name = String(decoding: bytes[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
            let body = Data(bytes[start..<(start + stored)])
            let data = method == 0 ? body : (try? Flate.inflate(body))
            guard let data, data.count == size, Flate.checksum(data) == UInt32(u32(offset + 14)) else { return nil }
            result[name] = data
            offset = start + stored
        }
        return result
    }
}

extension CorpusTests {
    /// Every file is turned into a Word file, an Excel file and an archival PDF, and
    /// compared with itself.
    @Test(.enabled(if: listPath != nil))
    func everyFileConverts() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8).split(separator: "\n").map(String.init)
        var converted = 0, fontsEmbedded = 0, conformant = 0
        var problems: [String] = []
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let original = PDFDocument(data: data), !original.isLocked, original.pageCount > 0, original.pageCount <= 40
            else { continue }
            do {
                let editor = PDFEditor(try PDFFile(data: data))
                // Word: a sound archive of well-formed parts.
                guard let word = ZipReader.entries(of: try editor.wordDocument()), let body = word["word/document.xml"] else {
                    problems.append("\(path): the Word file is not a sound archive")
                    continue
                }
                if (try? XMLDocument(data: body)) == nil { problems.append("\(path): the Word document is not well-formed") }
                if let relationships = word["word/_rels/document.xml.rels"], (try? XMLDocument(data: relationships)) == nil {
                    problems.append("\(path): the Word relationships are not well-formed")
                }
                // Excel: a sheet for each page.
                guard let excel = ZipReader.entries(of: try editor.spreadsheet()) else {
                    problems.append("\(path): the Excel file is not a sound archive")
                    continue
                }
                for index in 1...original.pageCount {
                    guard let sheet = excel["xl/worksheets/sheet\(index).xml"], (try? XMLDocument(data: sheet)) != nil else {
                        problems.append("\(path): sheet \(index) is missing or not well-formed")
                        break
                    }
                }
                // Archival: still opens, same pages, same amount of text.
                let archival = try editor.archival()
                guard let archived = PDFDocument(data: archival.data), archived.pageCount == original.pageCount else {
                    problems.append("\(path): PDFKit cannot open the archival copy")
                    continue
                }
                let before = PageTextTests.squeezed(original.page(at: 0)?.string ?? "").count
                let after = PageTextTests.squeezed(archived.page(at: 0)?.string ?? "").count
                if abs(before - after) > max(before / 20, 2) { problems.append("\(path): the archival copy reads differently (\(before) to \(after))") }
                fontsEmbedded += archival.fixed.filter { if case .embeddedFont = $0 { true } else { false } }.count
                if archival.remaining.isEmpty { conformant += 1 }
                // Comparing a document with itself finds nothing.
                if try !DocumentComparer.compare(editor, editor).changes.isEmpty { problems.append("\(path): differs from itself") }
                converted += 1
            } catch {
                problems.append("\(path): \(error)")
            }
        }
        print("corpus: \(converted) files converted to Word, Excel and PDF/A, \(fontsEmbedded) fonts embedded, \(conformant) with nothing left to fix, \(problems.count) problems")
        for problem in problems.prefix(40) { print("  " + problem.suffix(170)) }
        #expect(problems.isEmpty)
    }
}
