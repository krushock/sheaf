import AppKit
import PDFKit
import SheafKit
import SwiftUI

/// PDFKit's view, with the mouse and keyboard handling that editing annotations needs.
final class SheafPDFView: PDFView {
    weak var viewer: ViewerModel?
    let overlay = SelectionOverlay()

    private var isDraggingAnnotation = false
    private var scrollObserver: NSObjectProtocol?
    private var textSession: TextSession?

    private struct TextSession {
        var view: NSTextView
        var annotation: Annotation
        var pageIndex: Int
        var isNew: Bool
    }

    /// A form field being typed in.
    private var fieldSession: FieldSession?
    private var fieldPopover: NSPopover?
    private var menuHit: FieldHit?

    private struct FieldSession {
        var control: NSTextField
        var hit: FieldHit
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlay.pdfView = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SheafPDFView is created in code")
    }

    /// Redraws the selection frame as the page scrolls under it.
    func observeScrolling() {
        guard scrollObserver == nil, let clipView = subviews.compactMap({ $0 as? NSScrollView }).first?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A text box being typed in would be left behind by the page; finish it instead.
                self?.endTextEditing(commit: true)
                // A form field's editor follows its field, since moving to the next field scrolls.
                self?.repositionFieldEditor()
                self?.overlay.needsDisplay = true
            }
        }
    }

    // MARK: Mouse

    /// Where an event is, in the coordinates of the page under it.
    private func pagePoint(of event: NSEvent, onPage pageIndex: Int? = nil) -> (point: PDFPoint, pageIndex: Int)? {
        guard let document else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        if let pageIndex {
            guard let page = document.page(at: pageIndex) else { return nil }
            return (PDFPoint(convert(location, to: page)), pageIndex)
        }
        guard let page = page(for: location, nearest: false) else { return nil }
        return (PDFPoint(convert(location, to: page)), document.index(for: page))
    }

    override func mouseDown(with event: NSEvent) {
        endTextEditing(commit: true)
        endFieldEditing(commit: true)
        window?.makeFirstResponder(self)
        if let viewer, let place = pagePoint(of: event),
           viewer.mouseDown(at: place.point, pageIndex: place.pageIndex, clickCount: event.clickCount) {
            isDraggingAnnotation = true
            return
        }
        super.mouseDown(with: event)
        // PDFKit may track the whole drag inside the call above, so the selection can be
        // complete already. If not, `mouseUp` catches it.
        viewer?.textSelectionEnded()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingAnnotation else { return super.mouseDragged(with: event) }
        if let viewer, let session = viewer.drag, let place = pagePoint(of: event, onPage: session.pageIndex) {
            viewer.mouseDragged(to: place.point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingAnnotation else {
            super.mouseUp(with: event)
            viewer?.textSelectionEnded()
            return
        }
        isDraggingAnnotation = false
        viewer?.mouseUp()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let tool = viewer?.tool, tool != .select, tool.textMarkupKind == nil {
            addCursorRect(bounds, cursor: .crosshair)
        } else if viewer?.formTool != nil {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Keyboard and menus

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, viewer?.formTool != nil {
            viewer?.formTool = nil
            return
        }
        if viewer?.handleKeyDown(event) == true { return }
        if viewer?.handleFieldKey(event) == true { return }
        super.keyDown(with: event)
    }

    @objc func delete(_ sender: Any?) {
        viewer?.deleteSelection()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let viewer, let place = pagePoint(of: event), let hit = viewer.annotation(at: place.point, pageIndex: place.pageIndex),
              let id = hit.objectID, hit.kind != .other || (hit.subtype == "Widget" && viewer.isFormEditing)
        else { return super.menu(for: event) }
        viewer.selection = AnnotationSelection(pageIndex: place.pageIndex, id: id)
        let menu = NSMenu()
        if hit.kind == .freeText {
            menu.addItem(withTitle: String(localized: "Edit Text"), action: #selector(editSelectedText(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: String(localized: "Delete"), action: #selector(delete(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func editSelectedText(_ sender: Any?) {
        guard let viewer, let selection = viewer.selection, let annotation = viewer.selectedAnnotation else { return }
        viewer.beginTextEditing(annotation, pageIndex: selection.pageIndex, isNew: false)
    }

    // MARK: Typing in a text box

    func beginTextEditing(_ annotation: Annotation, pageIndex: Int, isNew: Bool) {
        endTextEditing(commit: true)
        guard let page = document?.page(at: pageIndex) else { return }
        let scale = scaleFactor
        let frame = convert(annotation.rect.cgRect, from: page)
        let textView = NSTextView(frame: frame)
        textView.string = annotation.contents
        textView.font = NSFont(name: annotation.fontName, size: annotation.fontSize * scale) ?? .systemFont(ofSize: annotation.fontSize * scale)
        textView.textColor = (annotation.color ?? .black).nsColor
        textView.alignment = annotation.alignment == .center ? .center : annotation.alignment == .right ? .right : .left
        textView.drawsBackground = true
        textView.backgroundColor = annotation.fillColor?.nsColor ?? NSColor.white.withAlphaComponent(0.9)
        textView.isRichText = false
        textView.allowsUndo = false
        // Match the text box's own padding, so the text does not jump when editing ends.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: Annotation.textPadding * scale, height: Annotation.textPadding * scale)
        textView.isVerticallyResizable = true
        textView.minSize = frame.size
        textView.delegate = self
        textView.wantsLayer = true
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.layer?.borderWidth = 1
        addSubview(textView)
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
        textSession = TextSession(view: textView, annotation: annotation, pageIndex: pageIndex, isNew: isNew)
        overlay.needsDisplay = true
    }

    func endTextEditing(commit: Bool) {
        guard let session = textSession else { return }
        textSession = nil
        let text = session.view.string
        session.view.delegate = nil
        session.view.removeFromSuperview()
        window?.makeFirstResponder(self)
        viewer?.commitText(commit ? text : session.annotation.contents, annotation: session.annotation, pageIndex: session.pageIndex, isNew: session.isNew)
    }

    var isEditingText: Bool { textSession != nil }

    // MARK: Filling in form fields

    /// The size, in points on the page, that a field's text is shown at.
    private func fontSize(for hit: FieldHit) -> Double {
        if hit.field.fontSize > 0 { return hit.field.fontSize }
        return hit.field.isMultiline ? 12 : min(12, max(4, (hit.widget.rect.height - 2) * 0.72))
    }

    private func editorFrame(for hit: FieldHit, font: NSFont) -> CGRect? {
        guard let page = document?.page(at: hit.pageIndex) else { return nil }
        let frame = convert(hit.widget.rect.cgRect, from: page)
        guard !hit.field.isMultiline else { return frame }
        // One line, centered in the field's height as the saved text will be.
        let height = min(ceil(font.ascender - font.descender + font.leading) + 4, frame.height)
        return CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
    }

    /// Puts a text editor over a field.
    func beginFieldEditing(_ hit: FieldHit) {
        endTextEditing(commit: true)
        endFieldEditing(commit: true)
        let field = hit.field
        let size = fontSize(for: hit) * scaleFactor
        let font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        guard let frame = editorFrame(for: hit, font: font) else { return }
        let control: NSTextField = field.isPassword ? NSSecureTextField(frame: frame) : NSTextField(frame: frame)
        control.stringValue = field.value
        control.font = font
        control.textColor = field.textColor.nsColor
        control.backgroundColor = .white
        control.drawsBackground = true
        control.isBordered = false
        control.focusRingType = .none
        control.alignment = field.alignment == .center ? .center : field.alignment == .right ? .right : .left
        control.usesSingleLineMode = !field.isMultiline
        control.cell?.wraps = field.isMultiline
        control.cell?.isScrollable = !field.isMultiline
        control.wantsLayer = true
        control.layer?.borderColor = NSColor.controlAccentColor.cgColor
        control.layer?.borderWidth = 1.5
        control.delegate = self
        control.setAccessibilityLabel(field.label ?? field.name)
        addSubview(control)
        window?.makeFirstResponder(control)
        fieldSession = FieldSession(control: control, hit: hit)
        viewer?.focusedWidget = hit.widget.id
        overlay.needsDisplay = true
    }

    func endFieldEditing(commit: Bool) {
        guard let session = fieldSession else { return }
        fieldSession = nil
        let text = session.control.stringValue
        session.control.delegate = nil
        session.control.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit { viewer?.setValue(text, of: session.hit.field) }
        overlay.needsDisplay = true
    }

    var isEditingField: Bool { fieldSession != nil }

    private func repositionFieldEditor() {
        guard let session = fieldSession, let font = session.control.font, let frame = editorFrame(for: session.hit, font: font) else { return }
        session.control.frame = frame
    }

    /// Where a field is in this view, for attaching menus and popovers to it.
    private func viewFrame(of hit: FieldHit) -> CGRect? {
        document?.page(at: hit.pageIndex).map { convert(hit.widget.rect.cgRect, from: $0) }
    }

    /// Shows a dropdown's options as a menu under the field.
    func showOptions(for hit: FieldHit) {
        guard let frame = viewFrame(of: hit) else { return }
        let menu = NSMenu()
        var current: NSMenuItem?
        for option in hit.field.options {
            let item = NSMenuItem(title: option.title, action: #selector(chooseOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.value
            if option.value == hit.field.value {
                item.state = .on
                current = item
            }
            menu.addItem(item)
        }
        if !hit.field.value.isEmpty || hit.field.isEditable { menu.addItem(.separator()) }
        if hit.field.isEditable {
            let other = NSMenuItem(title: String(localized: "Other…"), action: #selector(typeOption(_:)), keyEquivalent: "")
            other.target = self
            menu.addItem(other)
        }
        if !hit.field.value.isEmpty {
            let none = NSMenuItem(title: String(localized: "None"), action: #selector(chooseOption(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = ""
            menu.addItem(none)
        }
        menuHit = hit
        menu.minimumWidth = frame.width
        menu.popUp(positioning: current, at: NSPoint(x: frame.minX, y: current == nil ? frame.minY : frame.maxY), in: self)
    }

    @objc private func chooseOption(_ sender: NSMenuItem) {
        guard let hit = menuHit, let value = sender.representedObject as? String else { return }
        viewer?.setValue(value, of: hit.field)
    }

    @objc private func typeOption(_ sender: NSMenuItem) {
        if let hit = menuHit { beginFieldEditing(hit) }
    }

    /// Shows a calendar for a date field.
    func showDatePicker(for hit: FieldHit) {
        guard let viewer, let format = hit.field.dateFormat else { return }
        let picker = DateFieldPicker(date: hit.field.dateValue ?? .now, hasValue: !hit.field.value.isEmpty) { [weak self, weak viewer] date in
            viewer?.setValue(date.map { FormDate.string(from: $0, format: format) } ?? "", of: hit.field)
            self?.closeFieldPopover()
        }
        show(NSHostingController(rootView: picker), for: hit)
    }

    /// Shows the saved signatures, to put one in a signature field.
    func showSignatures(for hit: FieldHit) {
        guard let viewer else { return }
        show(NSHostingController(rootView: SignaturePicker(viewer: viewer)), for: hit)
    }

    private func show(_ controller: NSViewController, for hit: FieldHit) {
        closeFieldPopover()
        guard let frame = viewFrame(of: hit) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: frame, of: self, preferredEdge: .minY)
        fieldPopover = popover
    }

    func closeFieldPopover() {
        fieldPopover?.close()
        fieldPopover = nil
    }

    #if DEBUG
    /// Stands in for typing, when the app is driven from the command line.
    func debugType(_ text: String) {
        textSession?.view.string = text
        fieldSession?.control.stringValue = text
    }
    #endif
}

extension SheafPDFView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let session = fieldSession, session.control === control else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if session.hit.field.isMultiline {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                endFieldEditing(commit: true)
            }
        case #selector(NSResponder.insertTab(_:)):
            endFieldEditing(commit: true)
            viewer?.focusNextField()
        case #selector(NSResponder.insertBacktab(_:)):
            endFieldEditing(commit: true)
            viewer?.focusNextField(backwards: true)
        case #selector(NSResponder.cancelOperation(_:)):
            endFieldEditing(commit: false)
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let session = fieldSession, let limit = session.hit.field.maxLength, session.control.stringValue.count > limit else { return }
        session.control.stringValue = String(session.control.stringValue.prefix(limit))
        NSSound.beep()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endFieldEditing(commit: true)
    }
}

extension SheafPDFView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape keeps what was typed, as in Pages; only an empty box disappears.
            endTextEditing(commit: true)
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        endTextEditing(commit: true)
    }
}

/// Draws the frame and handles of the selected annotation, on top of the pages.
final class SelectionOverlay: NSView {
    weak var pdfView: SheafPDFView?

    // Clicks go to the pages underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let viewer = pdfView.viewer, let document = pdfView.document else { return }
        drawFields(of: viewer, in: pdfView, document: document)

        guard !pdfView.isEditingText, let geometry = viewer.selectionGeometry, let page = document.page(at: geometry.pageIndex) else { return }
        let frame = pdfView.convert(geometry.frame.cgRect, from: page).insetBy(dx: -0.5, dy: -0.5)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: frame)
        outline.lineWidth = 1
        outline.stroke()

        for (_, point) in geometry.handles {
            let center = pdfView.convert(point.cgPoint, from: page)
            let handle = NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }

    /// Tints the form fields on the pages in view, and rings the one that has the keyboard.
    private func drawFields(of viewer: ViewerModel, in pdfView: SheafPDFView, document: PDFDocument) {
        let fields = viewer.formFields
        guard !fields.isEmpty else { return }
        let visible = Set(pdfView.visiblePages.map { document.index(for: $0) })
        let isBuilding = viewer.isFormEditing
        for field in fields {
            for widget in field.widgets where !widget.isHidden {
                guard let pageIndex = widget.pageIndex, visible.contains(pageIndex), let page = document.page(at: pageIndex) else { continue }
                let frame = pdfView.convert(widget.rect.cgRect, from: page)
                guard frame.intersects(bounds) else { continue }
                if isBuilding {
                    // While building, every field shows its frame, filled in or not.
                    NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
                    frame.fill()
                    NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
                    let outline = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
                    outline.lineWidth = 1
                    outline.stroke()
                } else if viewer.highlightsFields, field.isFillable, field.kind != .signature {
                    // The same tint Preview gives fields, so they are easy to find.
                    NSColor(srgbRed: 0.25, green: 0.45, blue: 0.95, alpha: 0.105).setFill()
                    frame.fill()
                }
                if !isBuilding, widget.id == viewer.focusedWidget, !pdfView.isEditingField {
                    NSColor.keyboardFocusIndicatorColor.setStroke()
                    let ring = NSBezierPath(roundedRect: frame.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3)
                    ring.lineWidth = 2
                    ring.stroke()
                }
            }
        }
    }
}
