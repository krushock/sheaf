import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import SheafKit
import Testing
import UniformTypeIdentifiers

@Suite struct CompressionTests {
    // MARK: Test pictures

    /// A picture file. `photo` has smooth color with grain, like a camera's; otherwise it is
    /// a few flat colors with hard edges, like a chart.
    static func picture(width: Int, height: Int, photo: Bool, type: UTType, colorSpace: CFString = CGColorSpace.sRGB, quality: Double = 1) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if photo {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let grain = Int(seed >> 24) % 24
                    bytes[offset] = UInt8(min(255, x * 200 / width + grain))
                    bytes[offset + 1] = UInt8(min(255, y * 200 / height + grain))
                    bytes[offset + 2] = UInt8(min(255, (x + y) * 100 / (width + height) + 80 + grain))
                } else {
                    let band = (x * 6 / width + y * 4 / height) % 3
                    bytes[offset] = band == 0 ? 220 : 30
                    bytes[offset + 1] = band == 1 ? 200 : 60
                    bytes[offset + 2] = band == 2 ? 240 : 90
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: colorSpace)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A document showing one picture on a 300 by 200 point page.
    private func document(with picture: Data) throws -> PDFEditor {
        var editor = PDFEditor.empty()
        try editor.insertImagePage(picture, options: ImageDocumentOptions(paper: .fixed(PageSize(width: 300, height: 200))))
        return PDFEditor(try PDFFile(data: editor.rewritten()))
    }

    private func image(in data: Data) throws -> PDFStream {
        let file = try PDFFile(data: data)
        let resources = try file.value("Resources", in: file.object(try file.pageIDs()[0]).dictionaryValue ?? [:]).dictionaryValue
        let stream = try file.resolve(resources?["XObject"]?.dictionaryValue?["Im0"] ?? .null).streamValue
        return try #require(stream)
    }

    /// The average difference between two renderings, from 0 to 255.
    private func difference(_ a: Data, _ b: Data, scale: Double = 2) throws -> Double {
        func render(_ data: Data) throws -> [UInt8] {
            let page = try #require(PDFDocument(data: data)?.page(at: 0))
            let box = page.bounds(for: .cropBox)
            let width = Int(box.width * scale), height = Int(box.height * scale)
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }
        let first = try render(a), second = try render(b)
        #expect(first.count == second.count)
        var total = 0
        for index in 0..<min(first.count, second.count) { total += abs(Int(first[index]) - Int(second[index])) }
        return Double(total) / Double(max(first.count, 1))
    }

    // MARK: Packing

    @Test(arguments: [Fixture.text3Pages, .image1Page, .handwritten, .outlineAnnotations])
    func packedFilesReadTheSameAndAreSmaller(fixture: Fixture) throws {
        let data = try fixture.data
        let editor = PDFEditor(try PDFFile(data: data))
        let plain = try editor.rewritten()
        let packed = try editor.rewritten(options: WriteOptions(packsObjects: true, mergesDuplicates: true))
        #expect(packed.count < plain.count)

        let file = try PDFFile(data: packed)
        #expect(!file.wasRepaired)
        #expect(file.crossReference.newestSectionIsStream)
        #expect(try file.outline().map(\.title) == (try PDFFile(data: data).outline().map(\.title)))
        let before = try Reference(data), after = try Reference(packed)
        #expect(after.texts == before.texts)
        #expect(after.shapes == before.shapes)
        for index in 0..<before.pageCount { #expect(after.pixels(ofPage: index) == before.pixels(ofPage: index)) }
        // Packed files can be edited and saved by appending, and packed again.
        var again = PDFEditor(file)
        try again.rotatePage(at: 0, by: 90)
        let appended = try again.serialized()
        #expect(appended.prefix(packed.count) == packed)
        #expect(try Reference(appended).document.page(at: 0)?.rotation == ((before.document.page(at: 0)?.rotation ?? 0) + 90) % 360)
        #expect(try Reference(again.rewritten(options: WriteOptions(packsObjects: true))).texts == before.texts)
    }

    @Test(arguments: [EncryptionAlgorithm.rc4(bits: 128), .aes128, .aes256])
    func packedFilesCanBeEncrypted(algorithm: EncryptionAlgorithm) throws {
        let data = try Fixture.outlineAnnotations.data
        let before = try Reference(data)
        let packed = try PDFEditor(PDFFile(data: data)).rewritten(
            protection: .password(user: "пароль", owner: "owner", algorithm: algorithm), options: WriteOptions(packsObjects: true)
        )
        #expect(throws: SheafError.passwordRequired) { try PDFFile(data: packed) }
        let file = try PDFFile(data: packed, password: "пароль")
        #expect(try file.outline().map(\.title) == ["Introduction", "Getting Started", "Editing Text", "Working with Pages"])
        let after = try Reference(packed, password: "пароль")
        #expect(after.texts == before.texts)
        #expect(after.document.outlineRoot?.child(at: 0)?.label == "Introduction")
        // And an already protected, packed file can be packed again keeping its passwords.
        let again = try PDFEditor(file).rewritten(options: WriteOptions(packsObjects: true))
        #expect(try Reference(again, password: "owner").texts == before.texts)
    }

    @Test func packingKeepsTheVersionOfOldFiles() throws {
        var data = try Fixture.handwritten.data
        data.replaceSubrange(0..<8, with: Data("%PDF-1.3".utf8))
        let old = try PDFFile(data: PDFEditor(PDFFile(data: data)).rewritten(options: WriteOptions(packsObjects: true)))
        #expect(old.version.minor == 3 && old.crossReference.newestSectionIsStream)
        data.replaceSubrange(0..<8, with: Data("%PDF-1.4".utf8))
        let newer = try PDFFile(data: PDFEditor(PDFFile(data: data)).rewritten(options: WriteOptions(packsObjects: true)))
        #expect(newer.version.minor == 5)
    }

    @Test func identicalStreamsAreStoredOnce() throws {
        let picture = try Self.picture(width: 200, height: 150, photo: true, type: .jpeg)
        var editor = PDFEditor.empty()
        for _ in 0..<4 { try editor.insertImagePage(picture) }
        let separate = try editor.rewritten()
        let merged = try editor.rewritten(options: WriteOptions(mergesDuplicates: true))
        #expect(separate.count > picture.count * 4)
        #expect(merged.count < picture.count + 3000)
        let reference = try Reference(merged)
        #expect(reference.pageCount == 4)
        #expect(reference.pixels(ofPage: 3) == (try Reference(separate).pixels(ofPage: 3)))
    }

    // MARK: Pictures

    @Test func photographsAreScaledToTheResolutionAskedFor() throws {
        // 1200 pixels across 300 points is 288 per inch.
        let editor = try document(with: Self.picture(width: 1200, height: 800, photo: true, type: .png))
        let original = try editor.rewritten()
        #expect(try image(in: original).dictionary["Filter"]?.nameValue == "FlateDecode")

        let balanced = try editor.compressed(.balanced)
        let picture = try image(in: balanced)
        #expect(picture.dictionary["Filter"]?.nameValue == "DCTDecode")
        #expect(picture.dictionary["Width"]?.intValue == 625 && picture.dictionary["Height"]?.intValue == 417)
        #expect(balanced.count < original.count / 5)
        #expect(try difference(original, balanced) < 6)

        let smallest = try editor.compressed(.smallest)
        #expect(try image(in: smallest).dictionary["Width"]?.intValue == 400)
        #expect(smallest.count < balanced.count)
        #expect(try difference(original, smallest) < 10)

        // Without picture options nothing about the picture changes.
        let lossless = try editor.compressed(.lossless)
        #expect(try image(in: lossless).data == (try image(in: original).data))
        #expect(lossless.count < original.count + 200)
        #expect(try difference(original, lossless) == 0)
    }

    @Test func drawingsStayExact() throws {
        let editor = try document(with: Self.picture(width: 1200, height: 800, photo: false, type: .png))
        let original = try editor.rewritten()
        let compressed = try editor.compressed(.balanced)
        let picture = try image(in: compressed)
        #expect(picture.dictionary["Filter"]?.nameValue == "FlateDecode")
        #expect(picture.dictionary["Width"]?.intValue == 625)
        // Only the edges between colors differ, from scaling.
        #expect(try difference(original, compressed) < 1.5)

        // At or under the limit it is not touched at all.
        let small = try document(with: Self.picture(width: 500, height: 333, photo: false, type: .png))
        #expect(try image(in: small.compressed(.balanced)).data == (try image(in: small.rewritten()).data))
    }

    @Test func jpegPicturesAreRecompressedOnlyWhenItPays() throws {
        let fine = try document(with: Self.picture(width: 600, height: 400, photo: true, type: .jpeg, quality: 1))
        let original = try fine.rewritten()
        let compressed = try fine.compressed(.balanced)
        // 144 per inch is under the limit, so the size stays; the quality comes down.
        #expect(try image(in: compressed).dictionary["Width"]?.intValue == 600)
        #expect(try image(in: compressed).data.count < (try image(in: original).data.count) / 2)
        #expect(try difference(original, compressed) < 6)

        // A picture already compressed that hard is left alone rather than degraded again.
        let coarse = try document(with: Self.picture(width: 600, height: 400, photo: true, type: .jpeg, quality: 0.3))
        #expect(try image(in: coarse.compressed(.balanced)).data == (try image(in: coarse.rewritten()).data))
    }

    @Test func colorProfilesStayWithRecompressedPictures() throws {
        let editor = try document(with: Self.picture(width: 1200, height: 800, photo: true, type: .jpeg, colorSpace: CGColorSpace.displayP3))
        let original = try editor.rewritten()
        let compressed = try editor.compressed(.balanced)
        let file = try PDFFile(data: compressed)
        let picture = try image(in: compressed)
        #expect(picture.dictionary["Width"]?.intValue == 625)
        #expect(try file.resolve(picture.dictionary["ColorSpace"] ?? .null).arrayValue?.first?.nameValue == "ICCBased")
        // The picture's own copy of the profile is gone; the document's copy still applies.
        #expect(picture.data.range(of: Data("ICC_PROFILE".utf8)) == nil)
        #expect(try difference(original, compressed) < 6)
    }

    @Test func picturesInsideFormsAndStampsAreFound() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        var stamp = Annotation(kind: .stamp, rect: PDFRectangle(x: 100, y: 100, width: 200, height: 100))
        let pixels = try StampImage(encodedImageData: Self.picture(width: 1600, height: 800, photo: true, type: .png))
        stamp.stamp = .image(pixels)
        try editor.addAnnotation(stamp, toPageAt: 0)
        let usages = try editor.imageUsages()
        #expect(usages.count == 1)
        #expect(usages.values.first == PageSize(width: 200, height: 100))

        // Flattened, the same picture sits in a form on the page.
        try editor.flattenAnnotations(onPageAt: 0)
        let flattened = try editor.imageUsages()
        #expect(flattened.values.map { [$0.width.rounded(), $0.height.rounded()] } == [[200, 100]])
        let original = try editor.rewritten(), compressed = try editor.compressed(.balanced)
        #expect(compressed.count < original.count / 4)
        #expect(try difference(original, compressed) < 3)
    }

    // MARK: Everything else

    @Test func extrasAreRemovedAndPlainDataCompressed() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.nestedTree()))
        let page = try editor.pageIDs()[0]
        let filler = Data(repeating: 0x41, count: 20_000)
        let thumbnail = editor.add(.stream(PDFStream(dictionary: ["Width": 10, "Height": 10], data: filler)))
        let workingData = editor.add(.stream(PDFStream(data: filler + filler)))
        try editor.update(page) { dictionary in
            dictionary["Thumb"] = .reference(thumbnail)
            dictionary["PieceInfo"] = ["Illustrator": ["Private": .reference(workingData)]]
        }
        let original = try editor.rewritten()
        #expect(original.count > 60_000)

        let compressed = try editor.compressed(.lossless)
        #expect(compressed.count < 2500)
        let file = try PDFFile(data: compressed)
        let dictionary = try #require(file.object(try file.pageIDs()[0]).dictionaryValue)
        #expect(dictionary["Thumb"] == nil && dictionary["PieceInfo"] == nil)
        #expect(try Reference(compressed).texts == (try Reference(original).texts))
        #expect(try Reference(compressed).shapes == (try Reference(original).shapes))

        // Keeping the extras still compresses them.
        let kept = try editor.compressed(CompressionOptions(removesExtras: false))
        let keptFile = try PDFFile(data: kept)
        #expect(try keptFile.object(try keptFile.pageIDs()[0]).dictionaryValue?["Thumb"] != nil)
        #expect(kept.count < 4000)
    }

    @Test func progressIsReportedAndCanStopTheWork() throws {
        let editor = try document(with: Self.picture(width: 800, height: 600, photo: true, type: .png))
        var steps: [Double] = []
        _ = try editor.compressed(.balanced) { value in
            steps.append(value)
            return true
        }
        #expect(steps.first == 0 && steps.last == 1 && steps == steps.sorted())
        #expect(throws: CancellationError.self) { try editor.compressed(.balanced) { $0 < 0.5 } }
    }

    @Test func protectionIsKeptOrChanged() throws {
        let data = try Fixture.encrypted.data
        let editor = PDFEditor(try PDFFile(data: data, password: "sheaf"))
        let kept = try editor.compressed(.balanced)
        #expect(throws: SheafError.passwordRequired) { try PDFFile(data: kept) }
        #expect(try Reference(kept, password: "sheaf").texts == (try Reference(data, password: "sheaf").texts))
        let opened = try editor.compressed(.balanced, protection: .none)
        #expect(try !PDFFile(data: opened).isEncrypted)
    }
}
