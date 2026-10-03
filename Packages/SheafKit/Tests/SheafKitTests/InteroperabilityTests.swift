import CoreGraphics
import CoreText
import Foundation
import PDFKit
@testable import SheafKit
import Testing

/// Files protected by Apple's writers must open in the engine.
@Suite struct InteroperabilityTests {
    /// A one-page PDF made by Core Graphics with the given encryption settings.
    private func coreGraphicsPDF(_ options: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, options as CFDictionary))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Protected text",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)]
        ))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func checkOpens(_ data: Data, user: String, owner: String, canPrint: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(throws: SheafError.passwordRequired, sourceLocation: sourceLocation) { try PDFFile(data: data) }
        #expect(throws: SheafError.incorrectPassword, sourceLocation: sourceLocation) { try PDFFile(data: data, password: "not it") }
        for (password, isOwner) in [(user, false), (owner, true)] {
            let file = try PDFFile(data: data, password: password)
            #expect(file.isOpenedAsOwner == isOwner, sourceLocation: sourceLocation)
            #expect(file.permissions.contains(.print) == (isOwner || canPrint), sourceLocation: sourceLocation)
            let page = try #require(try file.pageIDs().first)
            let content = try file.contentStream(forPage: page)
            #expect(content.operations.contains { $0.name == "BT" }, sourceLocation: sourceLocation)
            #expect(!content.hasUnreadableTail, sourceLocation: sourceLocation)
            for number in file.objectNumbers { _ = try file.object(ObjectID(number)) }
            // Decrypted and written back out without protection, PDFKit reads the text.
            let open = try PDFEditor(file).rewritten(protection: .none)
            #expect(try Reference(open).texts == ["Protected text"], sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [40, 128])
    func coreGraphicsEncryption(keyLength: Int) throws {
        let data = try coreGraphicsPDF([
            kCGPDFContextUserPassword: "user", kCGPDFContextOwnerPassword: "owner",
            kCGPDFContextEncryptionKeyLength: keyLength, kCGPDFContextAllowsPrinting: false,
        ])
        let algorithm = try PDFFile(data: data, password: "user").encryptionAlgorithm
        #expect(algorithm == (keyLength == 40 ? .rc4(bits: 40) : .aes128))
        try checkOpens(data, user: "user", owner: "owner", canPrint: false)
    }

    @Test func pdfKitEncryption() throws {
        let plain = try coreGraphicsPDF([:])
        let document = try #require(PDFDocument(data: plain))
        let data = try #require(document.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "user", PDFDocumentWriteOption.ownerPasswordOption: "owner",
        ]))
        let algorithm = try PDFFile(data: data, password: "user").encryptionAlgorithm
        #expect(algorithm == .rc4(bits: 128))
        try checkOpens(data, user: "user", owner: "owner", canPrint: true)
    }

    @Test func fixtureEncryptionIsIdentified() throws {
        let file = try PDFFile(data: Fixture.encrypted.data, password: "sheaf")
        #expect(file.encryptionAlgorithm == .aes128)
    }
}

/// Timings on a large generated document. Prints numbers; fails only on gross slowness.
@Suite struct PerformanceTests {
    @Test func largeDocument() throws {
        let pageCount = 3000
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: output as CFMutableData)!, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            for row in 0..<40 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: "Page \(index + 1), line \(row + 1): the quick brown fox jumps over the lazy dog.",
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                ))
                context.textPosition = CGPoint(x: 50, y: 740 - Double(row) * 17)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let data = output as Data

        let clock = ContinuousClock()
        var file: PDFFile!
        let open = try clock.measure { file = try PDFFile(data: data) }
        var pages: [ObjectID] = []
        let walk = try clock.measure { pages = try file.pageIDs() }
        #expect(pages.count == pageCount)

        var editor = PDFEditor(file)
        let edit = try clock.measure {
            try editor.arrangePages(Array((0..<pageCount).reversed()))
            try editor.rotatePage(at: 10, by: 90)
            try editor.removePages(at: 100..<200)
        }
        var appended = Data()
        let save = try clock.measure { appended = try editor.serialized() }
        var rewritten = Data()
        let rewrite = try clock.measure { rewritten = try editor.rewritten() }
        var protected = Data()
        let protect = try clock.measure { protected = try editor.rewritten(protection: .password(user: "p")) }
        let reopen = try clock.measure { _ = try PDFFile(data: protected, password: "p").pageIDs() }

        func megabytes(_ data: Data) -> String { String(format: "%.1f MB", Double(data.count) / 1_048_576) }
        print("perf: \(pageCount) pages, \(megabytes(data)), \(file.objectNumbers.count) objects")
        print("perf: open \(open), walk pages \(walk), edit \(edit)")
        print("perf: append save \(save) (+\(appended.count - data.count) bytes), rewrite \(rewrite) (\(megabytes(rewritten))), protect \(protect), reopen protected \(reopen)")
        #expect(try Reference(appended).pageCount == pageCount - 100)
        #expect(try Reference(rewritten).pageCount == pageCount - 100)
        #expect(open + walk + edit + save < .seconds(10))
    }
}
