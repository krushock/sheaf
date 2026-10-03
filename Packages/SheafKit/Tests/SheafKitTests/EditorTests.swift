import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct EditorTests {
    static let plainFixtures: [Fixture] = [.text3Pages, .image1Page, .handwritten, .outlineAnnotations]

    private func edited(_ data: Data, password: String? = nil, _ change: (inout PDFEditor) throws -> Void) throws -> Data {
        var editor = PDFEditor(try PDFFile(data: data, password: password))
        try change(&editor)
        return try editor.serialized()
    }

    // MARK: Saving

    @Test(arguments: plainFixtures)
    func savingWithoutChangesGivesTheSameBytes(fixture: Fixture) throws {
        let data = try fixture.data
        #expect(try PDFEditor(PDFFile(data: data)).serialized() == data)
    }

    @Test(arguments: plainFixtures)
    func changesAreAppendedToUntouchedOriginalBytes(fixture: Fixture) throws {
        let data = try fixture.data
        let saved = try edited(data) { try $0.rotatePage(at: 0, by: 90) }
        #expect(saved.count > data.count)
        #expect(saved.prefix(data.count) == data)
        // Everything except the rotated page reads as before.
        let before = try Reference(data), after = try Reference(saved)
        #expect(after.pageCount == before.pageCount)
        #expect(after.texts == before.texts)
        #expect(after.document.page(at: 0)?.rotation == ((before.document.page(at: 0)?.rotation ?? 0) + 90) % 360)
        // And the engine can read its own output, including a second round of edits.
        let again = try edited(saved) { try $0.rotatePage(at: 0, by: -90) }
        #expect(again.prefix(saved.count) == saved)
        #expect(try Reference(again).shapes == before.shapes)
    }

    @Test(arguments: [true, false])
    func filesIndexedByAStreamAreExtendedWithAStream(predictor: Bool) throws {
        let data = TestPDF.compressed(predictor: predictor)
        let saved = try edited(data) { editor in
            try editor.rotatePage(at: 0, by: 90)
            var info = try editor.info()
            info.title = "Changed"
            try editor.setInfo(info)
        }
        #expect(saved.prefix(data.count) == data)
        let file = try PDFFile(data: saved)
        #expect(file.crossReference.newestSectionIsStream)
        #expect(!file.crossReference.wasRebuilt)
        #expect(try file.info().title == "Changed")
        #expect(try file.info().author == "Sheaf Tests")
        let reference = try Reference(saved)
        #expect(reference.shapes == ["300x200@90", "300x200@180"])
        #expect(reference.texts == ["First page", "Second page"])
        #expect(reference.document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Changed")
    }

    @Test func repairedFilesAreWrittenAfresh() throws {
        var broken = try Fixture.text3Pages.data
        let marker = try #require(broken.range(of: Data("startxref\n".utf8), options: .backwards))
        broken.replaceSubrange(marker.upperBound..<broken.endIndex, with: Data("5\n%%EOF\n".utf8))
        let saved = try edited(broken) { try $0.removePages(at: [0]) }
        #expect(saved.prefix(20) != broken.prefix(20) || saved.count < broken.count)
        let file = try PDFFile(data: saved)
        #expect(!file.crossReference.wasRebuilt)
        #expect(try Reference(saved).texts.map { $0.prefix(6) } == ["Page 2", "Page 3"])
    }

    // MARK: Pages

    @Test func pagesCanBeReordered() throws {
        let data = try Fixture.text3Pages.data
        func order(_ change: (inout PDFEditor) throws -> Void) throws -> [Substring] {
            try Reference(edited(data, change)).texts.map { $0.prefix(6) }
        }
        #expect(try order { try $0.movePage(from: 0, to: 2) } == ["Page 2", "Page 3", "Page 1"])
        #expect(try order { try $0.movePage(from: 2, to: 0) } == ["Page 3", "Page 1", "Page 2"])
        #expect(try order { try $0.arrangePages([2, 1, 0]) } == ["Page 3", "Page 2", "Page 1"])
        #expect(try order { try $0.removePages(at: [1]) } == ["Page 1", "Page 3"])
        #expect(try order { try $0.arrangePages([1]) } == ["Page 2"])
    }

    @Test func impossiblePageChangesAreRefused() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        #expect(throws: SheafError.pageOutOfRange(3)) { try editor.rotatePage(at: 3, by: 90) }
        #expect(throws: SheafError.pageOutOfRange(-1)) { try editor.movePage(from: -1, to: 0) }
        #expect(throws: SheafError.pageOutOfRange(7)) { try editor.removePages(at: [7]) }
        #expect(throws: SheafError.self) { try editor.removePages(at: [0, 1, 2]) }
        #expect(throws: SheafError.self) { try editor.arrangePages([0, 0]) }
        #expect(throws: SheafError.self) { try editor.rotatePage(at: 0, by: 45) }
        #expect(!editor.hasChanges)
    }

    @Test func rotationAddsToWhatIsThere() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.handwritten.data))
        #expect(try editor.pageRotation(at: 0) == 90)
        try editor.rotatePage(at: 0, by: 90)
        #expect(try editor.pageRotation(at: 0) == 180)
        try editor.rotatePage(at: 0, by: -270)
        #expect(try editor.pageRotation(at: 0) == 270)
        try editor.rotatePage(at: 0, by: 450)
        #expect(try editor.pageRotation(at: 0) == 0)
    }

    @Test func nestedPageTreesKeepTheirInheritedAttributes() throws {
        let data = TestPDF.nestedTree()
        let before = try Reference(data)
        #expect(before.shapes == ["200x100@90", "200x100@0", "300x300@0", "400x500@0"])
        #expect(before.texts == ["Page 1", "Page 2", "Page 3", "Page 4"])

        let saved = try edited(data) { try $0.arrangePages([3, 1, 2, 0]) }
        let after = try Reference(saved)
        #expect(after.texts == ["Page 4", "Page 2", "Page 3", "Page 1"])
        #expect(after.shapes == ["400x500@0", "200x100@0", "300x300@0", "200x100@90"])
        // The tree is now flat: every page hangs off the root.
        let file = try PDFFile(data: saved)
        let root = try #require(try file.catalog()["Pages"]?.referenceValue)
        for page in try file.pageIDs() {
            #expect(try file.object(page).dictionaryValue?["Parent"]?.referenceValue == root)
        }
        #expect(try file.object(root).dictionaryValue?["Count"]?.intValue == 4)
    }

    @Test func cropBoxIsSetClippedAndCleared() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.setCropBox(PDFRectangle(x: 100, y: 100, width: 5000, height: 200), forPageAt: 1)
        #expect(try editor.pageBox(at: 1) == PDFRectangle(x: 100, y: 100, width: 512, height: 200))
        #expect(try editor.pageBox(at: 1, cropped: false) == PDFRectangle(x: 0, y: 0, width: 612, height: 792))
        #expect(try Reference(editor.serialized()).shapes == ["612x792@0", "512x200@0", "612x792@0"])
        try editor.setCropBox(nil, forPageAt: 1)
        #expect(try Reference(editor.serialized()).shapes == ["612x792@0", "612x792@0", "612x792@0"])
        #expect(throws: SheafError.self) { try editor.setCropBox(PDFRectangle(x: 9000, y: 0, width: 10, height: 10), forPageAt: 0) }
    }

    @Test func blankPagesCanBeInserted() throws {
        let saved = try edited(Fixture.text3Pages.data) { editor in
            try editor.insertBlankPage(size: .a4, at: 1)
            try editor.insertBlankPage(size: PageSize(width: 100, height: 50), at: 4)
        }
        let reference = try Reference(saved)
        #expect(reference.shapes == ["612x792@0", "595x842@0", "612x792@0", "612x792@0", "100x50@0"])
        #expect(reference.texts.map { $0.prefix(6) } == ["Page 1", "", "Page 2", "Page 3", ""])
    }

    @Test func duplicatedPagesShareContentButNotAnnotations() throws {
        let data = try Fixture.outlineAnnotations.data
        let original = try PDFFile(data: data)
        var editor = PDFEditor(original)
        try editor.duplicatePage(at: 0)
        let saved = try editor.serialized()
        let reference = try Reference(saved)
        #expect(reference.pageCount == 13)
        #expect(reference.texts[1] == reference.texts[0])

        let file = try PDFFile(data: saved)
        let pages = try file.pageIDs()
        let first = try #require(try file.object(pages[0]).dictionaryValue)
        let copy = try #require(try file.object(pages[1]).dictionaryValue)
        #expect(copy["Contents"] == first["Contents"])
        let firstAnnotations = try #require(try file.value("Annots", in: first).arrayValue)
        let copyAnnotations = try #require(try file.value("Annots", in: copy).arrayValue)
        #expect(copyAnnotations.count == firstAnnotations.count)
        #expect(Set(copyAnnotations.compactMap(\.referenceValue)).isDisjoint(with: firstAnnotations.compactMap(\.referenceValue)))
        for annotation in copyAnnotations {
            #expect(try file.resolve(annotation).dictionaryValue?["P"]?.referenceValue == pages[1])
        }
        #expect(reference.document.page(at: 1)?.annotations.count == reference.document.page(at: 0)?.annotations.count)
    }

    // MARK: Merging

    @Test func pagesFromAnotherDocumentCanBeAdded() throws {
        let target = try Fixture.text3Pages.data, source = try Fixture.outlineAnnotations.data
        var editor = PDFEditor(try PDFFile(data: target))
        try editor.insertPages(from: PDFFile(data: source))
        let saved = try editor.serialized()
        #expect(saved.prefix(target.count) == target)
        let merged = try Reference(saved)
        #expect(merged.pageCount == 15)
        #expect(merged.texts == (try Reference(target).texts) + (try Reference(source).texts))
        #expect(merged.shapes == (try Reference(target).shapes) + (try Reference(source).shapes))
        // Annotations came along and belong to their new pages.
        #expect(merged.document.page(at: 3)?.annotations.count == (try Reference(source)).document.page(at: 0)?.annotations.count)
    }

    @Test func chosenPagesGoWhereAsked() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.insertPages(from: PDFFile(data: TestPDF.nestedTree()), pageIndexes: [3, 0], at: 1)
        let reference = try Reference(editor.serialized())
        #expect(reference.texts.map { String($0.prefix(6)) } == ["Page 1", "Page 4", "Page 1", "Page 2", "Page 3"])
        #expect(reference.shapes == ["612x792@0", "400x500@0", "200x100@90", "612x792@0", "612x792@0"])
        #expect(throws: SheafError.pageOutOfRange(9)) {
            try editor.insertPages(from: PDFFile(data: TestPDF.nestedTree()), pageIndexes: [9])
        }
    }

    @Test func theSamePageCanBeAddedTwice() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.handwritten.data))
        let source = try PDFFile(data: Fixture.outlineAnnotations.data)
        let added = try editor.insertPages(from: source, pageIndexes: [0, 0])
        let file = try PDFFile(data: editor.serialized())
        #expect(try file.pageIDs().count == 3)
        // Each copy has its own annotation objects.
        let first = try #require(try file.value("Annots", in: file.object(added[0]).dictionaryValue ?? [:]).arrayValue)
        let second = try #require(try file.value("Annots", in: file.object(added[1]).dictionaryValue ?? [:]).arrayValue)
        #expect(!first.isEmpty)
        #expect(Set(first.compactMap(\.referenceValue)).isDisjoint(with: second.compactMap(\.referenceValue)))
    }

    @Test func identicalStreamsFromRepeatedImportsAreStoredOnce() throws {
        let source = try PDFFile(data: Fixture.text3Pages.data)
        var editor = PDFEditor(try PDFFile(data: Fixture.handwritten.data))
        try editor.insertPages(from: source)
        let afterFirst = editor.changedNumbers.count
        try editor.insertPages(from: PDFFile(data: Fixture.text3Pages.data))
        let afterSecond = editor.changedNumbers.count
        // The second import reuses the font programs and content of the first.
        #expect(afterSecond - afterFirst < afterFirst - 1)
        #expect(try Reference(editor.serialized()).pageCount == 7)
    }

    @Test func linksToPagesLeftBehindAreDropped() throws {
        // Page 4 of the nested fixture, given a link to page 1, which is not copied.
        var source = PDFEditor(try PDFFile(data: TestPDF.nestedTree()))
        let pages = try source.pageIDs()
        let link = source.add(["Type": .name("Annot"), "Subtype": .name("Link"), "Rect": [0, 0, 10, 10], "Dest": [.reference(pages[0]), .name("Fit")], "P": .reference(pages[3])])
        try source.update(pages[3]) { $0["Annots"] = [.reference(link)] }

        var editor = PDFEditor(try PDFFile(data: Fixture.handwritten.data))
        let added = try editor.insertPages(from: source, pageIndexes: [3])
        let file = try PDFFile(data: editor.serialized())
        #expect(try file.pageIDs().count == 2)
        let annotations = try #require(try file.value("Annots", in: file.object(added[0]).dictionaryValue ?? [:]).arrayValue)
        let copied = try #require(try file.resolve(annotations[0]).dictionaryValue)
        #expect(copied["P"]?.referenceValue == added[0])
        #expect(copied["Dest"] == nil)
        #expect(copied["Rect"] == [0, 0, 10, 10])
        // Nothing of the other three pages was dragged along.
        let appended = try editor.serialized().suffix(from: Fixture.handwritten.data.count)
        #expect(!String(decoding: appended, as: UTF8.self).contains("(Page 1)"))
    }

    // MARK: Information

    @Test func informationIsReadAndWritten() throws {
        let data = try Fixture.text3Pages.data
        var editor = PDFEditor(try PDFFile(data: data))
        var info = try editor.info()
        #expect(info.title == "Sheaf Text Fixture")
        #expect(info.author == "SheafKit")
        #expect(info.creationDate != nil)
        info.title = "Заголовок 🙂"
        info.author = nil
        info.keywords = "one, two"
        info.modificationDate = Date(timeIntervalSince1970: 1_800_000_000)
        try editor.setInfo(info)
        let saved = try editor.serialized()

        let read = try PDFFile(data: saved).info()
        #expect(read == info)
        let attributes = try #require(try Reference(saved).document.documentAttributes)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Заголовок 🙂")
        #expect(attributes[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date == info.modificationDate)
    }

    @Test func informationIsCreatedWhenMissing() throws {
        let saved = try edited(Fixture.handwritten.data) { try $0.setInfo(DocumentInfo(title: "New", subject: "Made here")) }
        #expect(try PDFFile(data: saved).info() == DocumentInfo(title: "New", subject: "Made here"))
        #expect(try Reference(saved).document.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String == "Made here")
    }

    @Test func copiesOfAnEditorAreIndependent() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.rotatePage(at: 0, by: 90)
        let snapshot = editor
        try editor.removePages(at: [2])
        #expect(try snapshot.pageCount() == 3)
        #expect(try editor.pageCount() == 2)
        #expect(try Reference(snapshot.serialized()).shapes.first == "612x792@90")
    }
}
