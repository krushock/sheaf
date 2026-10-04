import AppKit
import PDFKit
import SheafKit

/// The kinds of field the form tools make.
enum FormTool: String, CaseIterable, Identifiable {
    case text, checkbox, radio, dropdown, date, signature

    var id: Self { self }

    var title: String {
        switch self {
        case .text: String(localized: "Text Field")
        case .checkbox: String(localized: "Checkbox")
        case .radio: String(localized: "Radio Button")
        case .dropdown: String(localized: "Dropdown")
        case .date: String(localized: "Date Field")
        case .signature: String(localized: "Signature Field")
        }
    }

    var systemImage: String {
        switch self {
        case .text: "character.cursor.ibeam"
        case .checkbox: "checkmark.square"
        case .radio: "largecircle.fill.circle"
        case .dropdown: "chevron.up.chevron.down.square"
        case .date: "calendar"
        case .signature: "signature"
        }
    }

    var kind: FormField.Kind {
        switch self {
        case .text, .date: .text
        case .checkbox: .checkbox
        case .radio: .radio
        case .dropdown: .dropdown
        case .signature: .signature
        }
    }

    /// The name a new field of this kind starts with.
    var baseName: String {
        switch self {
        case .text: String(localized: "Text")
        case .checkbox: String(localized: "Checkbox")
        case .radio: String(localized: "Choice")
        case .dropdown: String(localized: "Dropdown")
        case .date: String(localized: "Date")
        case .signature: String(localized: "Signature")
        }
    }

    /// The size a click without a drag makes.
    var defaultSize: (width: Double, height: Double) {
        switch self {
        case .text, .dropdown: (180, 22)
        case .date: (110, 22)
        case .checkbox, .radio: (14, 14)
        case .signature: (200, 48)
        }
    }
}

/// A field and the one of its widgets that is meant.
struct FieldHit {
    var field: FormField
    var widget: FormField.Widget
    var pageIndex: Int
}

/// Filling in forms, and building them.
extension ViewerModel {
    // MARK: Fields

    /// The document's form fields. Read once per change to the document.
    var formFields: [FormField] {
        guard let sheafDocument, let editor = sheafDocument.editor else { return [] }
        if let cache = fieldCache, cache.revision == sheafDocument.revision, cache.generation == sheafDocument.generation {
            return cache.fields
        }
        let fields = (try? editor.formFields()) ?? []
        fieldCache = (sheafDocument.revision, sheafDocument.generation, fields)
        return fields
    }

    var hasForm: Bool { !formFields.isEmpty }

    /// The field whose widget is under a point.
    func field(at point: PDFPoint, pageIndex: Int) -> FieldHit? {
        for field in formFields.reversed() {
            if let widget = field.widgets.last(where: { $0.pageIndex == pageIndex && !$0.isHidden && $0.rect.contains(point) }) {
                return FieldHit(field: field, widget: widget, pageIndex: pageIndex)
            }
        }
        return nil
    }

    func field(forWidget id: ObjectID) -> FieldHit? {
        for field in formFields {
            if let widget = field.widgets.first(where: { $0.id == id }), let pageIndex = widget.pageIndex {
                return FieldHit(field: field, widget: widget, pageIndex: pageIndex)
            }
        }
        return nil
    }

    /// The field picked for editing with the form tools.
    var selectedField: FieldHit? {
        guard let selection else { return nil }
        _ = sheafDocument?.revision
        return field(forWidget: selection.id)
    }

    /// Fields in the order Tab moves through them: page by page, as each page lists them.
    private var fillOrder: [FieldHit] {
        var hits: [FieldHit] = []
        for field in formFields where field.isFillable && field.kind != .signature {
            for widget in field.widgets where !widget.isHidden {
                if let pageIndex = widget.pageIndex { hits.append(FieldHit(field: field, widget: widget, pageIndex: pageIndex)) }
            }
        }
        // The order widgets have on their page is the order the form's author gave them.
        var position: [ObjectID: Int] = [:]
        for pageIndex in Set(hits.map(\.pageIndex)) {
            for (offset, annotation) in ((try? sheafDocument?.editor?.annotations(onPageAt: pageIndex)) ?? []).enumerated() {
                if let id = annotation.objectID { position[id] = offset }
            }
        }
        return hits.sorted { ($0.pageIndex, position[$0.widget.id] ?? 0) < ($1.pageIndex, position[$1.widget.id] ?? 0) }
    }

    func formEditingDidToggle() {
        pdfView.endFieldEditing(commit: true)
        focusedWidget = nil
        formTool = nil
        selection = nil
        if isFormEditing {
            isMarkupVisible = false
            isContentEditing = false
            isInspectorVisible = true
        }
        pdfView.overlay.needsDisplay = true
    }

    // MARK: Filling

    /// What a click on a field does while filling in the form.
    func activate(_ hit: FieldHit) {
        guard hit.field.isFillable else { return }
        focusedWidget = hit.widget.id
        switch hit.field.kind {
        case .text:
            if hit.field.dateFormat != nil {
                pdfView.showDatePicker(for: hit)
            } else {
                pdfView.beginFieldEditing(hit)
            }
        case .checkbox, .radio:
            toggle(hit)
        case .dropdown, .list:
            pdfView.showOptions(for: hit)
        case .signature:
            signatureTarget = (hit.pageIndex, hit.widget.rect)
            pdfView.showSignatures(for: hit)
        case .button:
            break
        }
    }

    func toggle(_ hit: FieldHit) {
        // A radio button that is on stays on when clicked; a checkbox goes off.
        let turnsOn = hit.field.kind == .radio ? true : !hit.widget.isOn
        guard turnsOn != hit.widget.isOn else { return }
        sheafDocument?.apply(turnsOn ? String(localized: "Check") : String(localized: "Uncheck")) { editor, effect in
            effect.pages = Set(hit.field.widgets.compactMap(\.pageIndex))
            try editor.setButton(hit.widget.id, on: turnsOn)
        }
    }

    func setValue(_ value: String, of field: FormField) {
        guard value != field.value else { return }
        sheafDocument?.apply(String(localized: "Fill In Field")) { editor, effect in
            effect.pages = Set(field.widgets.compactMap(\.pageIndex))
            try editor.setFieldValue(field.id, to: value)
        }
    }

    /// Moves the keyboard to the field after, or before, the one that has it.
    func focusNextField(backwards: Bool = false) {
        let order = fillOrder
        guard !order.isEmpty else { return }
        let current = order.firstIndex { $0.widget.id == focusedWidget }
        let next = current.map { ($0 + (backwards ? -1 : 1) + order.count) % order.count } ?? (backwards ? order.count - 1 : 0)
        let hit = order[next]
        focusedWidget = hit.widget.id
        if let page = document?.page(at: hit.pageIndex) {
            pdfView.go(to: hit.widget.rect.cgRect.insetBy(dx: -40, dy: -80), on: page)
        }
        // Text is ready to type in at once; other kinds wait for Space.
        if hit.field.kind == .text, hit.field.dateFormat == nil {
            DispatchQueue.main.async { [weak self] in self?.pdfView.beginFieldEditing(hit) }
        }
    }

    /// Keys that act on the field that has the keyboard. Returns `false` for keys it has no use for.
    func handleFieldKey(_ event: NSEvent) -> Bool {
        guard !isFormEditing else { return false }
        switch event.keyCode {
        case 48: // tab
            guard hasForm else { return false }
            focusNextField(backwards: event.modifierFlags.contains(.shift))
        case 49, 36, 76: // space, return, enter
            guard let focusedWidget, let hit = field(forWidget: focusedWidget) else { return false }
            activate(hit)
        case 53: // escape
            guard focusedWidget != nil else { return false }
            focusedWidget = nil
        default:
            return false
        }
        return true
    }

    func resetForm() {
        pdfView.endFieldEditing(commit: false)
        let pages = Set(formFields.flatMap { $0.widgets.compactMap(\.pageIndex) })
        sheafDocument?.apply(String(localized: "Reset Form")) { editor, effect in
            effect.pages = pages
            try editor.resetForm()
        }
    }

    func flattenForm() {
        pdfView.endFieldEditing(commit: true)
        selection = nil
        focusedWidget = nil
        sheafDocument?.apply(String(localized: "Flatten Form")) { editor, effect in
            effect.reloadsDisplay = true
            effect.pages = Set(0..<(try editor.pageCount()))
            try editor.flattenForm()
        }
    }

    // MARK: Building

    /// Adds a field where a form tool was dragged or clicked.
    func addField(_ tool: FormTool, rect: PDFRectangle, pageIndex: Int) {
        var new = NewField(kind: tool.kind, name: tool.baseName, rect: rect)
        if tool == .date { new.dateFormat = FormDate.standardFormat }
        if tool == .dropdown {
            new.options = [FormField.Option(value: String(localized: "Option 1")), FormField.Option(value: String(localized: "Option 2"))]
        }
        new.isMultiline = tool == .text && rect.height > 40
        // Another radio button joins the group of the one that is selected, if one is.
        if tool == .radio, let current = selectedField?.field, current.kind == .radio { new.name = current.fullName }
        let made = sheafDocument?.apply(String(localized: "Add \(tool.title)")) { editor, effect in
            effect.pages = [pageIndex]
            return try editor.addField(new, toPageAt: pageIndex)
        }
        if let made { selection = AnnotationSelection(pageIndex: pageIndex, id: made) }
        isInspectorVisible = true
    }

    /// Changes the selected field's properties, as the inspector does.
    func updateSelectedField(_ name: String, coalescing key: String? = nil, _ change: (inout FormField) -> Void) {
        guard let hit = selectedField else { return }
        var field = hit.field
        change(&field)
        guard field != hit.field else { return }
        sheafDocument?.apply(name, coalescing: key.map { "\($0)-\(field.id.number)" }) { editor, effect in
            effect.pages = Set(field.widgets.compactMap(\.pageIndex))
            try editor.updateField(field)
        }
    }

    func setDefaultValue(_ value: String) {
        guard let field = selectedField?.field else { return }
        setValue(value, of: field)
        updateSelectedField(String(localized: "Change Default")) { $0.defaultValue = value.isEmpty ? nil : value }
    }

    /// Looks for boxes and lines drawn to be filled in on the current page, and makes
    /// fields of them.
    func detectFields() {
        guard let sheafDocument, let editor = sheafDocument.editor, let page = document?.page(at: currentPageIndex) else { return }
        let pageIndex = currentPageIndex
        var candidates = (try? editor.detectFieldCandidates(onPageAt: pageIndex)) ?? []

        // Runs of underscores typed as text, as in "Name: ________".
        let text = page.string ?? ""
        if let pattern = try? NSRegularExpression(pattern: "_{4,}") {
            let existing = formFields.flatMap(\.widgets).filter { $0.pageIndex == pageIndex }.map(\.rect.cgRect)
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                guard let bounds = page.selection(for: match.range)?.bounds(for: page), bounds.width > 20 else { continue }
                let rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(bounds.height, 14))
                if existing.contains(where: { $0.intersects(rect) }) || candidates.contains(where: { $0.rect.cgRect.intersects(rect) }) { continue }
                candidates.append(FieldCandidate(kind: .text, rect: PDFRectangle(rect)))
            }
        }
        // A box with printed text in it is a table cell or a heading, not a place to write.
        candidates = candidates.filter { candidate in
            let inside = page.selection(for: candidate.rect.cgRect.insetBy(dx: 1.5, dy: 1.5))?.string ?? ""
            return inside.allSatisfy { $0 == "_" || $0.isWhitespace }
        }
        guard !candidates.isEmpty else {
            detectionMessage = String(localized: "No boxes or lines to fill in were found on this page.")
            return
        }

        // Each field is named after the words printed to its left, or above it.
        let names = candidates.map { candidate -> String in
            let rect = candidate.rect.cgRect
            let left = CGRect(x: max(rect.minX - 220, 0), y: rect.minY, width: min(220, rect.minX), height: rect.height)
            let above = CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 16)
            let right = CGRect(x: rect.maxX, y: rect.minY - 2, width: 200, height: rect.height + 4)
            // A checkbox's words usually follow it.
            let places = candidate.kind == .checkbox ? [right, left] : [left, above]
            for place in places {
                let found = (page.selection(for: place)?.string ?? "")
                    .components(separatedBy: .newlines).last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :_\t.*"))  ?? ""
                if found.count >= 2 { return String(found.suffix(40)) }
            }
            return candidate.kind == .checkbox ? FormTool.checkbox.baseName : FormTool.text.baseName
        }

        let made = sheafDocument.apply(String(localized: "Detect Fields")) { editor, effect -> Int in
            effect.pages = [pageIndex]
            for (candidate, name) in zip(candidates, names) {
                var new = NewField(kind: candidate.kind, name: name, rect: candidate.rect)
                new.isMultiline = candidate.isMultiline
                // The page already draws the box or the line.
                new.hasBorder = false
                try editor.addField(new, toPageAt: pageIndex)
            }
            return candidates.count
        }
        if let made {
            detectionMessage = made == 1 ? String(localized: "1 field was added to this page.") : String(localized: "\(made) fields were added to this page.")
        }
    }
}
