import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct MetadataTests {
    /// The kind of packet other tools write: some facts as attributes, some as elements,
    /// and a claim the engine knows nothing about.
    private static let packet = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Some Toolkit">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" pdf:Producer="Old Producer" pdf:Keywords="old, words"/>
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
          <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Old Title</rdf:li></rdf:Alt></dc:title>
          <dc:creator><rdf:Seq><rdf:li>First Author</rdf:li><rdf:li>Second Author</rdf:li></rdf:Seq></dc:creator>
          <xmp:CreateDate>2020-03-04T05:06:07+02:00</xmp:CreateDate>
        </rdf:Description>
        <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"><pdfaid:part>2</pdfaid:part></rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    /// A document whose facts are only in XMP, the way PDF 2.0 files carry them.
    private func documentWithPacket(compressed: Bool) throws -> PDFEditor {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 100, height: 100)])))
        let data = Data(Self.packet.utf8)
        let stream = compressed
            ? PDFStream(dictionary: ["Type": .name("Metadata"), "Subtype": .name("XML"), "Filter": .name("FlateDecode")], data: Flate.deflate(data))
            : PDFStream(dictionary: ["Type": .name("Metadata"), "Subtype": .name("XML")], data: data)
        let metadata = editor.add(.stream(stream))
        try editor.update(try #require(editor.catalogID)) { $0["Metadata"] = .reference(metadata) }
        return editor
    }

    @Test func factsMissingFromTheInformationDictionaryComeFromXMP() throws {
        let info = try documentWithPacket(compressed: true).info()
        #expect(info.title == "Old Title")
        #expect(info.author == "First Author, Second Author")
        #expect(info.producer == "Old Producer")
        #expect(info.keywords == "old, words")
        #expect(info.subject == nil)
        #expect(info.creationDate == Date(timeIntervalSince1970: 1_583_291_167))
    }

    @Test(arguments: [true, false])
    func changingTheInformationUpdatesXMPAndKeepsTheRest(compressed: Bool) throws {
        var editor = try documentWithPacket(compressed: compressed)
        var info = try editor.info()
        info.title = "Новое название <&>"
        info.author = "Valery"
        info.keywords = nil
        info.subject = "A subject"
        info.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try editor.setInfo(info)

        let file = try PDFFile(data: editor.serialized())
        let stream = try #require(file.value("Metadata", in: file.catalog()).streamValue)
        #expect(stream.dictionary["Filter"] == nil)
        let text = String(decoding: stream.data, as: UTF8.self)
        #expect(text.hasPrefix("<?xpacket begin=") && text.hasSuffix("<?xpacket end=\"w\"?>"))
        #expect(!text.contains("Old Title") && !text.contains("First Author") && !text.contains("old, words"))
        #expect(text.contains("pdfaid:part") && text.contains("Some Toolkit"))
        #expect(text.contains("2023-11-14T22:13:20"))

        // Both places now say the same thing.
        let fromXMP = XMP.read(stream.data)
        #expect(fromXMP.title == "Новое название <&>")
        #expect(fromXMP.author == "Valery")
        #expect(fromXMP.subject == "A subject")
        #expect(fromXMP.keywords == nil)
        #expect(fromXMP.producer == "Old Producer")
        #expect(fromXMP.modificationDate == info.modificationDate)
        #expect(try file.info() == info)
        let attributes = try #require(Reference(file.data).document.documentAttributes)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Новое название <&>")

        // A second change does not pile up duplicates.
        var again = PDFEditor(file)
        info.title = "Third"
        try again.setInfo(info)
        let third = String(decoding: try again.metadataPacket() ?? Data(), as: UTF8.self)
        #expect(third.components(separatedBy: "<dc:title>").count == 2)
        #expect(third.components(separatedBy: "xmlns:dc=").count == text.components(separatedBy: "xmlns:dc=").count)
        #expect(abs(third.count - text.count) < 40)
    }

    @Test func aBrokenPacketIsReplaced() throws {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 100, height: 100)])))
        let metadata = editor.add(.stream(PDFStream(dictionary: ["Type": .name("Metadata")], data: Data("<x:xmpmeta><unclosed>".utf8))))
        try editor.update(try #require(editor.catalogID)) { $0["Metadata"] = .reference(metadata) }
        try editor.setInfo(DocumentInfo(title: "Fixed"))
        #expect(XMP.read(try editor.metadataPacket() ?? Data()).title == "Fixed")
    }

    @Test func documentsWithoutXMPDoNotGainAny() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.handwritten.data))
        try editor.setInfo(DocumentInfo(title: "Plain"))
        #expect(try editor.catalog()["Metadata"] == nil)
        #expect(try editor.info().title == "Plain")
    }
}
