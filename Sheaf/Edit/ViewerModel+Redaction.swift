import AppKit
import PDFKit
import SheafKit

/// Kinds of text that Find to Redact looks for.
enum RedactionPattern: String, CaseIterable, Identifiable {
    case email, phone, card, socialSecurity

    var id: Self { self }

    var title: String {
        switch self {
        case .email: String(localized: "Email Addresses")
        case .phone: String(localized: "Phone Numbers")
        case .card: String(localized: "Card Numbers")
        case .socialSecurity: String(localized: "Social Security Numbers")
        }
    }

    /// What to say when the document has none.
    var nothingFound: String {
        switch self {
        case .email: String(localized: "No email addresses were found.")
        case .phone: String(localized: "No phone numbers were found.")
        case .card: String(localized: "No card numbers were found.")
        case .socialSecurity: String(localized: "No Social Security numbers were found.")
        }
    }

    var expression: String {
        switch self {
        case .email: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        // Groups of digits with separators between them, so plain long numbers are left alone.
        case .phone: #"(?<![\d\w])(?:\+\d{1,3}[\s.\-]?)?(?:\(\d{2,4}\)[\s.\-]?|\d{2,4}[\s.\-])\d{2,4}[\s.\-]\d{2,4}(?:[\s.\-]\d{2,4})?(?!\d)"#
        case .card: #"(?<!\d)\d(?:[ \-]?\d){12,18}(?!\d)"#
        case .socialSecurity: #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#
        }
    }
}

/// Redaction: marking what should go, and removing it for good.
extension ViewerModel {
    // MARK: Marks

    /// The redaction marks on every page that has any. Read once per change to the document.
    private var redactionMarks: [Int: [Annotation]] {
        guard let sheafDocument, let editor = sheafDocument.editor else { return [:] }
        if let cache = markCache, cache.revision == sheafDocument.revision, cache.generation == sheafDocument.generation { return cache.marks }
        var marks: [Int: [Annotation]] = [:]
        for index in (try? editor.pagesWithRedactionMarks()) ?? [] {
            let found = (try? editor.annotations(onPageAt: index))?.filter { $0.kind == .redact } ?? []
            if !found.isEmpty { marks[index] = found }
        }
        markCache = (sheafDocument.revision, sheafDocument.generation, marks)
        return marks
    }

    func redactionMarks(onPage index: Int) -> [Annotation] {
        redactionMarks[index] ?? []
    }

    /// PDFKit draws redaction marks as solid gray boxes, which hide what is being marked.
    /// Sheaf draws them itself, as frames one can see through, so PDFKit's are switched off.
    func hideNativeMarks() {
        guard let sheafDocument, let document else { return }
        for (pageIndex, marks) in redactionMarks {
            var changed = false
            for mark in marks {
                guard let id = mark.objectID, let shown = sheafDocument.displayedAnnotation(id, onPage: pageIndex), shown.shouldDisplay else { continue }
                shown.shouldDisplay = false
                changed = true
            }
            if changed, let page = document.page(at: pageIndex) { pdfView.annotationsChanged(on: page) }
        }
    }

    var redactionMarkCount: Int {
        _ = sheafDocument?.revision
        return redactionMarks.values.reduce(0) { $0 + $1.count }
    }

    /// Adds marks to pages in one step.
    ///
    /// - Parameter areas: For each page, frames on the page as displayed.
    @discardableResult
    private func addMarks(_ areas: [Int: [PDFRectangle]], name: String) -> Int {
        guard let sheafDocument else { return 0 }
        let author = NSFullUserName()
        let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return sheafDocument.apply(name) { editor, effect in
            var count = 0
            for (pageIndex, frames) in areas.sorted(by: { $0.key < $1.key }) {
                let geometry = try editor.geometry(ofPageAt: pageIndex)
                for frame in frames {
                    // A little larger than the text, so the box covers the tops and tails of letters.
                    let padded = PDFRectangle(x: frame.x - 1, y: frame.y - 1, width: frame.width + 2, height: frame.height + 2)
                    var mark = Annotation(kind: .redact, rect: geometry.pageRect(padded))
                    mark.author = author
                    mark.modified = date
                    try editor.addAnnotation(mark, toPageAt: pageIndex)
                    count += 1
                }
                effect.pages.insert(pageIndex)
            }
            return count
        } ?? 0
    }

    /// Marks every place in the document where a kind of text is found.
    func markForRedaction(_ pattern: RedactionPattern) {
        guard let sheafDocument, sheafDocument.isEditable else { return }
        let count = pageCount
        let source = Toolbox.Source(data: sheafDocument.currentData, name: "", password: sheafDocument.password)
        let revision = sheafDocument.revision
        isFindingText = true
        Task { [weak self] in
            let matches = (try? await Toolbox.findText(source, pattern.expression, options: TextSearchOptions(isRegularExpression: true), pageCount: count)) ?? []
            guard let self else { return }
            self.isFindingText = false
            guard sheafDocument.revision == revision else { return }
            var areas: [Int: [PDFRectangle]] = [:]
            for match in matches { areas[match.pageIndex, default: []].append(contentsOf: match.frames) }
            if areas.isEmpty {
                self.editMessage = pattern.nothingFound
            } else {
                self.addMarks(areas, name: String(localized: "Mark for Redaction"))
                if let first = areas.keys.min(), !areas.keys.contains(self.currentPageIndex) { self.goToPage(index: first) }
            }
        }
    }

    /// Marks every place the find bar has found.
    func markMatchesForRedaction() {
        var areas: [Int: [PDFRectangle]] = [:]
        for match in textMatches { areas[match.pageIndex, default: []].append(contentsOf: match.frames) }
        guard !areas.isEmpty else { return }
        addMarks(areas, name: String(localized: "Mark for Redaction"))
    }

    /// Marks the text selected on the pages.
    func markSelectionForRedaction() {
        guard let textSelection = pdfView.currentSelection, let document, let editor = sheafDocument?.editor else { return }
        var areas: [Int: [PDFRectangle]] = [:]
        for line in textSelection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                let index = document.index(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5, let geometry = try? editor.geometry(ofPageAt: index) else { continue }
                areas[index, default: []].append(geometry.displayRect(PDFRectangle(bounds)))
            }
        }
        guard !areas.isEmpty else { return }
        addMarks(areas, name: String(localized: "Mark for Redaction"))
        pdfView.clearSelection()
    }

    var hasTextSelection: Bool { pdfView.currentSelection?.string?.isEmpty == false }

    func removeRedactionMarks() {
        let marks = redactionMarks
        guard !marks.isEmpty else { return }
        selection = nil
        sheafDocument?.apply(String(localized: "Remove Redaction Marks")) { editor, effect in
            for (pageIndex, annotations) in marks {
                for annotation in annotations {
                    if let id = annotation.objectID { try editor.removeAnnotation(id, fromPageAt: pageIndex) }
                }
                effect.pages.insert(pageIndex)
            }
        }
    }

    // MARK: Applying

    /// Removes what is under every mark for good. The document is written out afresh, so
    /// nothing of what was removed is left anywhere in the file.
    func applyRedactions() {
        guard let sheafDocument, var editor = sheafDocument.editor else { return }
        selection = nil
        contentSelection = nil
        do {
            let result = try editor.applyRedactions()
            let data = try editor.rewritten()
            guard sheafDocument.replaceContents(String(localized: "Redact"), with: data, password: sheafDocument.password) else {
                throw CocoaError(.fileWriteUnknown)
            }
            previewsRedactions = false
            show(sheafDocument)
            var removed: [String] = []
            if result.glyphs > 0 { removed.append(String(localized: "\(result.glyphs) characters")) }
            if result.images > 0 { removed.append(String(localized: "parts of \(result.images) pictures")) }
            if result.shapes > 0 { removed.append(String(localized: "\(result.shapes) shapes")) }
            if result.annotations > 0 { removed.append(String(localized: "\(result.annotations) annotations")) }
            editMessage = removed.isEmpty
                ? String(localized: "There was nothing under the marks. Black boxes were drawn where they were.")
                : String(localized: "Removed \(removed.formatted(.list(type: .and))). Save the document to keep the redacted version.")
        } catch {
            NSApp.presentError(error)
        }
    }
}
