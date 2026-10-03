import Foundation
@testable import SheafKit
import Testing

@Suite struct FilterTests {
    private func decode(_ data: Data, _ dictionary: PDFDictionary) throws -> Data {
        try StreamFilters.decode(PDFStream(dictionary: dictionary, data: data))
    }

    @Test func flateRoundTrips() throws {
        let original = Data((0..<20000).map { UInt8(truncatingIfNeeded: $0 * 7 % 251) })
        let packed = Flate.deflate(original)
        #expect(packed.count < original.count)
        #expect(try decode(packed, ["Filter": .name("FlateDecode")]) == original)
        #expect(try decode(Flate.deflate(Data()), ["Filter": .name("FlateDecode")]) == Data())
    }

    @Test func truncatedFlateGivesWhatItCan() throws {
        let original = Data(repeating: 0x41, count: 5000) + Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        let packed = Flate.deflate(original)
        let partial = try decode(packed.prefix(packed.count - 6), ["Filter": .name("FlateDecode")])
        #expect(!partial.isEmpty)
        #expect(original.starts(with: partial))
    }

    @Test func asciiHex() throws {
        #expect(try decode(Data("48 65 6C6c 6F>".utf8), ["Filter": .name("ASCIIHexDecode")]) == Data("Hello".utf8))
        #expect(try decode(Data("7>".utf8), ["Filter": .name("AHx")]) == Data([0x70]))
    }

    @Test func ascii85() throws {
        #expect(try decode(Data("87cURD]i,\"Ebo80~>".utf8), ["Filter": .name("ASCII85Decode")]) == Data("Hello World!".utf8))
        #expect(try decode(Data("z~>".utf8), ["Filter": .name("A85")]) == Data([0, 0, 0, 0]))
        #expect(try decode(Data("87cUR\nDZ~>".utf8), ["Filter": .name("ASCII85Decode")]) == Data("Hello".utf8))
    }

    @Test func runLength() throws {
        let packed = Data([2, 0x41, 0x42, 0x43, 254, 0x5A, 128, 0x99])
        #expect(try decode(packed, ["Filter": .name("RunLengthDecode")]) == Data("ABCZZZ".utf8))
    }

    @Test func lzw() throws {
        // The worked example from the PDF specification.
        let packed = Data([0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01])
        #expect(try decode(packed, ["Filter": .name("LZWDecode")]) == Data([45, 45, 45, 45, 45, 65, 45, 45, 45, 66]))
    }

    @Test func filtersApplyInOrder() throws {
        let original = Data("chained filters".utf8)
        let hex = Data(Flate.deflate(original).map { String(format: "%02X", $0) }.joined().utf8)
        #expect(try decode(hex, ["Filter": [.name("ASCIIHexDecode"), .name("FlateDecode")]]) == original)
    }

    @Test func pngPredictorsUndoEachRowFilter() throws {
        // Three columns of one byte; rows use None, Sub, Up, Average and Paeth.
        let rows: [[UInt8]] = [[10, 20, 30], [11, 22, 33], [5, 6, 7], [100, 50, 25], [9, 8, 7]]
        var encoded: [UInt8] = []
        var previous: [UInt8] = [0, 0, 0]
        for (index, row) in rows.enumerated() {
            encoded.append(UInt8(index))
            for column in 0..<3 {
                let left = column > 0 ? Int(row[column - 1]) : 0
                let up = Int(previous[column])
                let upLeft = column > 0 ? Int(previous[column - 1]) : 0
                let prediction: Int
                switch index {
                case 1: prediction = left
                case 2: prediction = up
                case 3: prediction = (left + up) / 2
                case 4:
                    let estimate = left + up - upLeft
                    let (dl, du, dul) = (abs(estimate - left), abs(estimate - up), abs(estimate - upLeft))
                    prediction = dl <= du && dl <= dul ? left : du <= dul ? up : upLeft
                default: prediction = 0
                }
                encoded.append(row[column] &- UInt8(prediction))
            }
            previous = row
        }
        let dictionary: PDFDictionary = ["Filter": .name("FlateDecode"), "DecodeParms": ["Predictor": 12, "Columns": 3]]
        #expect(try decode(Flate.deflate(Data(encoded)), dictionary) == Data(rows.flatMap { $0 }))
    }

    @Test func tiffPredictor() throws {
        let dictionary: PDFDictionary = ["Filter": .name("FlateDecode"), "DecodeParms": ["Predictor": 2, "Columns": 4]]
        #expect(try decode(Flate.deflate(Data([1, 1, 1, 1, 10, 0, 255, 2])), dictionary) == Data([1, 2, 3, 4, 10, 10, 9, 11]))
    }

    @Test func imageFiltersAreReportedNotGuessed() {
        #expect(throws: SheafError.unsupported("stream filter DCTDecode")) {
            try decode(Data([1, 2, 3]), ["Filter": .name("DCTDecode")])
        }
    }
}
