import Foundation
import SheafKit
import Testing

@Suite struct InspectorTests {
    @Test func textFixtureHasThreeLetterPages() throws {
        let summary = try PDFInspector.summary(of: Fixture.text3Pages.data)
        #expect(summary.pageCount == 3)
        #expect(summary.pages.allSatisfy { $0.size == .letter && $0.rotation == 0 })
        #expect(!summary.isEncrypted)
        #expect(!summary.isLocked)
        #expect(summary.majorVersion == 1)
    }

    @Test func imageFixtureIsOneA4Page() throws {
        let summary = try PDFInspector.summary(of: Fixture.image1Page.data)
        #expect(summary.pages == [.init(size: .a4, rotation: 0)])
    }

    @Test func outlineFixtureHasTwelveLetterPages() throws {
        let summary = try PDFInspector.summary(of: Fixture.outlineAnnotations.data)
        #expect(summary.pageCount == 12)
        #expect(summary.pages.allSatisfy { $0.size == .letter })
    }

    @Test func handwrittenFixtureReportsVersionAndRotation() throws {
        let summary = try PDFInspector.summary(of: Fixture.handwritten.data)
        #expect(summary.majorVersion == 1)
        #expect(summary.minorVersion == 4)
        #expect(summary.pages == [.init(size: .letter, rotation: 90)])
    }

    @Test func encryptedFixtureIsLockedWithoutPassword() throws {
        let summary = try PDFInspector.summary(of: Fixture.encrypted.data)
        #expect(summary.isEncrypted)
        #expect(summary.isLocked)
        #expect(summary.pageCount == 0)
    }

    @Test(arguments: ["sheaf", "owner"])
    func encryptedFixtureUnlocks(password: String) throws {
        let summary = try PDFInspector.summary(of: Fixture.encrypted.data, password: password)
        #expect(summary.isEncrypted)
        #expect(!summary.isLocked)
        #expect(summary.pageCount == 1)
    }

    @Test func wrongPasswordThrows() throws {
        let data = try Fixture.encrypted.data
        #expect(throws: SheafError.incorrectPassword) {
            try PDFInspector.summary(of: data, password: "nope")
        }
    }

    @Test(arguments: [Data(), Data("not a pdf at all".utf8), Data(repeating: 0xFF, count: 4096)])
    func garbageThrowsNotAPDF(data: Data) {
        #expect(throws: SheafError.notAPDF) {
            try PDFInspector.summary(of: data)
        }
    }
}
