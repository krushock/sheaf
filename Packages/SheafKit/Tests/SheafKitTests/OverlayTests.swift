import Foundation
import PDFKit
@testable import SheafKit
import Testing

@Suite struct OverlayTests {
    /// A page drawn at one pixel per point, with a way to ask about parts of it.
    struct Picture {
        let pixels: Data
        let width: Int, height: Int

        init(_ reference: Reference, page: Int) throws {
            let pdfPage = try #require(reference.document.page(at: page))
            let box = pdfPage.bounds(for: .cropBox)
            let sideways = pdfPage.rotation % 180 != 0
            width = Int(sideways ? box.height : box.width)
            height = Int(sideways ? box.width : box.height)
            pixels = try #require(reference.pixels(ofPage: page, fullSize: true))
        }

        /// The share of pixels passing a test, in a region given in fractions of the page
        /// measured from its top left corner.
        func share(x: ClosedRange<Double> = 0...1, y: ClosedRange<Double> = 0...1, where test: (UInt8, UInt8, UInt8) -> Bool) -> Double {
            var matching = 0, total = 0
            for row in Int(y.lowerBound * Double(height))..<Int(y.upperBound * Double(height)) {
                for column in Int(x.lowerBound * Double(width))..<Int(x.upperBound * Double(width)) {
                    let offset = (row * width + column) * 4
                    total += 1
                    if test(pixels[offset], pixels[offset + 1], pixels[offset + 2]) { matching += 1 }
                }
            }
            return total == 0 ? 0 : Double(matching) / Double(total)
        }

        static func isRed(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g < 80 && b < 80 }
        static func isDark(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { Int(r) + Int(g) + Int(b) < 384 }
    }

    private static let redSquare = StampImage(width: 4, height: 4, rgb: Data(repeating: 0, count: 48).enumerated().reduce(into: Data()) { data, entry in
        data.append(entry.offset % 3 == 0 ? 255 : 0)
    }, alpha: nil)

    private func blankPage(width: Double = 400, height: Double = 200, rotation: Int = 0, content: String? = nil) throws -> PDFEditor {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 30, y: 40, width: width, height: height)])))
        try editor.rotatePage(at: 0, by: rotation)
        if let content {
            let stream = editor.add(.stream(PDFStream(data: Data(content.utf8))))
            try editor.update(try editor.pageIDs()[0]) { $0["Contents"] = .reference(stream) }
        }
        return editor
    }

    // MARK: Watermark

    /// A picture placed in the top left corner must be in the top left corner as shown,
    /// whichever way the page is turned.
    @Test(arguments: [0, 90, 180, 270])
    func watermarkPositionFollowsThePageAsDisplayed(rotation: Int) throws {
        var editor = try blankPage(rotation: rotation)
        var watermark = Watermark(content: .image(Self.redSquare))
        watermark.imageScale = 0.25
        watermark.opacity = 1
        watermark.rotation = 0
        watermark.margin = 0
        watermark.position = .topLeft
        try editor.addWatermark(watermark)

        let picture = try Picture(Reference(editor.serialized()), page: 0)
        let side = 0.25 * Double(picture.width) / Double(picture.height)
        #expect(picture.share(x: 0.01...0.24, y: 0.01...(side - 0.01), where: Picture.isRed) > 0.98)
        #expect(picture.share(x: 0.27...1, where: Picture.isRed) == 0)
        #expect(picture.share(y: (side + 0.02)...1, where: Picture.isRed) == 0)
    }

    @Test func watermarkGoesOverOrUnderThePage() throws {
        // A page painted white all over hides whatever is under it.
        for behind in [false, true] {
            var editor = try blankPage(content: "1 g 0 0 1000 1000 re f 3 0 0 3 0 0 cm")
            var watermark = Watermark(content: .image(Self.redSquare))
            watermark.opacity = 1
            watermark.rotation = 0
            watermark.isBehindContent = behind
            try editor.addWatermark(watermark)
            let red = try Picture(Reference(editor.serialized()), page: 0).share(where: Picture.isRed)
            // The stray scaling the page leaves behind must not reach the watermark either.
            #expect(behind ? red == 0 : red > 0.45 && red < 0.55, "behind=\(behind) red=\(red)")
        }
    }

    @Test func textWatermarkIsStoredOnceAndLeavesTextAlone() throws {
        let data = try Fixture.text3Pages.data
        let before = try Reference(data)
        var editor = PDFEditor(try PDFFile(data: data))
        var watermark = Watermark(content: .text("Черновик\nDRAFT"))
        watermark.color = .red
        watermark.opacity = 0.5
        try editor.addWatermark(watermark)
        // One form, its three per-page drawings, the two fences, and the three pages.
        #expect(editor.changedNumbers.count == 9)

        let saved = try editor.serialized()
        #expect(saved.prefix(data.count) == data)
        let after = try Reference(saved)
        #expect(after.texts == before.texts)
        for index in 0..<3 {
            let reddish = try Picture(after, page: index).share(x: 0.2...0.8, y: 0.25...0.75) { r, g, b in r > 200 && g < 200 && b < 200 }
            #expect(reddish > 0.03, "page \(index + 1) shows no watermark")
            #expect(try Picture(before, page: index).share { r, g, b in r > 200 && g < 200 && b < 200 } == 0)
        }
        // Only some pages, and a second mark on a page that already has one.
        var again = PDFEditor(try PDFFile(data: saved))
        watermark.isTiled = true
        try again.addWatermark(watermark, toPagesAt: [1])
        let tiled = try Reference(again.serialized())
        #expect(tiled.pixels(ofPage: 0) == after.pixels(ofPage: 0))
        #expect(tiled.pixels(ofPage: 1) != after.pixels(ofPage: 1))
        #expect(throws: SheafError.pageOutOfRange(7)) { try again.addWatermark(watermark, toPagesAt: [7]) }
    }

    @Test func tiledWatermarkCoversThePage() throws {
        var editor = try blankPage(width: 600, height: 800)
        var watermark = Watermark(content: .text("COPY"))
        watermark.fontSize = 30
        watermark.opacity = 1
        watermark.color = .black
        watermark.isTiled = true
        try editor.addWatermark(watermark)
        let picture = try Picture(Reference(editor.serialized()), page: 0)
        for (x, y) in [(0.0...0.5, 0.0...0.5), (0.5...1.0, 0.0...0.5), (0.0...0.5, 0.5...1.0), (0.5...1.0, 0.5...1.0)] {
            #expect(picture.share(x: x, y: y, where: Picture.isDark) > 0.02)
        }
    }

    // MARK: Header and footer

    @Test(arguments: [0, 90])
    func headerAndFooterSitInTheirCorners(rotation: Int) throws {
        var editor = try blankPage(width: 600, height: 400, rotation: rotation)
        var spec = HeaderFooter()
        spec.header.left = "{name}"
        spec.footer.right = "Page {page} of {pages}"
        spec.fontSize = 14
        try editor.addHeaderFooter(spec, documentName: "Квартальный отчёт")
        let picture = try Picture(Reference(editor.serialized()), page: 0)
        #expect(picture.share(x: 0...0.5, y: 0...0.25, where: Picture.isDark) > 0.005)
        #expect(picture.share(x: 0.5...1, y: 0.75...1, where: Picture.isDark) > 0.005)
        #expect(picture.share(x: 0.5...1, y: 0...0.25, where: Picture.isDark) == 0)
        #expect(picture.share(x: 0...0.5, y: 0.75...1, where: Picture.isDark) == 0)
        #expect(picture.share(y: 0.25...0.75, where: Picture.isDark) == 0)
    }

    @Test func pageNumbersCountFromTheChosenNumber() throws {
        // Each page's footer is its own drawing: different numbers give different pictures,
        // and the same number gives the same one.
        func footers(first: Int, pages: [Int]? = nil) throws -> [Data?] {
            var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: Array(repeating: PDFRectangle(x: 0, y: 0, width: 300, height: 200), count: 3))))
            var spec = HeaderFooter()
            spec.footer.center = HeaderFooter.pageToken
            spec.firstNumber = first
            try editor.addHeaderFooter(spec, toPagesAt: pages)
            let reference = try Reference(editor.serialized())
            return (0..<3).map { reference.pixels(ofPage: $0, fullSize: true) }
        }
        let fromOne = try footers(first: 1), fromTwo = try footers(first: 2)
        #expect(fromOne[1] == fromTwo[0] && fromOne[2] == fromTwo[1])
        #expect(fromOne[0] != fromOne[1] && fromOne[1] != fromOne[2])
        let onlyLast = try footers(first: 1, pages: [2])
        #expect(onlyLast[0] == onlyLast[1] && onlyLast[2] == fromOne[2])
    }

    @Test func anEmptyHeaderAndFooterChangeNothing() throws {
        var editor = PDFEditor(try PDFFile(data: Fixture.text3Pages.data))
        try editor.addHeaderFooter(HeaderFooter())
        try editor.addWatermark(Watermark(content: .text("")))
        #expect(!editor.hasChanges)
    }
}
