import CoreGraphics
import Foundation
import PDFKit
@testable import SheafKit
import Testing

/// Runs the engine over a list of real PDFs. Off unless `SHEAF_CORPUS` names a text file
/// with one path per line:
///
///     SHEAF_CORPUS=/tmp/list.txt swift test --filter Corpus
@Suite struct CorpusTests {
    static let listPath = ProcessInfo.processInfo.environment["SHEAF_CORPUS"]

    @Test(.enabled(if: listPath != nil))
    func everyFileReadsLikeCoreGraphicsReadsIt() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        var checked = 0, skipped = 0, rebuilt = 0
        var problems: [String] = []
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { continue }
            let reference = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
            guard let reference, reference.isUnlocked else {
                // Core Graphics cannot read it either, or it needs a password.
                skipped += 1
                continue
            }
            checked += 1
            do {
                let file = try PDFFile(data: data)
                let pages = try file.pageIDs().count
                if pages != reference.numberOfPages {
                    problems.append("\(path): \(pages) pages, Core Graphics sees \(reference.numberOfPages)")
                }
                var unreadable = 0
                for number in file.objectNumbers where (try? file.object(ObjectID(number))) == nil { unreadable += 1 }
                if unreadable > 0 { problems.append("\(path): \(unreadable) unreadable objects") }
                // A file whose own table is wrong is the file's problem, not the engine's.
                if file.crossReference.wasRebuilt { rebuilt += 1 }
            } catch {
                problems.append("\(path): \(error)")
            }
        }
        print("corpus: \(checked) checked, \(skipped) skipped, \(rebuilt) repaired, \(problems.count) problems")
        for problem in problems.prefix(60) { print("  " + problem) }
        #expect(problems.isEmpty)
    }
}

extension CorpusTests {
    /// Edits and saves every file both ways, and checks the results with PDFKit.
    @Test(.enabled(if: listPath != nil))
    func everyFileSurvivesEditingAndSaving() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        var checked = 0, pagesRead = 0
        var problems: [String] = []
        func texts(_ document: PDFDocument) -> [String] {
            // First and last page are enough to catch reordering and content damage.
            [0, document.pageCount - 1].map { document.page(at: $0)?.string ?? "" }
        }
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let original = PDFDocument(data: data), !original.isLocked, original.pageCount > 0
            else { continue }
            checked += 1
            do {
                let file = try PDFFile(data: data)
                let expected = texts(original)

                // Appended changes.
                var editor = PDFEditor(file)
                var info = try editor.info()
                info.title = "Corpus check"
                try editor.setInfo(info)
                try editor.arrangePages(Array((0..<original.pageCount).reversed()))
                let appended = try editor.serialized()
                if !file.crossReference.wasRebuilt, appended.prefix(data.count) != data {
                    problems.append("\(path): appended save altered the original bytes")
                }
                guard let reopened = PDFDocument(data: appended) else {
                    problems.append("\(path): PDFKit cannot open the appended save")
                    continue
                }
                if reopened.pageCount != original.pageCount || texts(reopened) != Array(expected.reversed()) {
                    problems.append("\(path): appended save reads differently")
                }
                let look = Reference.pixels(of: original.page(at: 0))
                if Reference.pixels(of: reopened.page(at: original.pageCount - 1)) != look {
                    problems.append("\(path): appended save looks different")
                }
                if try PDFFile(data: appended).info().title != "Corpus check" {
                    problems.append("\(path): title was not saved")
                }

                // Written afresh.
                let rewritten = try PDFEditor(file).rewritten()
                guard let fresh = PDFDocument(data: rewritten) else {
                    problems.append("\(path): PDFKit cannot open the rewritten file")
                    continue
                }
                if fresh.pageCount != original.pageCount || texts(fresh) != expected {
                    problems.append("\(path): rewritten file reads differently")
                }
                if Reference.pixels(of: fresh.page(at: 0)) != look {
                    problems.append("\(path): rewritten file looks different")
                }
                // Protected with a password and opened again.
                let locked = try PDFEditor(file).rewritten(protection: .password(user: "corpus"))
                let unlocked = try PDFFile(data: locked, password: "corpus")
                if try unlocked.pageIDs().count != original.pageCount {
                    problems.append("\(path): protected copy has the wrong page count")
                }
                if let reader = PDFDocument(data: locked), reader.unlock(withPassword: "corpus") {
                    if Reference.pixels(of: reader.page(at: 0)) != look { problems.append("\(path): protected copy looks different") }
                } else {
                    problems.append("\(path): PDFKit cannot unlock the protected copy")
                }

                // Content streams.
                for page in try file.pageIDs().prefix(50) {
                    pagesRead += 1
                    let content = try file.contentStream(forPage: page)
                    if content.hasUnreadableTail { problems.append("\(path): page content has an unreadable tail") }
                    var joined = Data()
                    let dictionary = try file.object(page).dictionaryValue ?? [:]
                    let contents = try file.value("Contents", in: dictionary)
                    for part in contents.arrayValue ?? [contents] {
                        guard let stream = try file.resolve(part).streamValue else { continue }
                        if !joined.isEmpty { joined.append(0x0A) }
                        joined.append(try file.decodedData(of: stream))
                    }
                    if content.data() != joined { problems.append("\(path): page content does not round trip") }
                }
            } catch {
                problems.append("\(path): \(error)")
            }
        }
        print("corpus: \(checked) files edited and saved, \(pagesRead) pages of content read, \(problems.count) problems")
        for problem in problems.prefix(60) { print("  " + problem) }
        #expect(problems.isEmpty)
    }
}

extension CorpusTests {
    /// Annotates, bookmarks and flattens the first page of every file.
    @Test(.enabled(if: listPath != nil))
    func everyFileTakesAnnotationsAndBookmarks() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        var checked = 0
        var problems: [String] = []
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let original = PDFDocument(data: data), !original.isLocked, let firstPage = original.page(at: 0)
            else { continue }
            checked += 1
            do {
                var editor = PDFEditor(try PDFFile(data: data))
                let existing = firstPage.annotations.count
                let box = try editor.pageBox(at: 0)
                // Placed relative to the page, whatever its size and origin.
                func place(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PDFRectangle {
                    PDFRectangle(x: box.x + box.width * x, y: box.y + box.height * y, width: box.width * width, height: box.height * height)
                }
                var square = Annotation(kind: .square, rect: place(0.1, 0.1, 0.3, 0.2))
                square.color = .red
                var text = Annotation(kind: .freeText, rect: place(0.5, 0.5, 0.4, 0.2))
                text.contents = "Corpus"
                var stamp = Annotation(kind: .stamp, rect: place(0.2, 0.7, 0.5, 0.15))
                stamp.stamp = .text("Checked")
                for annotation in [square, text, stamp] { try editor.addAnnotation(annotation, toPageAt: 0) }
                var outline = try editor.outline()
                outline.append(OutlineItem(title: "Corpus bookmark", pageIndex: 0))
                try editor.setOutline(outline)

                let annotated = try editor.serialized()
                guard let reopened = PDFDocument(data: annotated), let page = reopened.page(at: 0) else {
                    problems.append("\(path): PDFKit cannot open the annotated file")
                    continue
                }
                if page.annotations.count != existing + 3 {
                    problems.append("\(path): \(page.annotations.count) annotations, expected \(existing + 3)")
                }
                let root = reopened.outlineRoot
                if root?.child(at: (root?.numberOfChildren ?? 1) - 1)?.label != "Corpus bookmark" {
                    problems.append("\(path): bookmark was not saved")
                }
                if try PDFFile(data: annotated).annotations(forPage: try PDFFile(data: annotated).pageIDs()[0]).count < 3 {
                    problems.append("\(path): the engine cannot read back its annotations")
                }

                let before = Reference.pixels(of: page, fullSize: true)
                try editor.flattenAnnotations(onPageAt: 0)
                guard let flat = PDFDocument(data: try editor.serialized()), let flatPage = flat.page(at: 0) else {
                    problems.append("\(path): PDFKit cannot open the flattened file")
                    continue
                }
                if flatPage.annotations.count > existing { problems.append("\(path): flattening left the new annotations behind") }
                // The three additions have no text marks, so the look must not change.
                // Annotations the file came with may include text marks, which PDFKit draws
                // itself. A page with its own blending color space can shift a color by one
                // level out of 255 when drawing becomes part of it, which is not a difference.
                if existing == 0, let before, let after = Reference.pixels(of: flatPage, fullSize: true) {
                    let changed = before.count != after.count ? before.count
                        : zip(before, after).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 3 ? 1 : 0) }
                    if Double(changed) > Double(before.count) * 0.005 {
                        problems.append("\(path): flattening changed how the page looks (\(changed) of \(before.count) bytes)")
                    }
                }
            } catch {
                problems.append("\(path): \(error)")
            }
        }
        print("corpus: \(checked) files annotated, bookmarked and flattened, \(problems.count) problems")
        for problem in problems.prefix(60) { print("  " + problem) }
        #expect(problems.isEmpty)
    }
}

extension CorpusTests {
    /// Compresses, splits, merges and stamps every file, and checks the results with PDFKit.
    @Test(.enabled(if: listPath != nil))
    func everyFileSurvivesThePageAndFileTools() throws {
        let paths = try String(contentsOfFile: try #require(Self.listPath), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        var checked = 0, before = 0, lossless = 0, balanced = 0
        var problems: [String] = []
        func texts(_ document: PDFDocument) -> [String] {
            [0, document.pageCount - 1].map { document.page(at: $0)?.string ?? "" }
        }
        /// The share of color values that differ by more than a little.
        func change(_ a: Data?, _ b: Data?) -> Double {
            guard let a, let b, a.count == b.count, !a.isEmpty else { return 1 }
            return Double(zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 24 ? 1 : 0) }) / Double(a.count)
        }
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let original = PDFDocument(data: data), !original.isLocked, original.pageCount > 0
            else { continue }
            checked += 1
            do {
                let editor = PDFEditor(try PDFFile(data: data))
                let expected = texts(original)
                let look = Reference.pixels(of: original.page(at: 0))

                // Smaller without visible change, then smaller with softer pictures.
                for (options, exact) in [(CompressionOptions.lossless, true), (.balanced, false)] {
                    let compressed = try editor.compressed(options)
                    if exact { lossless += compressed.count } else { balanced += compressed.count }
                    guard let reopened = PDFDocument(data: compressed) else {
                        problems.append("\(path): PDFKit cannot open the compressed file (exact=\(exact))")
                        continue
                    }
                    if reopened.pageCount != original.pageCount || texts(reopened) != expected {
                        problems.append("\(path): compressed file reads differently (exact=\(exact))")
                    }
                    let after = Reference.pixels(of: reopened.page(at: 0))
                    if exact ? after != look : change(look, after) > 0.02 {
                        problems.append("\(path): compressed file looks different (exact=\(exact), \(change(look, after)))")
                    }
                    if try PDFFile(data: compressed).wasRepaired { problems.append("\(path): compressed file needed repair") }
                }
                before += data.count

                // The last and first page as a document of their own, and two copies joined.
                let chosen = original.pageCount > 1 ? [original.pageCount - 1, 0] : [0]
                if let extracted = PDFDocument(data: try editor.extractingPages(chosen)) {
                    // A document's reading-order tags stay behind, so the same text can come
                    // out in another order.
                    let wanted = (chosen.count > 1 ? Array(expected.reversed()) : expected).map { String($0.sorted()) }
                    if extracted.pageCount != chosen.count || texts(extracted).map({ String($0.sorted()) }) != wanted {
                        problems.append("\(path): extracted pages read differently")
                    }
                    if Reference.pixels(of: extracted.page(at: chosen.count - 1)) != look {
                        problems.append("\(path): extracted page looks different")
                    }
                } else {
                    problems.append("\(path): PDFKit cannot open the extracted pages")
                }
                let source = MergeSource(document: editor, title: "Copy")
                if PDFDocument(data: try PDFGenerator.merged([source, source]))?.pageCount != original.pageCount * 2 {
                    problems.append("\(path): merged file has the wrong page count")
                }

                // A watermark, a header and footer, and the first page cut in two.
                var stamped = editor
                var watermark = Watermark(content: .text("Corpus"))
                watermark.opacity = 1
                watermark.color = .red
                try stamped.addWatermark(watermark, toPagesAt: [0])
                var lines = HeaderFooter()
                lines.footer.center = "Page {page} of {pages}"
                try stamped.addHeaderFooter(lines, toPagesAt: [0])
                try stamped.splitPagesInHalf(at: [0], direction: .vertical)
                let saved = try stamped.serialized()
                guard let reopened = PDFDocument(data: saved) else {
                    problems.append("\(path): PDFKit cannot open the stamped file")
                    continue
                }
                if reopened.pageCount != original.pageCount + 1 { problems.append("\(path): stamped file has the wrong page count") }
                if original.pageCount > 1, reopened.page(at: reopened.pageCount - 1)?.string != expected[1] {
                    problems.append("\(path): stamping changed another page")
                }

                // A form built on the first page, filled in, read back by PDFKit, and flattened.
                var form = editor
                let box = try form.pageBox(at: 0)
                func place(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PDFRectangle {
                    PDFRectangle(x: box.x + box.width * x, y: box.y + box.height * y, width: max(box.width * width, 12), height: max(box.height * height, 12))
                }
                let existingFields = try form.formFields().count
                let text = try form.addField(NewField(kind: .text, name: "Corpus text", rect: place(0.1, 0.8, 0.5, 0.04)), toPageAt: 0)
                let check = try form.addField(NewField(kind: .checkbox, name: "Corpus check", rect: place(0.1, 0.7, 0.03, 0.03)), toPageAt: 0)
                if let field = try form.formField(forWidget: text) { try form.setFieldValue(field.id, to: "Проверка 123") }
                try form.setButton(check, on: true)
                _ = try form.detectFieldCandidates(onPageAt: 0)
                guard let withForm = PDFDocument(data: try form.serialized()), let formPage = withForm.page(at: 0) else {
                    problems.append("\(path): PDFKit cannot open the file with a form")
                    continue
                }
                let widgets = formPage.annotations.filter { $0.type == "Widget" }
                if !widgets.contains(where: { $0.widgetStringValue == "Проверка 123" }) { problems.append("\(path): PDFKit does not read the filled text field") }
                if !widgets.contains(where: { $0.widgetFieldType == .button && $0.buttonWidgetState == .onState }) { problems.append("\(path): PDFKit does not read the checked box") }
                if try form.formFields().count != existingFields + 2 { problems.append("\(path): the engine does not read back its fields") }
                try form.flattenForm()
                guard let flat = PDFDocument(data: try form.serialized()), let flatPage = flat.page(at: 0) else {
                    problems.append("\(path): PDFKit cannot open the flattened form")
                    continue
                }
                if flatPage.annotations.contains(where: { $0.type == "Widget" }) { problems.append("\(path): flattening left widgets behind") }
                // On pages too small for the text to fit its field, the cut-off text is not read back.
                if box.width >= 300, flatPage.string?.contains("Проверка 123") != true {
                    problems.append("\(path): the flattened field's text cannot be read")
                }
            } catch {
                problems.append("\(path): \(error)")
            }
        }
        func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        print("corpus: \(checked) files compressed, split, merged and stamped, \(problems.count) problems")
        print("corpus: \(megabytes(before)) as found, \(megabytes(lossless)) compressed exactly, \(megabytes(balanced)) with pictures at 150 per inch")
        for problem in problems.prefix(60) { print("  " + problem) }
        #expect(problems.isEmpty)
    }
}

/// Explains how one file reads. Off unless `SHEAF_DEBUG_FILE` is a path.
@Suite struct DebugFileTests {
    static let path = ProcessInfo.processInfo.environment["SHEAF_DEBUG_FILE"]

    @Test(.enabled(if: path != nil))
    func explain() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(Self.path)))
        let header = data.parse { $0.find("%PDF-", from: 0) } ?? -1
        print("debug: \(data.count) bytes, header at \(header)")
        do {
            let table = try CrossReference.read(from: data, headerOffset: header)
            print("debug: table has \(table.entries.count) entries, stream=\(table.newestSectionIsStream), trailer keys \(table.trailer.keys.map(\.rawValue).sorted())")
        } catch {
            print("debug: table could not be read: \(error)")
        }
        let file = try PDFFile(data: data)
        print("debug: repaired=\(file.wasRepaired) pages=\(try file.pageIDs().count) objects=\(file.objectNumbers.count) encrypted=\(file.isEncrypted)")
        for number in file.objectNumbers {
            let before = file.wasRepaired
            do { _ = try file.object(ObjectID(number)) } catch { print("debug: object \(number): \(error)") }
            if file.wasRepaired != before { print("debug: reading object \(number) forced a repair") }
        }
    }
}
