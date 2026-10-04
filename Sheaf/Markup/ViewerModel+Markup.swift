import AppKit
import PDFKit
import SheafKit

/// A drag in progress on the page.
struct DragSession {
    enum Mode {
        case creating
        case moving
        case resizing(ResizeHandle)
    }

    var mode: Mode
    var pageIndex: Int
    var start: PDFPoint
    /// The annotation as it was when the drag began. `nil` while making a new one.
    var original: Annotation?
    /// The annotation as the drag has it now.
    var draft: Annotation
    /// Shows the draft while dragging. The document is only changed when the mouse is let go.
    var preview: SheafAnnotation?
    /// The annotation's regular display object, hidden while the preview stands in for it.
    var hidden: PDFAnnotation?
    var didMove = false
    /// Set when the drag is drawing a new form field, not an annotation.
    var fieldTool: FormTool?
}

/// What the selection frame and its handles should be drawn around.
struct SelectionGeometry {
    var pageIndex: Int
    var frame: PDFRectangle
    var handles: [(handle: ResizeHandle, point: PDFPoint)]
    /// The corners of a thing that is turned, in place of its upright frame.
    var outline: [PDFPoint]? = nil
    /// Whether the thing is part of what the page itself draws, a picture or a block of
    /// text, which gets the small square handles Pages puts on such things.
    var isPicture = false
    /// Whether a handle turns the thing while Command is held.
    var canTurn = false
}

/// Editing annotations: tools, selection, dragging and the commands that act on them.
extension ViewerModel {
    // MARK: Style

    func style(for tool: MarkupTool) -> MarkupStyle {
        styles[tool] ?? .standard(for: tool)
    }

    private func now() -> Date {
        // PDF dates hold whole seconds; rounding here keeps what is saved equal to what is shown.
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    // MARK: Selection

    var selectedAnnotation: Annotation? {
        guard let selection, let sheafDocument else { return nil }
        _ = sheafDocument.revision
        return sheafDocument.annotation(selection.id, onPage: selection.pageIndex)
    }

    var selectionGeometry: SelectionGeometry? {
        if let drag { return geometry(of: drag.draft, pageIndex: drag.pageIndex) }
        guard let selection, let annotation = selectedAnnotation else { return nil }
        return geometry(of: annotation, pageIndex: selection.pageIndex)
    }

    private func geometry(of annotation: Annotation, pageIndex: Int) -> SelectionGeometry {
        var handles: [(ResizeHandle, PDFPoint)] = []
        if annotation.kind == .line, let start = annotation.lineStart, let end = annotation.lineEnd {
            handles = [(.lineStart, start), (.lineEnd, end)]
        } else if annotation.isResizable {
            let rect = annotation.rect
            handles = ResizeHandle.frameHandles.compactMap { handle in
                handle.anchor.map { (handle, PDFPoint(x: rect.x + $0.x * rect.width, y: rect.y + $0.y * rect.height)) }
            }
        }
        return SelectionGeometry(pageIndex: pageIndex, frame: annotation.rect, handles: handles)
    }

    /// How far, in page units, a click may be from something and still count as on it.
    private var reach: Double { 7 / max(Double(pdfView.scaleFactor), 0.1) }

    private func handle(at point: PDFPoint, of annotation: Annotation, pageIndex: Int) -> ResizeHandle? {
        geometry(of: annotation, pageIndex: pageIndex).handles.first {
            abs($0.point.x - point.x) <= reach && abs($0.point.y - point.y) <= reach
        }?.handle
    }

    /// The topmost annotation under a point.
    func annotation(at point: PDFPoint, pageIndex: Int) -> Annotation? {
        guard let annotations = try? sheafDocument?.editor?.annotations(onPageAt: pageIndex) else { return nil }
        return annotations.last { annotation in
            guard annotation.objectID != nil, annotation.replyTo == nil else { return false }
            if annotation.isTextMarkup { return annotation.quads.contains { $0.contains(point) } }
            let rect = annotation.rect
            let slack = [.line, .ink].contains(annotation.kind) ? reach : 0
            return PDFRectangle(x: rect.x - slack, y: rect.y - slack, width: rect.width + 2 * slack, height: rect.height + 2 * slack).contains(point)
        }
    }

    /// Picks an annotation and, if asked, scrolls it into view.
    func select(_ target: AnnotationSelection?, reveal: Bool = false) {
        selection = target
        guard reveal, let target, let annotation = selectedAnnotation, let page = document?.page(at: target.pageIndex) else { return }
        pdfView.go(to: annotation.rect.cgRect.insetBy(dx: -40, dy: -80), on: page)
    }

    /// Called after the document changed, by an edit here or by Undo.
    func documentDidChange() {
        guard let sheafDocument else { return }
        if selection != nil, selectedAnnotation == nil { selection = nil }
        refreshMailOrigin()
        contentDidChange()
        invalidateThumbnails(sheafDocument.lastChangedPages)
        for index in sheafDocument.lastChangedPages {
            if let page = document?.page(at: index) { pdfView.annotationsChanged(on: page) }
        }
        hideNativeMarks()
        pdfView.overlay.needsDisplay = true
    }

    // MARK: Mouse

    /// A click on a page. Returns `false` to let PDFKit handle it, as for selecting text.
    func mouseDown(at point: PDFPoint, pageIndex: Int, clickCount: Int) -> Bool {
        guard let sheafDocument, sheafDocument.isEditable else { return false }
        if isFormEditing, let formTool {
            // Drawing a new field: a plain frame stands in for it while the mouse is down.
            selection = nil
            var frame = Annotation(kind: .square, rect: PDFRectangle(x: point.x, y: point.y, width: 0, height: 0))
            frame.color = .blue
            frame.lineWidth = 1
            var session = DragSession(mode: .creating, pageIndex: pageIndex, start: point, original: nil, draft: frame)
            session.fieldTool = formTool
            drag = session
            return true
        }
        switch tool {
        case .select:
            if let selection, selection.pageIndex == pageIndex, let annotation = selectedAnnotation,
               let handle = handle(at: point, of: annotation, pageIndex: pageIndex) {
                drag = DragSession(mode: .resizing(handle), pageIndex: pageIndex, start: point, original: annotation, draft: annotation)
                return true
            }
            if let hit = field(at: point, pageIndex: pageIndex) {
                if isFormEditing {
                    // With the form tools out, a field is something to move and change.
                    selection = AnnotationSelection(pageIndex: pageIndex, id: hit.widget.id)
                    if let model = sheafDocument.annotation(hit.widget.id, onPage: pageIndex) {
                        drag = DragSession(mode: .moving, pageIndex: pageIndex, start: point, original: model, draft: model)
                    }
                } else {
                    selection = nil
                    activate(hit)
                }
                return true
            }
            focusedWidget = nil
            guard let hit = annotation(at: point, pageIndex: pageIndex), let id = hit.objectID, hit.kind != .other,
                  // Outside markup mode a link is something to follow, not something to edit.
                  hit.kind != .link || isMarkupVisible
            else {
                selection = nil
                return false
            }
            selection = AnnotationSelection(pageIndex: pageIndex, id: id)
            if clickCount >= 2, hit.kind == .freeText {
                beginTextEditing(hit, pageIndex: pageIndex, isNew: false)
            } else if !hit.isTextMarkup {
                drag = DragSession(mode: .moving, pageIndex: pageIndex, start: point, original: hit, draft: hit)
            }
            return true

        case .highlight, .underline, .strikeOut:
            return false

        case .note:
            addNote(at: point, pageIndex: pageIndex)
            return true

        case .text, .rectangle, .ellipse, .line, .arrow, .draw, .link:
            selection = nil
            drag = DragSession(mode: .creating, pageIndex: pageIndex, start: point, original: nil, draft: newAnnotation(for: tool, at: point))
            return true
        }
    }

    private func newAnnotation(for tool: MarkupTool, at point: PDFPoint) -> Annotation {
        let style = style(for: tool)
        let empty = PDFRectangle(x: point.x, y: point.y, width: 0, height: 0)
        var annotation: Annotation
        switch tool {
        case .rectangle: annotation = Annotation(kind: .square, rect: empty)
        case .ellipse: annotation = Annotation(kind: .circle, rect: empty)
        case .line, .arrow:
            annotation = Annotation(kind: .line, rect: empty)
            annotation.lineStart = point
            annotation.lineEnd = point
            if tool == .arrow { annotation.endEnding = .openArrow }
        case .draw:
            annotation = Annotation(kind: .ink, rect: empty)
            annotation.paths = [[point]]
        case .text:
            annotation = Annotation(kind: .freeText, rect: empty)
            annotation.fontSize = style.fontSize
        case .link: annotation = Annotation(kind: .link, rect: empty)
        default: annotation = Annotation(kind: .square, rect: empty)
        }
        annotation.color = style.color
        annotation.fillColor = tool == .text ? nil : style.fillColor
        annotation.lineWidth = style.lineWidth
        annotation.opacity = style.opacity
        return annotation
    }

    func mouseDragged(to point: PDFPoint) {
        guard var session = drag, let page = document?.page(at: session.pageIndex) else { return }
        let limits = PDFRectangle(page.bounds(for: .cropBox))
        let point = PDFPoint(x: min(max(point.x, limits.x), limits.x + limits.width), y: min(max(point.y, limits.y), limits.y + limits.height))

        switch session.mode {
        case .creating:
            switch session.draft.kind {
            case .line:
                session.draft.lineEnd = point
                session.draft.rect = PDFRectangle(from: session.start, to: point)
            case .ink:
                if let last = session.draft.paths[0].last, abs(last.x - point.x) + abs(last.y - point.y) > 0.75 {
                    session.draft.paths[0].append(point)
                }
                session.draft.rect = PDFRectangle(enclosing: session.draft.paths[0]) ?? session.draft.rect
            default:
                session.draft.rect = PDFRectangle(from: session.start, to: point)
            }

        case .moving:
            guard let original = session.original else { return }
            // Keep the whole annotation on the page.
            let dx = min(max(point.x - session.start.x, limits.x - original.rect.x), limits.x + limits.width - original.rect.x - original.rect.width)
            let dy = min(max(point.y - session.start.y, limits.y - original.rect.y), limits.y + limits.height - original.rect.y - original.rect.height)
            session.draft = original
            session.draft.translate(dx: dx, dy: dy)

        case .resizing(let handle):
            guard let original = session.original else { return }
            session.draft = original
            switch handle {
            case .lineStart: session.draft.lineStart = point
            case .lineEnd: session.draft.lineEnd = point
            default:
                guard let anchor = handle.anchor else { return }
                var (left, bottom, right, top) = (original.rect.x, original.rect.y, original.rect.x + original.rect.width, original.rect.y + original.rect.height)
                let minimum = 8.0
                if anchor.x == 0 { left = min(point.x, right - minimum) }
                if anchor.x == 1 { right = max(point.x, left + minimum) }
                if anchor.y == 0 { bottom = min(point.y, top - minimum) }
                if anchor.y == 1 { top = max(point.y, bottom + minimum) }
                session.draft.resize(to: PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom))
            }
            if session.draft.kind == .line, let start = session.draft.lineStart, let end = session.draft.lineEnd {
                session.draft.rect = PDFRectangle(from: start, to: end)
            }
        }

        if !session.didMove {
            session.didMove = true
            if let id = session.original?.objectID {
                session.hidden = sheafDocument?.displayedAnnotation(id, onPage: session.pageIndex)
            }
            // What Sheaf draws itself follows the drag by being drawn again. Of the rest,
            // annotations whose look only the file knows are moved as they are, and
            // everything else is redrawn in a stand-in while the drag lasts.
            if !session.draft.isDrawnSharply, session.draft.kind == .link || session.draft.appearance() != nil {
                let preview = SheafAnnotation(model: session.draft, document: document)
                page.addAnnotation(preview)
                session.preview = preview
                session.hidden?.shouldDisplay = false
            }
        }
        if session.draft.isDrawnSharply {
            drag = session
            pdfView.refreshAnnotationViews()
            pdfView.overlay.needsDisplay = true
            return
        }
        if let preview = session.preview {
            preview.update(session.draft, document: document)
        } else {
            session.hidden?.bounds = session.draft.rect.cgRect
        }
        drag = session
        pdfView.annotationsChanged(on: page)
        pdfView.overlay.needsDisplay = true
    }

    /// The annotations of a page that Sheaf draws itself, as a drag or typing has them now.
    func sharpAnnotations(onPage index: Int) -> [SharpAnnotation] {
        guard let sheafDocument else { return [] }
        var draft: (replacing: ObjectID?, annotation: Annotation)?
        if let drag, drag.didMove, drag.pageIndex == index, drag.fieldTool == nil { draft = (drag.original?.objectID, drag.draft) }
        let before = sheafDocument.nativeChanges
        let result = sheafDocument.sharpAnnotations(onPage: index, draft: draft, hidden: Set([pdfView.editedAnnotationID].compactMap(\.self)))
        // PDFKit takes its own drawing of an annotation away when told the page's annotations changed.
        if sheafDocument.nativeChanges != before, let page = document?.page(at: index) { pdfView.annotationsChanged(on: page) }
        return result
    }

    func mouseUp() {
        guard let session = drag else { return }
        drag = nil
        if let page = document?.page(at: session.pageIndex) {
            if let preview = session.preview { page.removeAnnotation(preview) }
            if !session.draft.isDrawnSharply {
                session.hidden?.shouldDisplay = true
                if session.preview == nil, let original = session.original { session.hidden?.bounds = original.rect.cgRect }
            }
            pdfView.annotationsChanged(on: page)
        }
        // Back to how the document has things, until a change to it says otherwise.
        pdfView.refreshAnnotationViews()
        hideNativeMarks()
        pdfView.overlay.needsDisplay = true

        switch session.mode {
        case .creating:
            finishCreating(session)
        case .moving:
            guard session.didMove, let original = session.original, session.draft != original else { return }
            update(session.draft, pageIndex: session.pageIndex, name: String(localized: "Move"))
        case .resizing:
            guard session.didMove, let original = session.original, session.draft != original else { return }
            update(session.draft, pageIndex: session.pageIndex, name: String(localized: "Resize"))
        }
    }

    private func finishCreating(_ session: DragSession) {
        if let fieldTool = session.fieldTool {
            var rect = session.draft.rect
            if rect.width < 6 || rect.height < 6 {
                // A click without a drag makes a field of the usual size, its top left corner at the click.
                let size = fieldTool.defaultSize
                rect = PDFRectangle(x: session.start.x, y: session.start.y - size.height, width: size.width, height: size.height)
            }
            formTool = nil
            addField(fieldTool, rect: rect, pageIndex: session.pageIndex)
            return
        }
        if session.draft.kind == .redact {
            // A mark too small to be meant is dropped. The tool stays, since marks come in runs.
            guard session.draft.rect.width >= 3, session.draft.rect.height >= 3 else { return }
            add(session.draft, pageIndex: session.pageIndex, name: String(localized: "Mark for Redaction"))
            return
        }
        var annotation = session.draft
        let createdWith = tool
        // A click without a drag makes the thing at a sensible size where the click was.
        let isTiny = annotation.rect.width < 4 && annotation.rect.height < 4
        switch annotation.kind {
        case .line where isTiny:
            annotation.lineEnd = PDFPoint(x: session.start.x + 120, y: session.start.y)
            annotation.rect = PDFRectangle(from: session.start, to: annotation.lineEnd!)
        case .square, .circle:
            if isTiny { annotation.rect = PDFRectangle(x: session.start.x - 60, y: session.start.y - 40, width: 120, height: 80) }
        case .link:
            if isTiny { annotation.rect = PDFRectangle(x: session.start.x, y: session.start.y - 24, width: 140, height: 24) }
        case .freeText:
            let lineHeight = annotation.fontSize * 1.35 + 2 * Annotation.textPadding
            if isTiny {
                annotation.rect = PDFRectangle(x: session.start.x, y: session.start.y - lineHeight, width: 220, height: lineHeight)
            } else if annotation.rect.height < lineHeight {
                annotation.rect = PDFRectangle(x: annotation.rect.x, y: annotation.rect.y + annotation.rect.height - lineHeight, width: max(annotation.rect.width, 40), height: lineHeight)
            }
            // A text box only exists once it has text, so nothing is added to the document yet.
            beginTextEditing(annotation, pageIndex: session.pageIndex, isNew: true)
            return
        default:
            break
        }
        let name: String = switch createdWith {
        case .rectangle: String(localized: "Add Rectangle")
        case .ellipse: String(localized: "Add Ellipse")
        case .line: String(localized: "Add Line")
        case .arrow: String(localized: "Add Arrow")
        case .draw: String(localized: "Draw")
        case .link: String(localized: "Add Link")
        default: String(localized: "Add Annotation")
        }
        if !createdWith.staysActive { tool = .select }
        guard let id = add(annotation, pageIndex: session.pageIndex, name: name) else { return }
        // A stroke is usually followed by another; leaving it unselected keeps the pen free.
        if createdWith != .draw { selection = AnnotationSelection(pageIndex: session.pageIndex, id: id) }
        if createdWith == .link { isInspectorVisible = true }
    }

    /// Called when PDFKit finishes a text selection. With a text marking tool active, the
    /// selection becomes a highlight, underline or strikethrough.
    func textSelectionEnded() {
        guard let kind = tool.textMarkupKind else { return }
        applyTextMarkup(kind)
    }

    // MARK: Changing the document

    @discardableResult
    func add(_ annotation: Annotation, pageIndex: Int, name: String) -> ObjectID? {
        var stamped = annotation
        stamped.author = NSFullUserName()
        stamped.modified = now()
        return sheafDocument?.apply(name) { editor, effect in
            effect.pages = [pageIndex]
            return try editor.addAnnotation(stamped, toPageAt: pageIndex)
        }
    }

    private func update(_ annotation: Annotation, pageIndex: Int, name: String, coalescing key: String? = nil) {
        if annotation.subtype == "Widget", let id = annotation.objectID {
            // A form field's frame is the engine's to change, since its picture is redrawn to fit.
            sheafDocument?.apply(name, coalescing: key) { editor, effect in
                effect.pages = [pageIndex]
                try editor.setWidgetRect(id, to: annotation.rect)
            }
            return
        }
        var stamped = annotation
        stamped.modified = now()
        sheafDocument?.apply(name, coalescing: key) { editor, effect in
            effect.pages = [pageIndex]
            try editor.updateAnnotation(stamped, onPageAt: pageIndex)
        }
    }

    /// Changes the selected annotation, as the inspector and the style controls do.
    func updateSelection(_ name: String, coalescing key: String? = nil, _ change: (inout Annotation) -> Void) {
        guard let selection, var annotation = selectedAnnotation else { return }
        let before = annotation
        change(&annotation)
        guard annotation != before else { return }
        update(annotation, pageIndex: selection.pageIndex, name: name, coalescing: key.map { "\($0)-\(selection.id.number)" })
    }

    func deleteSelection() {
        guard let selection else { return }
        delete(selection)
    }

    func delete(_ target: AnnotationSelection) {
        let isField = sheafDocument?.annotation(target.id, onPage: target.pageIndex)?.subtype == "Widget"
        if selection == target { selection = nil }
        sheafDocument?.apply(isField ? String(localized: "Delete Field") : String(localized: "Delete")) { editor, effect in
            effect.pages = [target.pageIndex]
            if isField {
                try editor.removeWidget(target.id)
            } else {
                try editor.removeAnnotation(target.id, fromPageAt: target.pageIndex)
            }
        }
    }

    func nudgeSelection(dx: Double, dy: Double) {
        guard selectedAnnotation?.isTextMarkup == false else { return }
        updateSelection(String(localized: "Move"), coalescing: "nudge") { $0.translate(dx: dx, dy: dy) }
    }

    /// Turns the current text selection into a highlight, underline or strikethrough.
    func applyTextMarkup(_ kind: Annotation.Kind) {
        guard let textSelection = pdfView.currentSelection, let document, let sheafDocument, sheafDocument.isEditable else { return }
        var quads: [Int: [PDFRectangle]] = [:]
        for line in textSelection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                quads[document.index(for: page), default: []].append(PDFRectangle(bounds))
            }
        }
        guard !quads.isEmpty else { return }
        let tool: MarkupTool = kind == .underline ? .underline : kind == .strikeOut ? .strikeOut : .highlight
        let style = style(for: tool)
        let author = NSFullUserName(), date = now()
        let name: String = switch kind {
        case .underline: String(localized: "Underline")
        case .strikeOut: String(localized: "Strikethrough")
        default: String(localized: "Highlight")
        }
        sheafDocument.apply(name) { editor, effect in
            for (pageIndex, rects) in quads.sorted(by: { $0.key < $1.key }) {
                let points = rects.flatMap { [PDFPoint(x: $0.x, y: $0.y), PDFPoint(x: $0.x + $0.width, y: $0.y + $0.height)] }
                var annotation = Annotation(kind: kind, rect: PDFRectangle(enclosing: points) ?? rects[0])
                annotation.quads = rects
                annotation.color = style.color
                annotation.opacity = style.opacity
                annotation.author = author
                annotation.modified = date
                try editor.addAnnotation(annotation, toPageAt: pageIndex)
                effect.pages.insert(pageIndex)
            }
        }
        pdfView.clearSelection()
    }

    private func addNote(at point: PDFPoint, pageIndex: Int) {
        let size = Annotation.noteSize
        var note = Annotation(kind: .note, rect: PDFRectangle(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        note.color = style(for: .note).color
        tool = .select
        guard let id = add(note, pageIndex: pageIndex, name: String(localized: "Add Note")) else { return }
        selection = AnnotationSelection(pageIndex: pageIndex, id: id)
        isInspectorVisible = true
        focusCommentField()
    }

    /// Puts a stamp or signature in the middle of what is visible of the current page.
    func placeStamp(_ content: Annotation.StampContent, width: Double, aspectRatio: Double, color: PDFColor?, name: String) {
        guard let page = pdfView.currentPage, let document else { return }
        let pageBounds = page.bounds(for: .cropBox)
        let visible = pdfView.convert(pdfView.bounds, to: page).intersection(pageBounds)
        let area = visible.isNull || visible.isEmpty ? pageBounds : visible
        let stampWidth = min(width, pageBounds.width * 0.8)
        let height = stampWidth / max(aspectRatio, 0.05)
        var stamp = Annotation(kind: .stamp, rect: PDFRectangle(x: area.midX - stampWidth / 2, y: area.midY - height / 2, width: stampWidth, height: height))
        stamp.stamp = content
        stamp.color = color
        let pageIndex = document.index(for: page)
        tool = .select
        guard let id = add(stamp, pageIndex: pageIndex, name: name) else { return }
        selection = AnnotationSelection(pageIndex: pageIndex, id: id)
    }

    func addReply(_ text: String, to target: AnnotationSelection) {
        guard let parent = sheafDocument?.annotation(target.id, onPage: target.pageIndex) else { return }
        var reply = Annotation(kind: .note, rect: parent.rect)
        reply.contents = text
        reply.replyTo = target.id
        add(reply, pageIndex: target.pageIndex, name: String(localized: "Reply"))
    }

    /// Makes every annotation part of its page. Links stay links.
    func flattenAnnotations() {
        guard let sheafDocument else { return }
        let count = pageCount
        selection = nil
        sheafDocument.apply(String(localized: "Flatten Annotations")) { editor, effect in
            var flattened = 0
            for index in 0..<count { flattened += try editor.flattenAnnotations(onPageAt: index) }
            // Page content changed, which PDFKit only sees by reading the document again.
            effect.reloadsDisplay = flattened > 0
        }
    }

    // MARK: Text boxes

    func beginTextEditing(_ annotation: Annotation, pageIndex: Int, isNew: Bool) {
        pdfView.beginTextEditing(annotation, pageIndex: pageIndex, isNew: isNew)
        // The box shows in its editor only while it is typed in.
        pdfView.refreshAnnotationViews()
    }

    /// Stores what was typed into a text box.
    func commitText(_ text: String, annotation: Annotation, pageIndex: Int, isNew: Bool) {
        defer { pdfView.refreshAnnotationViews() }
        var edited = annotation
        edited.contents = text
        fitHeight(of: &edited)
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isNew {
            tool = .select
            guard !isBlank, let id = add(edited, pageIndex: pageIndex, name: String(localized: "Add Text")) else { return }
            selection = AnnotationSelection(pageIndex: pageIndex, id: id)
        } else if isBlank, let id = annotation.objectID {
            delete(AnnotationSelection(pageIndex: pageIndex, id: id))
        } else if edited != annotation {
            update(edited, pageIndex: pageIndex, name: String(localized: "Edit Text"))
        }
    }

    /// Grows a text box downwards until all its text fits.
    func fitHeight(of annotation: inout Annotation) {
        guard annotation.kind == .freeText else { return }
        let padding = Annotation.textPadding
        let inner = PDFRectangle(x: 0, y: 0, width: max(annotation.rect.width - 2 * padding, 1), height: 10)
        let needed = TextOutliner.outline(
            annotation.contents, fontName: annotation.fontName, fontSize: annotation.fontSize, in: inner, alignment: annotation.alignment
        ).height + 2 * padding + 2
        if needed > annotation.rect.height {
            annotation.rect = PDFRectangle(
                x: annotation.rect.x, y: annotation.rect.y + annotation.rect.height - needed, width: annotation.rect.width, height: needed
            )
        }
    }

    // MARK: Bookmarks

    var outline: [OutlineItem] {
        guard let sheafDocument else { return [] }
        _ = sheafDocument.revision
        return (try? sheafDocument.editor?.outline()) ?? []
    }

    private func setOutline(_ name: String, _ change: (inout [OutlineItem]) -> Void) {
        sheafDocument?.apply(name) { editor, _ in
            var items = try editor.outline()
            change(&items)
            try editor.setOutline(items)
        }
    }

    /// Adds a bookmark for the page being read.
    func addBookmark() {
        let index = currentPageIndex
        // Named after the first line of the page when it has one.
        let firstLine = document?.page(at: index)?.string?
            .split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let title = firstLine.isEmpty ? String(localized: "Page \(index + 1)") : String(firstLine.prefix(60))
        setOutline(String(localized: "Add Bookmark")) { $0.append(OutlineItem(title: title, pageIndex: index)) }
        showSidebar(.tableOfContents)
    }

    /// Finds an entry by its position: the index at each level, from the top down.
    func renameBookmark(at path: [Int], to title: String) {
        setOutline(String(localized: "Rename Bookmark")) { items in
            Self.modify(&items, at: path) { $0.title = title }
        }
    }

    func deleteBookmark(at path: [Int]) {
        setOutline(String(localized: "Delete Bookmark")) { items in
            guard let last = path.last else { return }
            if path.count == 1 {
                if items.indices.contains(last) { items.remove(at: last) }
            } else {
                Self.modify(&items, at: Array(path.dropLast())) { parent in
                    if parent.children.indices.contains(last) { parent.children.remove(at: last) }
                }
            }
        }
    }

    private static func modify(_ items: inout [OutlineItem], at path: [Int], _ change: (inout OutlineItem) -> Void) {
        guard let first = path.first, items.indices.contains(first) else { return }
        if path.count == 1 {
            change(&items[first])
        } else {
            modify(&items[first].children, at: Array(path.dropFirst()), change)
        }
    }

    // MARK: Keyboard

    /// Handles a key press on the page. Returns `false` to let PDFKit have it.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            guard selection != nil else { return false }
            deleteSelection()
        case 53: // escape
            guard selection != nil || tool != .select else { return false }
            selection = nil
            tool = .select
        case 36, 76: // return, enter
            guard let selection, let annotation = selectedAnnotation, annotation.kind == .freeText else { return false }
            beginTextEditing(annotation, pageIndex: selection.pageIndex, isNew: false)
        case 123 where selection != nil: nudgeSelection(dx: -step, dy: 0)
        case 124 where selection != nil: nudgeSelection(dx: step, dy: 0)
        case 125 where selection != nil: nudgeSelection(dx: 0, dy: -step)
        case 126 where selection != nil: nudgeSelection(dx: 0, dy: step)
        default: return false
        }
        return true
    }
}
