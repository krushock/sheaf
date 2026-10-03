import PDFKit
import SheafKit

/// Keeps PDFKit's annotations in step with the document's.
///
/// PDFKit shows the annotations it read from the file. When the document changes, the
/// annotations that changed are swapped for `SheafAnnotation`s, which draw exactly what
/// will be saved. Untouched annotations stay as PDFKit made them.
struct AnnotationDisplay {
    private struct Shown {
        var id: ObjectID?
        var annotation: PDFAnnotation
        var model: Annotation?
    }

    /// The document as it was when PDFKit last read it.
    private var base: PDFEditor?
    private var pages: [Int: [Shown]] = [:]
    /// PDFKit's own annotation objects, kept so that undoing a deletion can bring one back.
    private var originals: [ObjectID: PDFAnnotation] = [:]
    /// The small documents that changed annotations were read from. An annotation draws
    /// from the document it came out of, so each has to stay alive as long as its annotation.
    private var sources: [ObjectIdentifier: PDFDocument] = [:]

    nonisolated init() {}

    init(base: PDFEditor) {
        self.base = base
    }

    /// Pairs up a page's PDFKit annotations with the document's, the first time the page matters.
    private mutating func shown(page index: Int, of pdf: PDFDocument) -> [Shown] {
        if let existing = pages[index] { return existing }
        guard let page = pdf.page(at: index) else { return [] }
        let models = (try? base?.annotations(onPageAt: index)) ?? []
        let annotations = page.annotations
        var result: [Shown]
        if models.count == annotations.count {
            // Both list the page's annotations in file order.
            result = zip(annotations, models).map { Shown(id: $1.objectID, annotation: $0, model: $1) }
        } else {
            // PDFKit added or dropped something. Match what can be matched by type and place.
            var unused = models
            result = annotations.map { annotation in
                let match = unused.firstIndex { model in
                    model.subtype.rawValue == annotation.type && abs(model.rect.x - annotation.bounds.minX) < 2 && abs(model.rect.y - annotation.bounds.minY) < 2
                }
                let model = match.map { unused.remove(at: $0) }
                return Shown(id: model?.objectID, annotation: annotation, model: model)
            }
        }
        for entry in result {
            if let id = entry.id { originals[id] = entry.annotation }
        }
        pages[index] = result
        return result
    }

    mutating func objectID(of annotation: PDFAnnotation, page index: Int, of pdf: PDFDocument) -> ObjectID? {
        shown(page: index, of: pdf).first { $0.annotation === annotation }?.id
    }

    mutating func annotation(for id: ObjectID, page index: Int, of pdf: PDFDocument) -> PDFAnnotation? {
        shown(page: index, of: pdf).first { $0.id == id }?.annotation
    }

    /// Makes one page of PDFKit's document show the annotations the editor has for it.
    mutating func sync(page index: Int, of pdf: PDFDocument, with editor: PDFEditor) {
        guard let page = pdf.page(at: index) else { return }
        let current = shown(page: index, of: pdf)
        let models = (try? editor.annotations(onPageAt: index)) ?? []
        let byID = Dictionary(current.compactMap { entry in entry.id.map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })

        // Annotations that are not separate objects cannot be edited; they stay in front.
        var next = current.filter { $0.id == nil }
        var remadeWidgets: [(annotation: PDFAnnotation, id: ObjectID)] = []
        for model in models {
            guard let id = model.objectID else { continue }
            if let existing = byID[id], existing.model == model {
                next.append(existing)
            } else {
                let annotation = displayAnnotation(for: model, pageIndex: index, in: pdf, editor: editor)
                next.append(Shown(id: id, annotation: annotation, model: model))
                if model.subtype == "Widget" { remadeWidgets.append((annotation, id)) }
            }
        }

        // PDFKit can only append, so a changed order means putting them all back in order.
        if next.count != page.annotations.count || !zip(next, page.annotations).allSatisfy({ $0.annotation === $1 }) {
            for annotation in page.annotations { page.removeAnnotation(annotation) }
            for entry in next { page.addAnnotation(entry.annotation) }
        }
        pages[index] = next
        applyFieldStates(to: remadeWidgets, editor: editor)
        // Documents whose annotation is no longer shown anywhere can go.
        let live = Set(pages.values.flatMap { $0.map { ObjectIdentifier($0.annotation) } })
        sources = sources.filter { live.contains($0.key) }
    }

    /// PDFKit keeps one value per field name for a whole document, and gives it to a widget
    /// that joins a page. So a widget made afresh is told its state again once it is there.
    private func applyFieldStates(to widgets: [(annotation: PDFAnnotation, id: ObjectID)], editor: PDFEditor) {
        guard !widgets.isEmpty, let fields = try? editor.formFields() else { return }
        var turnedOn: [PDFAnnotation] = []
        for (annotation, id) in widgets {
            guard let field = fields.first(where: { field in field.widgets.contains { $0.id == id } }),
                  let widget = field.widgets.first(where: { $0.id == id })
            else { continue }
            switch field.kind {
            case .checkbox, .radio:
                if widget.isOn {
                    turnedOn.append(annotation)
                } else if annotation.buttonWidgetState != .offState {
                    annotation.buttonWidgetState = .offState
                }
            case .text, .dropdown, .list:
                let shown = field.kind == .text ? field.value : field.displayValue
                if (annotation.widgetStringValue ?? "") != shown { annotation.widgetStringValue = shown }
            case .signature, .button:
                break
            }
        }
        // Last, so that turning one radio button on is not undone by turning its neighbor off.
        for annotation in turnedOn where annotation.buttonWidgetState != .onState { annotation.buttonWidgetState = .onState }
    }

    /// An annotation as PDFKit reads it from the document's own bytes for it. Drawn by
    /// PDFKit like any annotation in a file, it is sharp at every zoom and looks as it
    /// will when the saved document is opened again.
    static func nativeAnnotation(for id: ObjectID, pageIndex: Int, editor: PDFEditor) -> (annotation: PDFAnnotation, source: PDFDocument)? {
        guard let data = try? editor.annotationDocument(for: id, onPageAt: pageIndex), let source = PDFDocument(data: data),
              let page = source.page(at: 0), let annotation = page.annotations.first
        else { return nil }
        page.removeAnnotation(annotation)
        return (annotation, source)
    }

    private mutating func displayAnnotation(for model: Annotation, pageIndex: Int, in pdf: PDFDocument, editor: PDFEditor) -> PDFAnnotation {
        // A link shows nothing; it only needs to lead to the right place in this document.
        if model.kind == .link { return SheafAnnotation(model: model, document: pdf) }
        if let id = model.objectID, let native = Self.nativeAnnotation(for: id, pageIndex: pageIndex, editor: editor) {
            sources[ObjectIdentifier(native.annotation)] = native.source
            return native.annotation
        }
        // PDFKit could not read it back. Fall back on drawing it here.
        if model.appearance() != nil { return SheafAnnotation(model: model, document: pdf) }
        if let id = model.objectID, let original = originals[id] {
            original.bounds = CGRect(x: model.rect.x, y: model.rect.y, width: model.rect.width, height: model.rect.height)
            original.contents = model.contents
            return original
        }
        let stored = model.objectID.flatMap { try? editor.storedAppearancePreview(of: $0) }
        return SheafAnnotation(model: model, document: pdf, storedPreview: stored)
    }
}

/// An annotation drawn from the same instructions that are saved in the file, so what is
/// on screen while editing is what the saved document shows.
nonisolated final class SheafAnnotation: PDFAnnotation {
    private let lock = NSLock()
    // PDFKit may draw pages on background threads, so these are only touched under the lock.
    nonisolated(unsafe) private var preview: CGPDFDocument?
    /// Text marks are left to PDFKit to draw.
    private let drawsNatively: Bool

    init(model: Annotation, document: PDFDocument?, storedPreview: Data? = nil) {
        // Links keep their type so that PDFKit follows them when clicked. Highlights,
        // underlines and strikethroughs keep theirs because PDFKit draws annotations on a
        // layer above the page, where only its own drawing can blend with the text below;
        // it also draws them itself in any saved file, so this is how they will look anyway.
        // Everything else uses a neutral type, so PDFKit adds no drawing or pop-ups of its own.
        let type: PDFAnnotationSubtype = switch model.kind {
        case .link: .link
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        default: .stamp
        }
        drawsNatively = model.isTextMarkup
        super.init(bounds: Self.frame(of: model), forType: type, withProperties: nil)
        update(model, document: document, storedPreview: storedPreview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SheafAnnotation is never archived")
    }

    static func frame(of model: Annotation) -> CGRect {
        let bounds = model.appearance()?.bounds ?? model.rect
        return CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }

    /// - Parameter storedPreview: What to draw when the model cannot describe its own look.
    ///   Left alone when `nil` and the model has no look of its own, so a drag keeps the picture.
    func update(_ model: Annotation, document: PDFDocument?, storedPreview: Data? = nil) {
        if let data = model.appearance()?.previewPDF() ?? storedPreview {
            let parsed = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
            lock.withLock { preview = parsed }
        }
        let frame = Self.frame(of: model)
        bounds = frame
        // PDFKit puts a comment bubble next to anything that has contents, even empty ones.
        contents = model.contents.isEmpty ? nil : model.contents
        if drawsNatively {
            color = (model.color ?? .yellow).nsColor.withAlphaComponent(model.opacity)
            // Four corners per line, relative to the annotation's own corner.
            quadrilateralPoints = model.quads.flatMap { quad -> [NSValue] in
                let (left, right) = (quad.x - frame.minX, quad.x + quad.width - frame.minX)
                let (bottom, top) = (quad.y - frame.minY, quad.y + quad.height - frame.minY)
                return [NSPoint(x: left, y: top), NSPoint(x: right, y: top), NSPoint(x: left, y: bottom), NSPoint(x: right, y: bottom)]
                    .map(NSValue.init(point:))
            }
        }
        switch model.link {
        case .url(let text): url = URL(string: text)
        case .page(let index):
            if let page = document?.page(at: index) {
                destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY))
            }
        case nil: break
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if drawsNatively {
            super.draw(with: box, in: context)
            return
        }
        guard let page = lock.withLock({ preview })?.page(at: 1) else { return }
        // The preview's page is the annotation's frame, so it is stretched onto wherever
        // the frame is now. That also makes a drag follow the mouse without redrawing.
        let frame = bounds, size = page.getBoxRect(.mediaBox).size
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        context.scaleBy(x: frame.width / size.width, y: frame.height / size.height)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
