import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct ContentStreamTests {
    @Test func readsOperationsAndOperands() {
        let content = ContentStream(data: Data("q 1 0 0 1 72.5 700 cm\nBT /F1 12 Tf (Hi) Tj [(A) -20 (B)] TJ ET Q".utf8))
        #expect(content.operations.map(\.name) == ["q", "cm", "BT", "Tf", "Tj", "TJ", "ET", "Q"])
        #expect(content.operations[1].operands == [1, 0, 0, 1, 72.5, 700])
        #expect(content.operations[3].operands == [.name("F1"), 12])
        #expect(content.operations[4].operands == [.string(Data("Hi".utf8))])
        #expect(content.operations[5].operands == [[.string(Data("A".utf8)), -20, .string(Data("B".utf8))]])
    }

    @Test(arguments: [
        "q\n  1 0 0 1 0 0 cm % a comment\r\n/GS1 gs\tQ   \n",
        "0 0 m 10 10 l S",
        "BT/F1 12 Tf(tight)Tj ET",
        "",
        "   \n",
        "/Im1 Do 1 2 3", // operands with no operator at the end
        "1 0 R f", // not a reference inside content
        "T* (a) ' 1 2 (b) \" true false null BDC <</MCID 0>> BDC EMC",
    ])
    func untouchedContentIsWrittenBackExactly(text: String) {
        let data = Data(text.utf8)
        #expect(ContentStream(data: data).data() == data)
    }

    @Test func unreadableTailIsKept() {
        let data = Data("q 1 0 0 1 0 0 cm [1 2 (never closed".utf8)
        let content = ContentStream(data: data)
        #expect(content.operations.map(\.name) == ["q", "cm"])
        #expect(content.data() == data)
    }

    @Test func inlineImagesAreKeptWhole() {
        var data = Data("q 10 0 0 10 0 0 cm BI /W 2 /H 2 /BPC 8 /CS /G ID ".utf8)
        let pixels = Data([0x00, 0xFF, 0x45, 0x49]) // ends in the letters "EI", which must not end the image
        data.append(pixels)
        data.append(Data("\nEI Q 1 0 0 RG".utf8))
        let content = ContentStream(data: data)
        #expect(content.operations.map(\.name) == ["q", "cm", "BI", "Q", "RG"])
        #expect(content.operations[2].operands == [["W": 2, "H": 2, "BPC": 8, "CS": .name("G")]])
        #expect(content.operations[2].inlineImageData == pixels)
        #expect(content.data() == data)

        var changed = content
        changed.operations[2].inlineImageData = Data([1, 2, 3, 4])
        let reread = ContentStream(data: changed.data())
        #expect(reread.operations[2].inlineImageData == Data([1, 2, 3, 4]))
        #expect(reread.operations.map(\.name) == ["q", "cm", "BI", "Q", "RG"])
    }

    @Test func aChangeOnlyTouchesItsOwnBytes() {
        let original = "q\n1 0 0 1 10 10 cm   % move\nBT /F1 12 Tf (Old) Tj ET\nQ\n"
        var content = ContentStream(data: Data(original.utf8))
        content.operations[4].operands = [.string(Data("New".utf8))]
        #expect(String(decoding: content.data(), as: UTF8.self) == "q\n1 0 0 1 10 10 cm   % move\nBT /F1 12 Tf\n(New) Tj ET\nQ\n")

        content.operations.remove(at: 1)
        content.operations.insert(ContentStream.Operation("w", [2.5]), at: 0)
        #expect(ContentStream(data: content.data()).operations.map(\.name) == ["w", "q", "BT", "Tf", "Tj", "ET", "Q"])
    }

    @Test func newContentIsSerialized() {
        let content = ContentStream(operations: [
            .init("BT"), .init("Tf", [.name("F1"), 10]), .init("Td", [72, 700.5]),
            .init("Tj", [.string(Data("Made here".utf8))]), .init("ET"),
        ])
        #expect(String(decoding: content.data(), as: UTF8.self) == "BT\n/F1 10 Tf\n72 700.5 Td\n(Made here) Tj\nET")
    }

    @Test(arguments: [Fixture.text3Pages, .image1Page, .handwritten, .outlineAnnotations])
    func everyFixturePageRoundTrips(fixture: Fixture) throws {
        let file = try PDFFile(data: fixture.data)
        for page in try file.pageIDs() {
            let dictionary = try #require(try file.object(page).dictionaryValue)
            let stream = try #require(try file.value("Contents", in: dictionary).streamValue)
            let decoded = try file.decodedData(of: stream)
            let content = try file.contentStream(forPage: page)
            #expect(!content.operations.isEmpty)
            #expect(content.data() == decoded)
        }
    }

    @Test func editedTextShowsUpInTheSavedPage() throws {
        let data = try Fixture.handwritten.data
        var editor = PDFEditor(try PDFFile(data: data))
        var content = try editor.contentStream(forPageAt: 0)
        let index = try #require(content.operations.firstIndex { $0.name == "Tj" })
        content.operations[index].operands = [.string(Data("Hello, world".utf8))]
        try editor.setContentStream(content, forPageAt: 0)
        let saved = try editor.serialized()
        #expect(saved.prefix(data.count) == data)
        #expect(try Reference(saved).texts == ["Hello, world"])
        #expect(try PDFFile(data: saved).contentStream(forPage: try PDFFile(data: saved).pageIDs()[0]) == content)
    }

    @Test func aPageWithSeveralContentStreamsReadsAsOne() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.handwritten.data))
        let page = try editor.pageIDs()[0]
        let first = editor.add(.stream(PDFStream(data: Data("BT /F1 24 Tf 72 700 Td".utf8))))
        let second = editor.add(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(Data("(Split) Tj ET".utf8)))))
        try editor.update(page) { $0["Contents"] = [.reference(first), .reference(second)] }
        let content = try editor.contentStream(forPageAt: 0)
        #expect(content.operations.map(\.name) == ["BT", "Tf", "Td", "Tj", "ET"])
        #expect(try Reference(editor.serialized()).texts == ["Split"])
    }
}
