#!/usr/bin/env swift
// Regenerates the PDFs in Tests/SheafKitTests/Fixtures.
// Run from the package root: swift Scripts/make-fixtures.swift
//
// Core Graphics stamps a creation date and file ID, so regenerated files differ in bytes
// from the committed ones. Tests assert on structure, never on bytes.

import CoreGraphics
import CoreText
import Foundation
import PDFKit

let outputDirectory = URL(fileURLWithPath: "Tests/SheafKitTests/Fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func write(_ name: String, auxiliary: [CFString: Any] = [:], pages: [(CGSize, (CGContext) -> Void)]) throws {
    let data = NSMutableData()
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: nil, auxiliary as CFDictionary)!
    for (size, draw) in pages {
        var box = CGRect(origin: .zero, size: size)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        draw(context)
        context.endPDFPage()
    }
    context.closePDF()
    try (data as Data).write(to: outputDirectory.appendingPathComponent(name))
    print("wrote \(name) (\(data.length) bytes)")
}

func drawText(_ string: String, font name: String, size: CGFloat, in rect: CGRect, context: CGContext) {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, context)
}

let letter = CGSize(width: 612, height: 792)
let a4 = CGSize(width: 595, height: 842)
let lorem = """
Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut \
labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco \
laboris nisi ut aliquip ex ea commodo consequat.
"""

// 1. Three Letter pages of embedded-font text, with document metadata.
try write(
    "text-3pages.pdf",
    auxiliary: [kCGPDFContextTitle: "Sheaf Text Fixture", kCGPDFContextAuthor: "SheafKit"],
    pages: (1...3).map { number in
        (letter, { context in
            drawText("Page \(number)", font: "Helvetica-Bold", size: 28, in: CGRect(x: 72, y: 680, width: 468, height: 40), context: context)
            drawText(lorem, font: "Times New Roman", size: 12, in: CGRect(x: 72, y: 420, width: 468, height: 240), context: context)
        })
    }
)

// 2. One A4 page holding a bitmap image and a vector path.
try write("image-1page.pdf", pages: [(a4, { context in
    let bitmap = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for row in 0..<8 {
        for column in 0..<8 {
            bitmap.setFillColor(red: Double(column) / 7, green: Double(row) / 7, blue: 0.6, alpha: 1)
            bitmap.fill(CGRect(x: column * 8, y: row * 8, width: 8, height: 8))
        }
    }
    context.draw(bitmap.makeImage()!, in: CGRect(x: 100, y: 500, width: 256, height: 256))
    context.setStrokeColor(red: 0, green: 0.3, blue: 0.8, alpha: 1)
    context.setLineWidth(3)
    context.strokeEllipse(in: CGRect(x: 100, y: 200, width: 200, height: 120))
})])

// 3. Encrypted: user password "sheaf", owner password "owner".
try write(
    "encrypted-user-password.pdf",
    auxiliary: [kCGPDFContextUserPassword: "sheaf", kCGPDFContextOwnerPassword: "owner"],
    pages: [(letter, { context in
        drawText("Secret", font: "Helvetica", size: 24, in: CGRect(x: 72, y: 680, width: 468, height: 40), context: context)
    })]
)

// 4. A hand-assembled PDF 1.4 with a classic cross-reference table, an uncompressed
//    content stream, a base-14 font that is not embedded, and a page rotated 90 degrees.
do {
    var body = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
    var offsets: [Int] = []
    func object(_ number: Int, _ content: String) {
        offsets.append(body.count)
        body.append(Data("\(number) 0 obj\n\(content)\nendobj\n".utf8))
    }
    let stream = "BT /F1 24 Tf 72 700 Td (Hello, Sheaf) Tj ET"
    object(1, "<< /Type /Catalog /Pages 2 0 R >>")
    object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
    object(4, "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
    object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    let xrefOffset = body.count
    var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
    xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
    body.append(Data(xref.utf8))
    try body.write(to: outputDirectory.appendingPathComponent("handwritten-classic-xref.pdf"))
    print("wrote handwritten-classic-xref.pdf (\(body.count) bytes)")
}

// 5. Twelve pages with a nested outline, markup annotations, a note, a link and page
//    labels. Assembled with PDFKit on top of Core Graphics pages.
do {
    let chapters = ["Introduction", "Getting Started", "Editing Text", "Working with Pages"]
    let name = "outline-annotations-12pages.pdf"
    try write(name, auxiliary: [kCGPDFContextTitle: "Sheaf Sample Guide", kCGPDFContextAuthor: "SheafKit"],
              pages: (0..<12).map { index in
        (letter, { context in
            let chapter = chapters[index / 3]
            let heading = index % 3 == 0 ? "Chapter \(index / 3 + 1): \(chapter)" : "\(chapter), continued"
            drawText(heading, font: "Helvetica-Bold", size: 22, in: CGRect(x: 72, y: 690, width: 468, height: 34), context: context)
            drawText("Section \(index / 3 + 1).\(index % 3 + 1)", font: "Helvetica", size: 14, in: CGRect(x: 72, y: 655, width: 468, height: 24), context: context)
            let body = "This is page \(index + 1) of the sample guide. " + lorem + " The quick brown fox jumps over the lazy dog. "
                + (index % 2 == 0 ? "Sheaf keeps every document on your Mac. " : "Pages can be reordered by dragging. ")
            drawText(body + body, font: "Times New Roman", size: 12, in: CGRect(x: 72, y: 330, width: 468, height: 310), context: context)
        })
    })
    let url = outputDirectory.appendingPathComponent(name)
    // PDFKit only saves a new outline for a document it assembled itself, so the pages
    // are copied into a fresh one instead of adding the outline to the loaded file.
    let drawn = PDFDocument(url: url)!
    let document = PDFDocument()
    for index in 0..<drawn.pageCount {
        document.insert(drawn.page(at: index)!.copy() as! PDFPage, at: index)
    }
    document.documentAttributes = drawn.documentAttributes

    let root = PDFOutline()
    document.outlineRoot = root
    for (chapterIndex, chapter) in chapters.enumerated() {
        let item = PDFOutline()
        item.label = chapter
        item.destination = PDFDestination(page: document.page(at: chapterIndex * 3)!, at: CGPoint(x: 0, y: 792))
        for section in 0..<3 {
            let child = PDFOutline()
            child.label = "Section \(chapterIndex + 1).\(section + 1)"
            child.destination = PDFDestination(page: document.page(at: chapterIndex * 3 + section)!, at: CGPoint(x: 0, y: 700))
            item.insertChild(child, at: section)
        }
        root.insertChild(item, at: chapterIndex)
    }

    func markup(_ subtype: PDFAnnotationSubtype, page: Int, bounds: CGRect, color: NSColor) {
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = color
        document.page(at: page)!.addAnnotation(annotation)
    }
    markup(.highlight, page: 0, bounds: CGRect(x: 72, y: 626, width: 300, height: 14), color: .yellow)
    markup(.underline, page: 1, bounds: CGRect(x: 72, y: 612, width: 240, height: 14), color: .red)
    markup(.strikeOut, page: 4, bounds: CGRect(x: 72, y: 598, width: 200, height: 14), color: .red)
    markup(.highlight, page: 7, bounds: CGRect(x: 72, y: 584, width: 360, height: 14), color: .green)

    let note = PDFAnnotation(bounds: CGRect(x: 520, y: 700, width: 24, height: 24), forType: .text, withProperties: nil)
    note.contents = "Check this heading with the editor."
    note.color = .yellow
    document.page(at: 3)!.addAnnotation(note)

    let freeText = PDFAnnotation(bounds: CGRect(x: 320, y: 250, width: 200, height: 40), forType: .freeText, withProperties: nil)
    freeText.contents = "Draft, do not distribute"
    freeText.font = NSFont.systemFont(ofSize: 14)
    freeText.fontColor = .red
    freeText.color = .clear
    document.page(at: 5)!.addAnnotation(freeText)

    let link = PDFAnnotation(bounds: CGRect(x: 72, y: 655, width: 120, height: 20), forType: .link, withProperties: nil)
    link.action = PDFActionURL(url: URL(string: "https://example.com")!)
    document.page(at: 0)!.addAnnotation(link)

    guard document.write(to: url) else { fatalError("could not write \(name)") }
    print("rewrote \(name) with outline and annotations")
}
