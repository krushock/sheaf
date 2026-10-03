import Foundation
import PDFKit
@testable import SheafKit
import Testing

/// Small PDFs assembled by hand, independent of the engine's own writers.
enum TestPDF {
    /// A two-page document whose objects live in an object stream and whose
    /// cross-reference is a stream: the PDF 1.5 layout.
    ///
    /// Objects: 1 catalog, 2 pages, 3 and 4 page, 5 font and 7 info sit in object stream 6.
    /// Objects 8 and 9 are the content streams, 10 is the cross-reference stream.
    static func compressed(predictor: Bool = true) -> Data {
        var body = Data("%PDF-1.5\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int: Int] = [:]

        let packed: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R >> >> >>"),
            (3, "<< /Type /Page /Parent 2 0 R /Contents 8 0 R >>"),
            (4, "<< /Type /Page /Parent 2 0 R /Contents 9 0 R /Rotate 180 >>"),
            (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            (7, "<< /Title (Packed) /Author (Sheaf Tests) >>"),
        ]
        var header = "", objects = ""
        for (number, text) in packed {
            header += "\(number) \(objects.utf8.count) "
            objects += text + "\n"
        }
        let streamData = Flate.deflate(Data((header + objects).utf8))
        func add(_ number: Int, _ dictionary: String, _ data: Data) {
            offsets[number] = body.count
            body.append(Data("\(number) 0 obj\n<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8))
            body.append(data)
            body.append(Data("\nendstream\nendobj\n".utf8))
        }
        add(6, "/Type /ObjStm /N \(packed.count) /First \(header.utf8.count) /Filter /FlateDecode", streamData)
        add(8, "/Filter /FlateDecode", Flate.deflate(Data("BT /F1 18 Tf 20 100 Td (First page) Tj ET".utf8)))
        add(9, "", Data("BT /F1 18 Tf 20 100 Td (Second page) Tj ET".utf8))

        // Rows of [type, 2-byte field, 1-byte field] for objects 0 through 10.
        let xrefOffset = body.count
        var rows: [[UInt8]] = [[0, 0, 0, 255]]
        for number in 1...10 {
            if let index = packed.firstIndex(where: { $0.0 == number }) {
                rows.append([2, 0, 6, UInt8(index)])
            } else {
                let offset = number == 10 ? xrefOffset : offsets[number]!
                rows.append([1, UInt8(offset >> 8), UInt8(offset & 0xFF), 0])
            }
        }
        var table = Data()
        var parameters = ""
        if predictor {
            // PNG "Up" prediction on every row, as most writers do for these streams.
            var previous: [UInt8] = [0, 0, 0, 0]
            for row in rows {
                table.append(2)
                table.append(contentsOf: zip(row, previous).map { $0 &- $1 })
                previous = row
            }
            parameters = " /DecodeParms << /Predictor 12 /Columns 4 >>"
        } else {
            for row in rows { table.append(contentsOf: row) }
        }
        add(10, "/Type /XRef /Size 11 /W [1 2 1] /Root 1 0 R /Info 7 0 R /Filter /FlateDecode\(parameters)", Flate.deflate(table))
        body.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return body
    }

    /// Four pages in a nested page tree, with attributes set on the intermediate nodes:
    ///
    ///     root ── A (MediaBox 200x100, Rotate 90) ── page 1, page 2
    ///          ├─ B (MediaBox 300x300, Resources) ── page 3
    ///          └─ page 4 (own MediaBox 400x500)
    ///
    /// Each page draws its own number as text.
    static func nestedTree() -> Data {
        var body = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ number: Int, _ content: String) {
            precondition(number == offsets.count + 1)
            offsets.append(body.count)
            body.append(Data("\(number) 0 obj\n\(content)\nendobj\n".utf8))
        }
        func content(_ page: Int) -> String {
            let text = "BT /F1 12 Tf 10 50 Td (Page \(page)) Tj ET"
            return "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        }
        let font = "<< /Font << /F1 12 0 R >> >>"
        object(1, "<< /Type /Catalog /Pages 2 0 R >>")
        object(2, "<< /Type /Pages /Kids [3 0 R 4 0 R 8 0 R] /Count 4 >>")
        object(3, "<< /Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2 /MediaBox [0 0 200 100] /Rotate 90 /Resources \(font) >>")
        object(4, "<< /Type /Pages /Parent 2 0 R /Kids [7 0 R] /Count 1 /MediaBox [0 0 300 300] /Resources \(font) >>")
        object(5, "<< /Type /Page /Parent 3 0 R /Contents 9 0 R >>")
        object(6, "<< /Type /Page /Parent 3 0 R /Contents 10 0 R /Rotate 0 >>")
        object(7, "<< /Type /Page /Parent 4 0 R /Contents 11 0 R >>")
        object(8, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources \(font) /Contents 13 0 R >>")
        object(9, content(1))
        object(10, content(2))
        object(11, content(3))
        object(12, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        object(13, content(4))
        let xrefOffset = body.count
        var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
        xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        body.append(Data(xref.utf8))
        return body
    }
}

extension TestPDF {
    /// A one-page form written by hand, the way careful writers lay one out:
    ///
    ///     person ─ first (text, value "Ada", default "Ada", at most 20 characters)
    ///            └ last  (text, required, right-aligned)
    ///     agree   (checkbox, off; its on state is called "On")
    ///     plan    (radio group: "basic" is on, "pro" is off)
    ///     country (dropdown: pt/Portugal chosen, es/Spain, Other)
    ///     notes   (text, several lines)
    ///     sign    (signature, empty)
    ///     when    (text with a date format, dd/mm/yyyy)
    ///     send    (push button)
    ///
    /// The type and text style of `first` and `last` come from `person`. The form also
    /// carries an XFA copy of itself, as forms made in LiveCycle do.
    static func form() -> Data {
        var body = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        func object(_ number: Int, _ content: String) {
            precondition(number == offsets.count + 1)
            offsets.append(body.count)
            body.append(Data("\(number) 0 obj\n\(content)\nendobj\n".utf8))
        }
        func stream(_ dictionary: String, _ text: String) -> String {
            "<< \(dictionary) /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        }
        let widget = "/Type /Annot /Subtype /Widget /P 3 0 R /F 4"
        let look = "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"
        object(1, "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>")
        object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 6 0 R >> >> /Annots [7 0 R 8 0 R 10 0 R 13 0 R 14 0 R 15 0 R 16 0 R 17 0 R 21 0 R 19 0 R] >>")
        func label(_ text: String, _ x: Int, _ y: Int, size: Int = 10) -> String { "BT /F1 \(size) Tf \(x) \(y) Td (\(text)) Tj ET\n" }
        let labels = label("Registration", 100, 750, size: 16) + label("First name", 100, 724) + label("Last name", 320, 724)
            + label("I agree to the terms", 120, 663) + label("Basic", 118, 623) + label("Pro", 158, 623)
            + label("Country", 100, 604) + label("Date", 320, 604) + label("Notes", 100, 564) + label("Signature", 100, 464)
        object(4, stream("", labels))
        object(5, "<< /Fields [20 0 R 10 0 R 12 0 R 15 0 R 16 0 R 17 0 R 21 0 R 19 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> /XFA 22 0 R >>")
        object(6, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        object(7, "<< \(widget) /Parent 20 0 R /T (first) /TU (First name) /Rect [100 700 300 720] /V (Ada) /DV (Ada) /MaxLen 20 /AP << /N 9 0 R >> >>")
        object(8, "<< \(widget) /Parent 20 0 R /T (last) /Rect [320 700 520 720] /Q 2 /Ff 2 >>")
        object(9, stream("/Type /XObject /Subtype /Form /BBox [0 0 200 20] /Resources << /Font << /Helv 6 0 R >> >>", "/Tx BMC BT /Helv 11 Tf 0 0 1 rg 2 5 Td (Ada) Tj ET EMC"))
        object(10, "<< \(widget) /FT /Btn /T (agree) /V /Off /AS /Off /Rect [100 660 114 674] /AP << /N << /On 11 0 R /Off 18 0 R >> >> >>")
        object(11, stream(look, "0 g 2 2 10 10 re f"))
        object(12, "<< /FT /Btn /Ff 49152 /T (plan) /V /basic /Kids [13 0 R 14 0 R] >>")
        object(13, "<< \(widget) /Parent 12 0 R /AS /basic /Rect [100 620 114 634] /AP << /N << /basic 11 0 R /Off 18 0 R >> >> >>")
        object(14, "<< \(widget) /Parent 12 0 R /AS /Off /Rect [140 620 154 634] /AP << /N << /pro 11 0 R /Off 18 0 R >> >> >>")
        object(15, "<< \(widget) /FT /Ch /Ff 131072 /T (country) /Opt [[(pt) (Portugal)] [(es) (Spain)] (Other)] /V (pt) /DA (/Helv 10 Tf 0 g) /Rect [100 580 250 600] >>")
        object(16, "<< \(widget) /FT /Tx /Ff 4096 /T (notes) /Rect [100 480 400 560] >>")
        object(17, "<< \(widget) /FT /Sig /T (sign) /Rect [100 420 300 460] >>")
        object(18, stream(look, ""))
        object(19, "<< \(widget) /FT /Btn /Ff 65536 /T (send) /Rect [100 380 180 400] >>")
        object(20, "<< /T (person) /FT /Tx /DA (/Helv 11 Tf 0 0 1 rg) /Kids [7 0 R 8 0 R] >>")
        object(21, "<< \(widget) /FT /Tx /T (when) /Rect [320 580 440 600] /AA << /F << /S /JavaScript /JS (AFDate_FormatEx\\(\"dd/mm/yyyy\"\\);) >> >> >>")
        object(22, stream("", "<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"/>"))
        let xrefOffset = body.count
        var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
        xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        body.append(Data(xref.utf8))
        return body
    }
}

extension TestPDF {
    /// A form as it comes off a printer: labels, with boxes and lines drawn to write in,
    /// and no fields. One box holds printed text, which makes it a heading and not a place
    /// to write.
    static func paperForm() -> Data {
        func label(_ text: String, _ x: Int, _ y: Int, size: Int = 11) -> String { "BT /F1 \(size) Tf \(x) \(y) Td (\(text)) Tj ET\n" }
        let content = label("Application", 72, 720, size: 18)
            + label("Full name", 72, 680) + "0.75 w 150 674 250 20 re S\n"
            + label("Email", 72, 642) + "150 638 m 400 638 l S\n"
            + label("Phone: ______________________", 72, 602)
            + "72 560 12 12 re S\n" + label("Subscribe to the newsletter", 92, 562)
            + "72 536 12 12 re S\n" + label("I accept the terms", 92, 538)
            + label("Comments", 72, 505) + "72 400 400 95 re S\n"
            + "72 340 220 24 re S\n" + label("Office use only", 80, 348)
        return MinimalPage.document(content: content)
    }
}

/// A one-page document with a font and the given drawing.
enum MinimalPage {
    static func document(content: String) -> Data {
        var body = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        func object(_ text: String) {
            offsets.append(body.count)
            body.append(Data("\(offsets.count) 0 obj\n\(text)\nendobj\n".utf8))
        }
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        object("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        let xrefOffset = body.count
        var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
        xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        body.append(Data(xref.utf8))
        return body
    }
}

/// What Apple's own PDF code makes of some bytes: the yardstick for the engine's output.
struct Reference {
    let document: PDFDocument

    init(_ data: Data, password: String? = nil) throws {
        document = try #require(PDFDocument(data: data), "PDFKit could not open the data")
        if let password {
            #expect(document.unlock(withPassword: password))
        }
    }

    var pageCount: Int { document.pageCount }

    /// The text of each page, trimmed.
    var texts: [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    /// Each page's size and rotation.
    var shapes: [String] {
        (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { return "?" }
            let box = page.bounds(for: .cropBox)
            return "\(Int(box.width))x\(Int(box.height))@\(page.rotation)"
        }
    }

    /// The pixels of a page drawn small, for checking that a save did not change how it looks.
    func pixels(ofPage index: Int, fullSize: Bool = false) -> Data? {
        Self.pixels(of: document.page(at: index), fullSize: fullSize)
    }

    /// - Parameter fullSize: Draw at one pixel per point instead of thumbnail size. PDFKit
    ///   simplifies annotations in tiny renderings, so comparisons of them need full size.
    static func pixels(of page: PDFPage?, fullSize: Bool = false) -> Data? {
        guard let page else { return nil }
        let box = page.bounds(for: .cropBox)
        let sideways = page.rotation % 180 != 0
        let size = sideways ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = fullSize ? 1 : 96 / max(size.width, size.height)
        let width = max(Int(size.width * scale), 1), height = max(Int(size.height * scale), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.data.map { Data(bytes: $0, count: width * height * 4) }
    }
}
