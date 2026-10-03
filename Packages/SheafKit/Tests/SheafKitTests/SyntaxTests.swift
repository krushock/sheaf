import Foundation
@testable import SheafKit
import Testing

@Suite struct SyntaxTests {
    private func parse(_ text: String) throws -> PDFObject {
        try Data(text.utf8).parse { try $0.parseObject() }
    }

    @Test func parsesScalars() throws {
        #expect(try parse("null") == .null)
        #expect(try parse("true") == true)
        #expect(try parse("false") == false)
        #expect(try parse("42") == 42)
        #expect(try parse("-17") == -17)
        #expect(try parse("+3") == 3)
        #expect(try parse("3.5") == 3.5)
        #expect(try parse("-.25") == -0.25)
        #expect(try parse("4.") == 4.0)
        #expect(try parse("% a comment\n 7") == 7)
    }

    @Test func parsesNames() throws {
        #expect(try parse("/Type") == .name("Type"))
        #expect(try parse("/A#20B") == .name("A B"))
        #expect(try parse("/") == .name(""))
        #expect(try parse("/Name1/Name2") == .name("Name1"))
        #expect(try parse("/caf#C3#A9").nameValue?.text == "café")
        #expect(try parse("/caf#E9").nameValue?.bytes == [0x63, 0x61, 0x66, 0xE9])
    }

    @Test func parsesStrings() throws {
        #expect(try parse("(hello)") == .string(Data("hello".utf8)))
        #expect(try parse("(a (nested) b)") == .string(Data("a (nested) b".utf8)))
        #expect(try parse(#"(line\nbreak \( \) \\ \101\60)"#) == .string(Data("line\nbreak ( ) \\ A0".utf8)))
        #expect(try parse("(split\\\nline)") == .string(Data("splitline".utf8)))
        #expect(try parse("(a\r\nb)") == .string(Data("a\nb".utf8)))
        #expect(try parse("<48656C6C6F>") == .string(Data("Hello".utf8)))
        #expect(try parse("<48 65 6c 6C 6>") == .string(Data([0x48, 0x65, 0x6C, 0x6C, 0x60])))
        #expect(try parse("()") == .string(Data()))
    }

    @Test func parsesContainersAndReferences() throws {
        #expect(try parse("[1 2.5 /N (s) [true] null]") == [1, 2.5, .name("N"), .string(Data("s".utf8)), [true], nil])
        #expect(try parse("<< /A 1 /B [2 3] /C << /D /E >> >>") == ["A": 1, "B": [2, 3], "C": ["D": .name("E")]])
        #expect(try parse("12 0 R") == .reference(ObjectID(12, 0)))
        #expect(try parse("[1 0 R 2 3 4 5 R]") == [.reference(ObjectID(1)), 2, 3, .reference(ObjectID(4, 5))])
        #expect(try parse("<</Kids[3 0 R]/Count 1>>") == ["Kids": [.reference(ObjectID(3))], "Count": 1])
        // A null value means the key is absent.
        #expect(try parse("<< /A null /B 1 >>") == ["B": 1])
    }

    @Test func toleratesCommonDamage() throws {
        // An object number too large to exist: the reference points at nothing.
        #expect(try parse("<< /Pg 18446744073386459286 0 R /K 1 >>") == ["K": 1])
        #expect(try parse("[99999999999999999999 0 R 5]") == [nil, 5])
        // A stray token between entries.
        #expect(try parse("<< /A 1 R /B 2 >>") == ["A": 1, "B": 2])
        #expect(try parse("<< /A 1 7 /B 2 >>") == ["A": 1, "B": 2])
        #expect(try parse("1.2.3") == 1.2)
        #expect(try parse("--5") == 0)
    }

    @Test func referencesAreOffInContentStreams() throws {
        let value = try Data("1 0 R".utf8).parse { parser -> PDFObject in
            parser.allowsReferences = false
            return try parser.parseObject()
        }
        #expect(value == 1)
    }

    @Test(arguments: ["[1 2", "<< /A 1", "<< /A [ >>", "endobj", ""])
    func rejectsBrokenInput(text: String) {
        #expect(throws: SheafError.self) { try parse(text) }
    }

    @Test func deepNestingIsRefused() {
        let text = String(repeating: "[", count: 5000)
        #expect(throws: SheafError.self) { try parse(text) }
    }

    @Test func parsesIndirectObjectsAndStreams() throws {
        let simple = try Data("7 0 obj\n<< /A 1 >>\nendobj".utf8).parse { try $0.parseIndirectObject(resolveLength: { _ in nil }) }
        #expect(simple.id == ObjectID(7))
        #expect(simple.object == ["A": 1])

        let text = "4 2 obj\n<< /Length 5 >>\nstream\r\nHello\nendstream\nendobj\n"
        let stream = try Data(text.utf8).parse { try $0.parseIndirectObject(resolveLength: { _ in nil }) }
        #expect(stream.id == ObjectID(4, 2))
        #expect(stream.object.streamValue?.data == Data("Hello".utf8))
    }

    @Test func streamLengthCanBeAReference() throws {
        let text = "4 0 obj << /Length 9 0 R >> stream\nabcdef\nendstream endobj"
        let stream = try Data(text.utf8).parse { try $0.parseIndirectObject(resolveLength: { $0 == ObjectID(9) ? 6 : nil }) }
        #expect(stream.object.streamValue?.data == Data("abcdef".utf8))
    }

    @Test(arguments: ["<< /Length 99 >>", "<< >>", "<< /Length 2 >>"])
    func wrongStreamLengthFallsBackToTheKeyword(dictionary: String) throws {
        let text = "4 0 obj \(dictionary) stream\nabcdef\r\nendstream endobj"
        let stream = try Data(text.utf8).parse { try $0.parseIndirectObject(resolveLength: { _ in nil }) }
        #expect(stream.object.streamValue?.data == Data("abcdef".utf8))
    }

    @Test func serializesEveryKindOfObject() {
        func text(_ object: PDFObject) -> String { String(decoding: Serializer.data(object), as: UTF8.self) }
        #expect(text(nil) == "null")
        #expect(text(true) == "true")
        #expect(text(-12) == "-12")
        #expect(text(2.5) == "2.5")
        #expect(text(3.0) == "3")
        #expect(text(.real(0.000001)) == "0.000001")
        #expect(text(.real(1e-12)) == "0")
        #expect(text(.real(-123456.75)) == "-123456.75")
        #expect(text(.name("A B#/")) == "/A#20B#23#2F")
        #expect(text(.string(Data("a(b)c\\".utf8))) == #"(a\(b\)c\\)"#)
        #expect(text(.string(Data([0x00, 0xFF]))) == "<00FF>")
        #expect(text([1, [2], .name("N")]) == "[1 [2] /N]")
        #expect(text(["B": 2, "A": .reference(ObjectID(5, 1))]) == "<< /A 5 1 R /B 2 >>")
        #expect(text(.stream(PDFStream(dictionary: ["Length": 0, "K": 1], data: Data("xyz".utf8))))
            == "<< /K 1 /Length 3 >>\nstream\nxyz\nendstream")
    }

    @Test func serializedObjectsParseBackToThemselves() throws {
        let object: PDFObject = [
            "Name": .name("With Space"), "Bytes": .string(Data((0...255).map { UInt8($0) })),
            "Text": .string(Data("plain (text) \\ here".utf8)), "Numbers": [0, -1, 2.25, 1_000_000_000_000],
            "Ref": .reference(ObjectID(99, 3)), "Nested": ["Deep": [["X": true]]],
        ]
        let parsed = try Serializer.data(object).parse { try $0.parseObject() }
        #expect(parsed == object)
    }

    @Test func textStringsUseTheRightEncoding() {
        #expect(PDFText.decode(Data("Plain".utf8)) == "Plain")
        #expect(PDFText.decode(Data([0xFE, 0xFF, 0x04, 0x1F, 0x00, 0x41])) == "ПA")
        #expect(PDFText.decode(Data([0xEF, 0xBB, 0xBF]) + Data("é".utf8)) == "é")
        #expect(PDFText.decode(Data([0x80, 0xE9, 0xA0])) == "•é€")
        #expect(PDFText.encode("Plain") == Data("Plain".utf8))
        #expect(PDFText.decode(PDFText.encode("Привет 🙂")) == "Привет 🙂")
    }

    @Test func datesRoundTrip() throws {
        let date = try #require(PDFDate.decode("D:20261003142500+02'00'"))
        #expect(PDFDate.encode(date) == "D:20261003122500Z")
        #expect(PDFDate.decode("D:2026") != nil)
        #expect(PDFDate.decode("20261003") == PDFDate.decode("D:20261003000000Z"))
        #expect(PDFDate.decode("nonsense") == nil)
    }
}
