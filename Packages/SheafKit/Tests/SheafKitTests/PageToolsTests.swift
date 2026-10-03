import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct PageToolsTests {
    // MARK: Ranges

    @Test func pageRangesAreReadTheWayPeopleWriteThem() throws {
        #expect(try PageRanges.parse("1-3, 5", pageCount: 10) == [0, 1, 2, 4])
        #expect(try PageRanges.parse("8-", pageCount: 10) == [7, 8, 9])
        #expect(try PageRanges.parse("-2", pageCount: 10) == [0, 1])
        #expect(try PageRanges.parse("3–1", pageCount: 10) == [2, 1, 0])
        #expect(try PageRanges.parse(" 2 ;4  6", pageCount: 10) == [1, 3, 5])
        #expect(try PageRanges.parse("2,2", pageCount: 10) == [1, 1])
        for bad in ["", "0", "11", "a", "1-2-3", "-", "4-12"] {
            #expect(throws: SheafError.self, "\(bad)") { try PageRanges.parse(bad, pageCount: 10) }
        }
        #expect(PageRanges.description(of: [0, 1, 2, 4, 7, 8]) == "1–3, 5, 8–9")
        #expect(PageRanges.description(of: []) == "")
    }

    // MARK: Extracting and splitting

    @Test func extractedPagesMakeACompleteDocument() throws {
        let data = try Fixture.outlineAnnotations.data
        let before = try Reference(data)
        let editor = PDFEditor(try PDFFile(data: data))
        let extracted = try editor.extractingPages([9, 3, 4])

        let after = try Reference(extracted)
        #expect(after.texts == [9, 3, 4].map { before.texts[$0] })
        #expect(after.pixels(ofPage: 1) == before.pixels(ofPage: 3))
        // The note on the fourth page came along.
        #expect(after.document.page(at: 1)?.annotations.contains { $0.type == "Text" } == true)
        // Bookmarks that lead to the chosen pages came along, renumbered; the rest did not.
        let outline = try PDFFile(data: extracted).outline()
        #expect(outline.map(\.title) == ["Getting Started", "Working with Pages"])
        #expect(outline.map(\.pageIndex) == [1, 0])
        #expect(outline[0].children.map(\.title) == ["Section 2.1", "Section 2.2"])
        #expect(outline[0].children.map(\.pageIndex) == [1, 2])
        #expect(outline[0].children[0].top == 700)
        // Nothing of the other nine pages is in the file.
        #expect(extracted.count < data.count)
        #expect(try Self.pageObjects(in: data) == 12)
        #expect(try Self.pageObjects(in: extracted) == 3)
    }

    @Test func extractionKeepsDocumentInformationAndCanProtect() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.setInfo(DocumentInfo(title: "Отчёт", author: "Sheaf"))
        let extracted = try editor.extractingPages([2], protection: .password(user: "secret"))
        #expect(throws: SheafError.passwordRequired) { try PDFFile(data: extracted) }
        let file = try PDFFile(data: extracted, password: "secret")
        #expect(try file.info().title == "Отчёт")
        #expect(try Reference(extracted, password: "secret").pageCount == 1)
    }

    @Test func extractionFromAnEncryptedDocumentIsReadable() throws {
        let data = try Fixture.encrypted.data
        let before = try Reference(data, password: "sheaf")
        let extracted = try PDFEditor(PDFFile(data: data, password: "sheaf")).extractingPages([0])
        let after = try Reference(extracted)
        #expect(!after.document.isEncrypted)
        #expect(after.texts == [before.texts[0]])
    }

    @Test func splitPlansCoverEveryPageOnce() throws {
        #expect(SplitPlan.every(5, pageCount: 12).map(\.pageIndexes) == [Array(0..<5), Array(5..<10), [10, 11]])
        #expect(SplitPlan.every(0, pageCount: 12).isEmpty)
        let outline = try PDFFile(data: Fixture.outlineAnnotations.data).outline()
        let parts = SplitPlan.byBookmarks(outline, pageCount: 12)
        #expect(parts.map(\.title) == ["Introduction", "Getting Started", "Editing Text", "Working with Pages"])
        #expect(parts.map(\.pageIndexes) == [Array(0..<3), Array(3..<6), Array(6..<9), Array(9..<12)])
        // Pages ahead of the first bookmark are not lost.
        let late = SplitPlan.byBookmarks(Array(outline.dropFirst()), pageCount: 12)
        #expect(late.first == SplitPart(pageIndexes: [0, 1, 2]))
        #expect(late.flatMap(\.pageIndexes) == Array(0..<12))
    }

    // MARK: Merging

    @Test func mergedDocumentsFollowOneAnotherWithBookmarks() throws {
        let first = try Fixture.text3Pages.data, second = try Fixture.outlineAnnotations.data, third = try Fixture.encrypted.data
        let sources = [
            MergeSource(document: PDFEditor(try PDFFile(data: first)), title: "Text"),
            MergeSource(document: PDFEditor(try PDFFile(data: second)), title: "Manual", pageIndexes: [3, 4, 5, 0]),
            MergeSource(document: PDFEditor(try PDFFile(data: third, password: "sheaf")), title: "Secret"),
        ]
        let merged = try PDFGenerator.merged(sources)
        let reference = try Reference(merged)
        let texts = try [Reference(first).texts, [3, 4, 5, 0].map { try Reference(second).texts[$0] }, Reference(third, password: "sheaf").texts]
        #expect(reference.texts == texts.flatMap { $0 })
        #expect(!reference.document.isEncrypted)

        let outline = try PDFFile(data: merged).outline()
        #expect(outline.map(\.title) == ["Text", "Manual", "Secret"])
        #expect(outline.map(\.pageIndex) == [0, 3, 7])
        #expect(outline[1].children.map(\.title) == ["Introduction", "Getting Started"])
        #expect(outline[1].children.map(\.pageIndex) == [6, 3])
        #expect(outline[1].children[1].children.map(\.pageIndex) == [3, 4, 5])
        // PDFKit agrees about where the entries lead.
        let root = try #require(reference.document.outlineRoot)
        let manual = try #require(root.child(at: 1))
        #expect(manual.destination?.page.flatMap { reference.document.index(for: $0) } == 3)

        let flat = try PDFFile(data: PDFGenerator.merged(sources, bookmarksPerDocument: false)).outline()
        #expect(flat.map(\.title) == ["Introduction", "Getting Started"])
    }

    @Test func mergingTheSameDocumentTwiceStoresItsFontsOnce() throws {
        let data = try Fixture.text3Pages.data
        let source = MergeSource(document: PDFEditor(try PDFFile(data: data)), title: "A")
        let once = try PDFGenerator.merged([source]), twice = try PDFGenerator.merged([source, source])
        #expect(try Reference(twice).pageCount == 6)
        #expect(twice.count < once.count * 2 - 1000)
    }

    // MARK: Removing pages

    @Test func removingAPageRemovesLinksAndBookmarksThatLedToIt() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.outlineAnnotations.data))
        var link = Annotation(kind: .link, rect: PDFRectangle(x: 72, y: 72, width: 100, height: 20))
        link.link = .page(4)
        try editor.addAnnotation(link, toPageAt: 0)
        link.link = .page(7)
        try editor.addAnnotation(link, toPageAt: 0)
        #expect(try editor.annotations(onPageAt: 0).filter { $0.kind == .link }.count == 3)

        // Page 4 is "Section 2.1" and the start of "Getting Started"; page 5 is "Section 2.2".
        try editor.removePages(at: [3, 4])
        let saved = try editor.serialized()
        let file = try PDFFile(data: saved)
        let links = try file.annotations(forPage: try file.pageIDs()[0]).filter { $0.kind == .link }
        #expect(links.map(\.link) == [.url("https://example.com"), .page(5)])

        let outline = try file.outline()
        #expect(outline.map(\.title) == ["Introduction", "Getting Started", "Editing Text", "Working with Pages"])
        // The chapter keeps its last section but has no page of its own to go to.
        #expect(outline.map(\.pageIndex) == [0, nil, 4, 7])
        #expect(outline[1].children.map(\.title) == ["Section 2.3"])
        #expect(outline[1].children.map(\.pageIndex) == [3])
        #expect(try Reference(saved).pageCount == 10)

        // With nothing pointing at them, a rewrite leaves the removed pages out for good.
        let rewritten = try editor.rewritten()
        let before = try Reference(Fixture.outlineAnnotations.data)
        #expect(try Reference(rewritten).texts == before.texts.enumerated().filter { ![3, 4].contains($0.offset) }.map(\.element))
        #expect(try Self.pageObjects(in: saved) == 12)
        #expect(try Self.pageObjects(in: rewritten) == 10)
    }

    @Test func reorderingLeavesLinksAndBookmarksAlone() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.outlineAnnotations.data))
        try editor.movePage(from: 0, to: 11)
        #expect(try editor.changedNumbers.count <= 13)
        let outline = try PDFFile(data: editor.serialized()).outline()
        #expect(outline.map(\.pageIndex) == [11, 2, 5, 8])
    }

    /// How many page objects a file holds, whether or not the page tree still lists them.
    private static func pageObjects(in data: Data) throws -> Int {
        let file = try PDFFile(data: data)
        return file.objectNumbers.filter { (try? file.object(ObjectID($0)).dictionaryValue?["Type"]?.nameValue) == "Page" }.count
    }

    // MARK: Halves

    /// A page that is black on one half, turned each way, must split into a black page
    /// and a white page in reading order.
    @Test(arguments: [0, 90, 180, 270], [SplitDirection.vertical, .horizontal])
    func splittingInHalfFollowsThePageAsDisplayed(rotation: Int, direction: SplitDirection) throws {
        // Paint the half that ends up first when displayed: the left or the top.
        let (width, height) = (400.0, 200.0)
        let size = rotation % 180 == 0 ? (width, height) : (height, width)
        let half: PDFRectangle = direction == .vertical
            ? PDFRectangle(x: 0, y: 0, width: size.0 / 2, height: size.1)
            : PDFRectangle(x: 0, y: size.1 / 2, width: size.0, height: size.1 / 2)
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 10, y: 20, width: width, height: height)])))
        try editor.rotatePage(at: 0, by: rotation)
        let geometry = try editor.geometry(ofPageAt: 0)
        #expect(geometry.displaySize == PageSize(width: size.0, height: size.1))
        let corners = [PDFPoint(x: half.x, y: half.y), PDFPoint(x: half.x + half.width, y: half.y + half.height)].map(geometry.fromDisplay.apply)
        let painted = try #require(PDFRectangle(enclosing: corners))
        let content = editor.add(.stream(PDFStream(data: Data("0 g \(painted.x) \(painted.y) \(painted.width) \(painted.height) re f".utf8))))
        try editor.update(try editor.pageIDs()[0]) { $0["Contents"] = .reference(content) }

        try editor.splitPagesInHalf(at: [0], direction: direction)
        let reference = try Reference(editor.serialized())
        #expect(reference.pageCount == 2)
        let expected = direction == .vertical ? "\(Int(size.0 / 2))x\(Int(size.1))" : "\(Int(size.0))x\(Int(size.1 / 2))"
        for index in 0..<2 {
            let page = try #require(reference.document.page(at: index))
            let box = page.bounds(for: .cropBox)
            let shown = rotation % 180 == 0 ? "\(Int(box.width))x\(Int(box.height))" : "\(Int(box.height))x\(Int(box.width))"
            #expect(shown == expected)
            let pixels = try #require(reference.pixels(ofPage: index))
            let dark = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 128 }.count
            let share = Double(dark) / Double(pixels.count / 4)
            #expect(index == 0 ? share > 0.9 : share < 0.1, "page \(index + 1) is \(Int(share * 100))% dark")
        }
    }

    @Test func splittingSeveralPagesKeepsTheirOrder() throws {
        let before = try Reference(Fixture.text3Pages.data)
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.splitPagesInHalf(at: [0, 2], direction: .vertical, rightToLeft: true)
        let reference = try Reference(editor.serialized())
        #expect(reference.pageCount == 5)
        #expect(reference.shapes == ["306x792@0", "306x792@0", "612x792@0", "306x792@0", "306x792@0"])
        #expect(reference.texts[2] == before.texts[1])
        // Right to left: the first of each pair is the right half.
        #expect(reference.document.page(at: 0)?.bounds(for: .cropBox).minX == 306)
        #expect(reference.document.page(at: 1)?.bounds(for: .cropBox).minX == 0)
    }
}
