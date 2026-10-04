import Foundation
@testable import SheafKit
import Testing

/// Feeds the engine damaged files. Errors are fine; crashes and hangs are not.
@Suite struct FuzzTests {
    /// A small deterministic generator, so a failure can be reproduced.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Multiplies the number of damaged files tried. Set `SHEAF_FUZZ=40` for a long run.
    static let scale = ProcessInfo.processInfo.environment["SHEAF_FUZZ"].flatMap(Int.init) ?? 1

    static let nastyValues = [
        "0", "-1", "65536", "4294967296", "9223372036854775807", "99999999999999999999", "1e308",
        "<<", ">>", "[", "]", "(", ")", "stream", "endstream", "endobj", "obj", "R", "/Length", "/Kids", "/Parent", "null",
    ]

    private func mutate(_ original: Data, using generator: inout Generator) -> Data {
        var data = original
        for _ in 0..<Int.random(in: 1...4, using: &generator) {
            guard !data.isEmpty else { break }
            let position = Int.random(in: 0..<data.count, using: &generator)
            switch Int.random(in: 0..<7, using: &generator) {
            case 0: data[position] = UInt8.random(in: .min ... .max, using: &generator)
            case 1: data.remove(at: position)
            case 2: data.insert(UInt8.random(in: .min ... .max, using: &generator), at: position)
            case 3: data = data.prefix(position)
            case 4:
                // Replace a number with an awkward one.
                var end = position
                while end < data.count, data[end] >= 0x30, data[end] <= 0x39 { end += 1 }
                data.replaceSubrange(position..<end, with: Data(Self.nastyValues.randomElement(using: &generator)!.utf8))
            case 5:
                data.insert(contentsOf: Data(Self.nastyValues.randomElement(using: &generator)!.utf8), at: position)
            default:
                // Copy a chunk over another place.
                let length = min(Int.random(in: 1...64, using: &generator), data.count - position)
                let target = Int.random(in: 0..<data.count, using: &generator)
                let chunk = Data(data[position..<position + length])
                data.replaceSubrange(target..<min(target + length, data.count), with: chunk)
            }
        }
        return Data(data)
    }

    /// Everything the engine can do with a file, with errors ignored.
    private func exercise(_ data: Data, password: String?) {
        guard let file = try? PDFFile(data: data, password: password) else { return }
        let pages = (try? file.pageIDs()) ?? []
        for number in file.objectNumbers.prefix(400) {
            guard let object = try? file.object(ObjectID(number)) else { continue }
            if let stream = object.streamValue { _ = try? file.decodedData(of: stream) }
        }
        for page in pages.prefix(5) {
            _ = try? file.contentStream(forPage: page).data()
            _ = try? file.inherited("MediaBox", forPage: page)
        }
        _ = try? file.info()

        var editor = PDFEditor(file)
        _ = try? editor.rotatePage(at: 0, by: 90)
        _ = try? editor.pageBox(at: 0)
        _ = try? editor.arrangePages(Array((0..<pages.count).reversed()))
        _ = try? editor.duplicatePage(at: 0)
        _ = try? editor.insertPages(from: file)
        _ = try? editor.setInfo(DocumentInfo(title: "Fuzz"))
        if let saved = try? editor.serialized() { _ = try? PDFFile(data: saved, password: password).pageIDs() }
        _ = try? editor.rewritten(protection: .none)

        // The page and file tools, on the file as it was read.
        var tools = PDFEditor(file)
        _ = try? tools.outline()
        _ = try? tools.imageUsages()
        _ = try? tools.addWatermark(Watermark(content: .text("Fuzz")))
        var lines = HeaderFooter()
        lines.footer.center = HeaderFooter.pageToken
        _ = try? tools.addHeaderFooter(lines)
        _ = try? tools.splitPagesInHalf(at: [0], direction: .vertical)
        _ = try? tools.removePages(at: [0])
        _ = try? tools.extractingPages([0])
        _ = try? PDFGenerator.merged([MergeSource(document: PDFEditor(file), title: "Fuzz")])
        if let compressed = try? PDFEditor(file).compressed(.balanced) { _ = try? PDFFile(data: compressed, password: password).pageIDs() }

        // Forms: read, fill, change, build, detect, reset and flatten.
        var forms = PDFEditor(file)
        for field in ((try? forms.formFields()) ?? []).prefix(8) {
            _ = try? forms.setFieldValue(field.id, to: "Fuzz")
            _ = try? forms.updateField(field)
            if let widget = field.widgets.first {
                _ = try? forms.setButton(widget.id, on: true)
                _ = try? forms.setWidgetRect(widget.id, to: PDFRectangle(x: 10, y: 10, width: 80, height: 20))
                _ = try? forms.annotationDocument(for: widget.id, onPageAt: widget.pageIndex ?? 0)
            }
        }
        _ = try? forms.addField(NewField(kind: .text, name: "Fuzz", rect: PDFRectangle(x: 20, y: 20, width: 100, height: 20)), toPageAt: 0)
        _ = try? forms.addField(NewField(kind: .radio, name: "Fuzz", rect: PDFRectangle(x: 20, y: 50, width: 14, height: 14)), toPageAt: 0)
        _ = try? forms.detectFieldCandidates(onPageAt: 0)
        _ = try? forms.resetForm()
        if let widget = (try? forms.formFields())?.last?.widgets.first { _ = try? forms.removeWidget(widget.id) }
        _ = try? forms.flattenForm()
        _ = try? forms.serialized()

        // Converting and comparing.
        let converting = PDFEditor(file)
        _ = try? converting.wordDocument()
        _ = try? converting.spreadsheet()
        _ = try? converting.archival()
        if let comparison = try? DocumentComparer.compare(converting, converting) {
            _ = try? comparison.report(nameA: "a", nameB: "b", pageSize: PageSize(width: 612, height: 792), date: "today")
        }

        // Content: read, change text and pictures, find, redact, add a text layer.
        var content = PDFEditor(file)
        if let page = try? content.pageContent(at: 0) {
            if let block = page.blocks.first(where: \.isEditable) {
                _ = try? content.replaceText(ofBlock: block.id, onPageAt: 0, with: "Fuzz " + block.flowingText + " Ж")
                _ = try? content.moveText(ofBlock: block.id, onPageAt: 0, dx: 3, dy: -3)
            }
            if let image = page.images.first {
                _ = try? content.setImageFrame(PDFRectangle(x: 5, y: 5, width: 40, height: 40), ofImage: image.id, onPageAt: 0)
            }
        }
        _ = try? content.replaceAll("e", with: "ee", onPagesAt: [0])
        _ = try? content.addText("Fuzz", toPageAt: 0, at: PDFPoint(x: 10, y: 100))
        _ = try? content.redact([PDFRectangle(x: 0, y: 0, width: 300, height: 400)], onPageAt: 0)
        _ = try? content.addTextLayer([RecognizedText(text: "Fuzz", frame: PDFRectangle(x: 0.1, y: 0.1, width: 0.5, height: 0.05))], toPageAt: 0)
        if let saved = try? content.rewritten() { _ = try? PDFEditor(PDFFile(data: saved, password: password)).pageContent(at: 0) }
    }

    @Test(arguments: [Fixture.text3Pages, .handwritten, .outlineAnnotations, .encrypted])
    func damagedFixturesNeverCrash(fixture: Fixture) throws {
        let original = try fixture.data
        var generator = Generator(state: UInt64(fixture.rawValue.count) &* 7919)
        for _ in 0..<250 * Self.scale {
            exercise(mutate(original, using: &generator), password: fixture == .encrypted ? "sheaf" : nil)
        }
    }

    @Test func damagedHandBuiltFilesNeverCrash() {
        for (seed, original) in [TestPDF.compressed(), TestPDF.compressed(predictor: false), TestPDF.nestedTree(), TestPDF.form(), TestPDF.paperForm()].enumerated() {
            var generator = Generator(state: UInt64(seed + 1) &* 104_729)
            for _ in 0..<400 * Self.scale { exercise(mutate(original, using: &generator), password: nil) }
        }
    }

    @Test func randomBytesNeverCrash() {
        var generator = Generator(state: 42)
        for _ in 0..<300 * Self.scale {
            var data = Data("%PDF-1.7\n".utf8)
            for _ in 0..<Int.random(in: 0...40, using: &generator) {
                if Bool.random(using: &generator) {
                    data.append(Data((Self.nastyValues.randomElement(using: &generator)! + " ").utf8))
                } else {
                    data.append(UInt8.random(in: .min ... .max, using: &generator))
                }
            }
            data.append(Data("\n1 0 obj << /Type /Catalog /Pages 1 0 R /Length 1 0 R >> stream\n".utf8))
            exercise(data, password: nil)
            _ = ContentStream(data: data).data()
        }
    }

    @Test func filesThatReferToThemselvesAreRefused() {
        // A stream whose length is itself, a page tree that is its own child, and an
        // object stream packed inside itself.
        let lengthLoop = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Length 2 0 R >> stream\nabc\nendstream endobj\ntrailer << /Root 1 0 R >>"
        let treeLoop = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [2 0 R 2 0 R] /Parent 2 0 R /Count 2 >> endobj\ntrailer << /Root 1 0 R >>"
        let referenceLoop = "%PDF-1.4\n1 0 obj 2 0 R endobj\n2 0 obj 1 0 R endobj\ntrailer << /Root 1 0 R >>"
        for text in [lengthLoop, treeLoop, referenceLoop] {
            exercise(Data(text.utf8), password: nil)
        }
        #expect(throws: SheafError.self) { try PDFFile(data: Data(referenceLoop.utf8)) }
        #expect((try? PDFFile(data: Data(treeLoop.utf8)).pageIDs()) == [])
    }
}
