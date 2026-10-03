import CoreGraphics
import Foundation
@testable import SheafKit
import Testing

@Suite struct FileTests {
    @Test(arguments: [Fixture.text3Pages, .image1Page, .handwritten, .outlineAnnotations])
    func fixturesOpenAndMatchCoreGraphics(fixture: Fixture) throws {
        let data = try fixture.data
        let file = try PDFFile(data: data)
        let expected = try PDFInspector.summary(of: data)
        #expect(try file.pageIDs().count == expected.pageCount)
        #expect(try file.catalog()["Type"]?.nameValue == "Catalog")
        #expect(!file.isEncrypted)
        #expect(file.permissions == .all)
        #expect((file.version.major, file.version.minor) == (expected.majorVersion, expected.minorVersion))
        // Every object the table lists can be read.
        for number in file.objectNumbers {
            _ = try file.object(ObjectID(number))
        }
        // Page sizes and rotations agree with Core Graphics.
        for (id, page) in zip(try file.pageIDs(), expected.pages) {
            let box = try #require(PDFRectangle(try file.resolve(try file.inherited("MediaBox", forPage: id) ?? .null)))
            #expect(PageSize(width: box.width, height: box.height) == page.size)
            #expect((try file.inherited("Rotate", forPage: id)?.intValue ?? 0) == page.rotation)
        }
    }

    @Test func handwrittenContentIsReadable() throws {
        let file = try PDFFile(data: Fixture.handwritten.data)
        let page = try #require(try file.pageIDs().first)
        let dictionary = try #require(try file.object(page).dictionaryValue)
        let contents = try #require(try file.value("Contents", in: dictionary).streamValue)
        #expect(String(decoding: try file.decodedData(of: contents), as: UTF8.self) == "BT /F1 24 Tf 72 700 Td (Hello, Sheaf) Tj ET")
        #expect(try file.resolve(file.trailer["Info"] ?? .null) == .null)
    }

    @Test func compressedContentStreamsDecode() throws {
        let file = try PDFFile(data: Fixture.text3Pages.data)
        for page in try file.pageIDs() {
            let dictionary = try #require(try file.object(page).dictionaryValue)
            let contents = try #require(try file.value("Contents", in: dictionary).streamValue)
            let text = String(decoding: try file.decodedData(of: contents), as: UTF8.self)
            #expect(text.contains("BT") && text.contains("ET"))
        }
        let info = try #require(try file.resolve(file.trailer["Info"] ?? .null).dictionaryValue)
        #expect(info["Title"]?.textValue == "Sheaf Text Fixture")
    }

    @Test(arguments: [true, false])
    func objectStreamsAndCrossReferenceStreams(predictor: Bool) throws {
        let data = TestPDF.compressed(predictor: predictor)
        let file = try PDFFile(data: data)
        #expect(file.crossReference.newestSectionIsStream)
        #expect(!file.crossReference.wasRebuilt)
        let pages = try file.pageIDs()
        #expect(pages == [ObjectID(3), ObjectID(4)])
        #expect(try file.inherited("Rotate", forPage: pages[1])?.intValue == 180)
        #expect(try file.inherited("MediaBox", forPage: pages[0]) == [0, 0, 300, 200])
        #expect(try file.resolve(file.trailer["Info"] ?? .null).dictionaryValue?["Title"]?.textValue == "Packed")
        let contents = try #require(try file.object(ObjectID(8)).streamValue)
        #expect(String(decoding: try file.decodedData(of: contents), as: UTF8.self).contains("(First page)"))
        // Core Graphics agrees that this hand-built file is sound.
        #expect(try PDFInspector.summary(of: data).pageCount == 2)
    }

    @Test func junkBeforeTheHeaderIsTolerated() throws {
        let data = Data("garbage line\r\n".utf8) + (try Fixture.handwritten.data)
        let file = try PDFFile(data: data)
        #expect(file.headerOffset == 14)
        #expect(try file.pageIDs().count == 1)
    }

    @Test func dataSlicesWork() throws {
        let padded = Data(repeating: 0x20, count: 100) + (try Fixture.text3Pages.data)
        let file = try PDFFile(data: padded.dropFirst(100))
        #expect(try file.pageIDs().count == 3)
    }

    @Test(arguments: [Fixture.text3Pages, .handwritten, .outlineAnnotations])
    func wrongStartxrefIsRepaired(fixture: Fixture) throws {
        var text = try fixture.data
        let marker = try #require(text.range(of: Data("startxref\n".utf8), options: .backwards))
        text.replaceSubrange(marker.upperBound..<text.endIndex, with: Data("5\n%%EOF\n".utf8))
        let file = try PDFFile(data: text)
        #expect(file.crossReference.wasRebuilt)
        #expect(try file.pageIDs().count == (try PDFFile(data: fixture.data)).pageIDs().count)
    }

    @Test func missingTrailerIsRepaired() throws {
        let data = try Fixture.text3Pages.data
        let xref = try #require(data.range(of: Data("\nxref\n".utf8), options: .backwards))
        let file = try PDFFile(data: data.prefix(upTo: xref.lowerBound))
        #expect(file.crossReference.wasRebuilt)
        #expect(try file.pageIDs().count == 3)
    }

    @Test func compressedFileWithoutItsTableIsRepaired() throws {
        let data = TestPDF.compressed()
        let marker = try #require(data.range(of: Data("startxref".utf8), options: .backwards))
        var broken = data.prefix(upTo: marker.lowerBound)
        broken.append(Data("startxref\n999999\n%%EOF\n".utf8))
        let file = try PDFFile(data: broken)
        #expect(file.crossReference.wasRebuilt)
        #expect(try file.pageIDs() == [ObjectID(3), ObjectID(4)])
    }

    @Test func shiftedOffsetsAreRepaired() throws {
        // Insert a line after the header: every offset in the table now points 40 bytes early.
        var data = try Fixture.text3Pages.data
        let headerEnd = try #require(data.firstIndex(of: 0x0A)) + 1
        let inserted = Data("% thirty-nine bytes of inserted comment\n".utf8)
        data.insert(contentsOf: inserted, at: headerEnd)
        let marker = try #require(data.range(of: Data("startxref\n".utf8), options: .backwards))
        let old = Int(String(decoding: data[marker.upperBound...].prefix { $0 != 0x0A }, as: UTF8.self))!
        data.replaceSubrange(marker.upperBound..<data.endIndex, with: Data("\(old + inserted.count)\n%%EOF\n".utf8))
        let file = try PDFFile(data: data)
        #expect(file.crossReference.wasRebuilt)
        #expect(try file.pageIDs().count == 3)
        for number in file.objectNumbers { _ = try file.object(ObjectID(number)) }
    }

    @Test func offsetsOffByWhitespaceStillWork() throws {
        var data = try Fixture.text3Pages.data
        let headerEnd = try #require(data.firstIndex(of: 0x0A)) + 1
        data.insert(0x0A, at: headerEnd)
        let marker = try #require(data.range(of: Data("startxref\n".utf8), options: .backwards))
        let old = Int(String(decoding: data[marker.upperBound...].prefix { $0 != 0x0A }, as: UTF8.self))!
        data.replaceSubrange(marker.upperBound..<data.endIndex, with: Data("\(old + 1)\n%%EOF\n".utf8))
        #expect(try PDFFile(data: data).pageIDs().count == 3)
    }

    @Test(arguments: [Data(), Data("not a pdf".utf8), Data("%PDF-1.7\nnothing else".utf8), Data(repeating: 0xFF, count: 5000)])
    func garbageIsRejected(data: Data) {
        #expect(throws: SheafError.notAPDF) { try PDFFile(data: data) }
    }

    // MARK: Encryption

    @Test func encryptedFixtureNeedsItsPassword() throws {
        let data = try Fixture.encrypted.data
        #expect(throws: SheafError.passwordRequired) { try PDFFile(data: data) }
        #expect(throws: SheafError.incorrectPassword) { try PDFFile(data: data, password: "nope") }
    }

    @Test(arguments: [("sheaf", false), ("owner", true)])
    func encryptedFixtureOpens(password: String, isOwner: Bool) throws {
        let file = try PDFFile(data: Fixture.encrypted.data, password: password)
        #expect(file.isEncrypted)
        #expect(file.isOpenedAsOwner == isOwner)
        let page = try #require(try file.pageIDs().first)
        let dictionary = try #require(try file.object(page).dictionaryValue)
        let contents = try #require(try file.value("Contents", in: dictionary).streamValue)
        // Decryption worked if the stream inflates into drawing operators.
        let text = String(decoding: try file.decodedData(of: contents), as: UTF8.self)
        #expect(text.contains("BT") && text.contains("Tf"))
        for number in file.objectNumbers { _ = try file.object(ObjectID(number)) }
    }
}
