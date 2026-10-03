import CoreGraphics
import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct WriterTests {
    static let plainFixtures: [Fixture] = [.text3Pages, .image1Page, .handwritten, .outlineAnnotations]

    // MARK: Writing afresh

    @Test(arguments: plainFixtures)
    func rewritingKeepsEveryPageAsItWas(fixture: Fixture) throws {
        let data = try fixture.data
        let rewritten = try PDFEditor(PDFFile(data: data)).rewritten()
        let before = try Reference(data), after = try Reference(rewritten)
        #expect(after.texts == before.texts)
        #expect(after.shapes == before.shapes)
        for index in 0..<before.pageCount {
            #expect(after.pixels(ofPage: index) == before.pixels(ofPage: index))
            #expect(after.document.page(at: index)?.annotations.count == before.document.page(at: index)?.annotations.count)
        }
        #expect(after.document.outlineRoot?.numberOfChildren == before.document.outlineRoot?.numberOfChildren)
        let file = try PDFFile(data: rewritten)
        #expect(!file.crossReference.wasRebuilt)
        #expect(try file.info() == (try PDFFile(data: data).info()))
        // Rewriting what was just rewritten changes nothing but the file identifier.
        let again = try PDFEditor(file).rewritten()
        #expect(again.count == rewritten.count)
        // And writing the same document twice gives the same bytes.
        #expect(try PDFEditor(PDFFile(data: data)).rewritten() == rewritten)
    }

    @Test func rewritingUnpacksObjectStreams() throws {
        let rewritten = try PDFEditor(PDFFile(data: TestPDF.compressed())).rewritten()
        let file = try PDFFile(data: rewritten)
        #expect(!file.crossReference.newestSectionIsStream)
        #expect(try file.info().title == "Packed")
        #expect(try Reference(rewritten).texts == ["First page", "Second page"])
        #expect(try Reference(rewritten).shapes == ["300x200@0", "300x200@180"])
    }

    @Test func rewritingDropsWhatIsNoLongerUsed() throws {
        let data = TestPDF.nestedTree()
        var editor = PDFEditor(try PDFFile(data: data))
        try editor.removePages(at: [1, 2])

        // Appending keeps the removed pages' content in the file.
        let appended = String(decoding: try editor.serialized(), as: UTF8.self)
        #expect(appended.contains("(Page 2)") && appended.contains("(Page 3)"))

        let rewritten = try editor.rewritten()
        let text = String(decoding: rewritten, as: UTF8.self)
        #expect(!text.contains("(Page 2)") && !text.contains("(Page 3)"))
        #expect(text.contains("(Page 1)") && text.contains("(Page 4)"))
        #expect(try Reference(rewritten).texts == ["Page 1", "Page 4"])
        // The intermediate page tree nodes are gone as well.
        #expect(try PDFFile(data: rewritten).objectNumbers.count < (try PDFFile(data: data)).objectNumbers.count - 2)
    }

    // MARK: Protection

    @Test(arguments: [EncryptionAlgorithm.aes256, .aes128, .rc4(bits: 128), .rc4(bits: 40)])
    func passwordsCanBeSet(algorithm: EncryptionAlgorithm) throws {
        let original = try Fixture.outlineAnnotations.data
        let protected = try PDFEditor(PDFFile(data: original)).rewritten(
            protection: .password(user: "open sesame", owner: "master", permissions: [.print, .copy], algorithm: algorithm)
        )

        // Apple's reader agrees: locked, and opened by either password.
        let locked = try #require(PDFDocument(data: protected))
        #expect(locked.isEncrypted && locked.isLocked)
        #expect(!locked.unlock(withPassword: "wrong"))
        let expected = try Reference(original)
        for password in ["open sesame", "master"] {
            let unlocked = try Reference(protected, password: password)
            #expect(unlocked.texts == expected.texts)
            #expect(unlocked.document.outlineRoot?.child(at: 0)?.label == "Introduction")
        }
        let asUser = try #require(PDFDocument(data: protected))
        #expect(asUser.unlock(withPassword: "open sesame"))
        #expect(asUser.allowsPrinting && asUser.allowsCopying)
        #expect(!asUser.allowsDocumentChanges && !asUser.allowsCommenting)

        // And the engine reads its own protected file.
        #expect(throws: SheafError.passwordRequired) { try PDFFile(data: protected) }
        #expect(throws: SheafError.incorrectPassword) { try PDFFile(data: protected, password: "wrong") }
        let user = try PDFFile(data: protected, password: "open sesame")
        #expect(user.encryptionAlgorithm == algorithm)
        #expect(!user.isOpenedAsOwner)
        #expect(user.permissions == [.print, .copy])
        #expect(try user.info() == (try PDFFile(data: original).info()))
        let owner = try PDFFile(data: protected, password: "master")
        #expect(owner.isOpenedAsOwner)
        #expect(owner.permissions == .all)
        for number in owner.objectNumbers { _ = try owner.object(ObjectID(number)) }
    }

    @Test func unicodePasswordsWork() throws {
        let protected = try PDFEditor(PDFFile(data: Fixture.handwritten.data)).rewritten(protection: .password(user: "пароль-密码"))
        #expect(try PDFFile(data: protected, password: "пароль-密码").pageIDs().count == 1)
        let reader = try #require(PDFDocument(data: protected))
        #expect(reader.unlock(withPassword: "пароль-密码"))
    }

    @Test func anEmptyUserPasswordOpensWithoutAsking() throws {
        let protected = try PDFEditor(PDFFile(data: Fixture.text3Pages.data)).rewritten(
            protection: .password(user: "", owner: "boss", permissions: [.print])
        )
        let file = try PDFFile(data: protected)
        #expect(file.isEncrypted && !file.isOpenedAsOwner)
        #expect(file.permissions == [.print])
        let reader = try #require(PDFDocument(data: protected))
        #expect(reader.isEncrypted && !reader.isLocked)
        #expect(!reader.allowsCopying)
        #expect(try PDFFile(data: protected, password: "boss").isOpenedAsOwner)
    }

    @Test func passwordsCanBeRemoved() throws {
        let file = try PDFFile(data: Fixture.encrypted.data, password: "sheaf")
        let open = try PDFEditor(file).rewritten(protection: .none)
        let reader = try #require(PDFDocument(data: open))
        #expect(!reader.isEncrypted)
        #expect(reader.page(at: 0)?.string?.contains("Secret") == true)
        #expect(!(try PDFFile(data: open)).isEncrypted)
    }

    @Test func protectionIsKeptByDefault() throws {
        let data = try Fixture.encrypted.data
        var editor = PDFEditor(try PDFFile(data: data, password: "sheaf"))
        try editor.rotatePage(at: 0, by: 90)
        try editor.setInfo(DocumentInfo(title: "Still secret"))

        for saved in [try editor.serialized(), try editor.rewritten()] {
            #expect(throws: SheafError.passwordRequired) { try PDFFile(data: saved) }
            for password in ["sheaf", "owner"] {
                let file = try PDFFile(data: saved, password: password)
                #expect(try file.info().title == "Still secret")
                let reference = try Reference(saved, password: password)
                #expect(reference.shapes == ["612x792@90"])
                #expect(reference.texts == ["Secret"])
                #expect(reference.document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Still secret")
            }
        }
        #expect(try editor.serialized().prefix(data.count) == data)
    }

    @Test func pagesMoveBetweenProtectedAndOpenDocuments() throws {
        // From a protected document into an open one.
        var open = PDFEditor(try PDFFile(data: Fixture.handwritten.data))
        try open.insertPages(from: PDFFile(data: Fixture.encrypted.data, password: "sheaf"))
        #expect(try Reference(open.serialized()).texts == ["Hello, Sheaf", "Secret"])

        // From an open document into a protected one, which stays protected.
        var protected = PDFEditor(try PDFFile(data: Fixture.encrypted.data, password: "owner"))
        try protected.insertPages(from: PDFFile(data: Fixture.text3Pages.data), pageIndexes: [1])
        let saved = try protected.serialized()
        #expect(throws: SheafError.passwordRequired) { try PDFFile(data: saved) }
        #expect(try Reference(saved, password: "sheaf").texts.map { $0.prefix(6) } == ["Secret", "Page 2"])
    }
}
