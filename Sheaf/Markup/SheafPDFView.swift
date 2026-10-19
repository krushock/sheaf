import AppKit
import PDFKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// PDFKit's view, with the mouse and keyboard handling that editing annotations needs.
final class SheafPDFView: PDFView {
    weak var viewer: ViewerModel?
    let overlay = SelectionOverlay()

    private var isDraggingAnnotation = false
    /// The views that draw annotations over the pages in view.
    let annotationViews = NSHashTable<PageAnnotationView>.weakObjects()
    private var displayObservers: [NSObjectProtocol] = []
    private var scrollObserver: NSObjectProtocol?
    private var lastScrollOrigin = CGPoint.zero
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

    /// Text on a page being typed in: a block that is there, or new text.
    private var contentSession: ContentSession?

    nonisolated(unsafe) private static var keeperKey = 0

    private struct ContentSession {
        var view: NSTextView
        var pageIndex: Int
        /// The block being changed. `nil` for new text.
        var block: TextBlock?
        /// The top left corner of new text, on the page as displayed.
        var origin: PDFPoint
        var style: NewTextStyle
        /// The edge that stays put as the editor grows, in this view.
        var top: CGFloat
        var minimumHeight: CGFloat
        /// Whether the editor was made narrower or wider by hand, which sets the width
        /// the text is fitted to when it is kept.
        var isResized = false
    }

    /// A side of the text editor being dragged, with where the drag began and the frame it began with.
    private var editorResize: (isLeft: Bool, startX: CGFloat, frame: CGRect)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlay.pdfView = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        pageOverlayViewProvider = self
        // Annotations are drawn again at once when the document changes, and soon after the zoom does.
        displayObservers.append(NotificationCenter.default.addObserver(forName: SheafDocument.didChangeDisplay, object: nil, queue: nil) { [weak self] note in
            // Which document it was is told apart by identity alone, which is safe to carry across.
            let changed = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let document = self.viewer?.sheafDocument, ObjectIdentifier(document) == changed else { return }
                self.refreshAnnotationViews()
            }
        })
        displayObservers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                for view in self?.annotationViews.allObjects ?? [] { view.zoomChanged() }
            }
        })
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
                guard let self else { return }
                // PDFKit settles its layout in steps too small to see; only real scrolling counts.
                let origin = clipView.bounds.origin
                let moved = abs(origin.x - self.lastScrollOrigin.x) + abs(origin.y - self.lastScrollOrigin.y) > 0.5
                self.lastScrollOrigin = origin
                self.overlay.needsDisplay = true
                guard moved else { return }
                // A text box being typed in would be left behind by the page; finish it instead.
                self.endTextEditing(commit: true)
                self.endContentEditing(commit: true)
                // A form field's editor follows its field, since moving to the next field scrolls.
                self.repositionFieldEditor()
            }
        }
    }

    /// Where the pages are scrolled to.
    var scrollOrigin: CGPoint? {
        get { subviews.compactMap { $0 as? NSScrollView }.first?.contentView.bounds.origin }
        set {
            guard let newValue, let scrollView = subviews.compactMap({ $0 as? NSScrollView }).first else { return }
            scrollView.contentView.scroll(to: newValue)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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

    /// Which side of the editor of the page's text a point in this view is on, for dragging it.
    private func editorEdge(at point: CGPoint) -> Bool? {
        guard let frame = contentSession?.view.frame, point.y >= frame.minY - 4, point.y <= frame.maxY + 4 else { return nil }
        // Mostly outside the editor, where a click would otherwise end the typing.
        if point.x >= frame.minX - 7, point.x <= frame.minX + 2 { return true }
        if point.x >= frame.maxX - 2, point.x <= frame.maxX + 7 { return false }
        return nil
    }

    /// The sides of the editor belong to this view, not to the editor: dragging one resizes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if contentSession != nil, let own = superview.map({ convert(point, from: $0) }), editorEdge(at: own) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let place = convert(event.locationInWindow, from: nil)
        if let session = contentSession, let isLeft = editorEdge(at: place) {
            editorResize = (isLeft, place.x, session.view.frame)
            return
        }
        endTextEditing(commit: true)
        endFieldEditing(commit: true)
        endContentEditing(commit: true)
        window?.makeFirstResponder(self)
        if let viewer, viewer.isContentEditing {
            // While editing content every click is the editor's; a click off the pages picks nothing.
            if let place = pagePoint(of: event), viewer.contentMouseDown(at: place.point, pageIndex: place.pageIndex, clickCount: event.clickCount, modifiers: event.modifierFlags) {
                isDraggingAnnotation = true
            } else {
                viewer.contentSelection = nil
                viewer.selection = nil
            }
            return
        }
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
        if let resize = editorResize, var session = contentSession {
            // The text wraps to the new width as the side moves.
            let moved = convert(event.locationInWindow, from: nil).x - resize.startX
            let narrowest = 40 + 2 * Self.editorMargin
            var frame = session.view.frame
            if resize.isLeft {
                frame.origin.x = min(resize.frame.minX + moved, resize.frame.maxX - narrowest)
                frame.size.width = resize.frame.maxX - frame.origin.x
            } else {
                frame.size.width = max(resize.frame.width + moved, narrowest)
            }
            session.view.frame = frame
            session.isResized = true
            contentSession = session
            fitContentEditor()
            overlay.needsDisplay = true
            return
        }
        guard isDraggingAnnotation else { return super.mouseDragged(with: event) }
        if let viewer, let edit = viewer.maskEdit, let place = pagePoint(of: event, onPage: edit.pageIndex) {
            viewer.contentMouseDragged(to: place.point)
            return
        }
        if let viewer, let session = viewer.contentDrag, let place = pagePoint(of: event, onPage: session.target.pageIndex) {
            viewer.contentMouseDragged(to: place.point, modifiers: event.modifierFlags)
            return
        }
        if let viewer, let session = viewer.drag, let place = pagePoint(of: event, onPage: session.pageIndex) {
            viewer.mouseDragged(to: place.point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if editorResize != nil {
            editorResize = nil
            return
        }
        guard isDraggingAnnotation else {
            super.mouseUp(with: event)
            viewer?.textSelectionEnded()
            return
        }
        isDraggingAnnotation = false
        viewer?.contentMouseUp()
        viewer?.mouseUp()
        updatePointer(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    // MARK: Pointer

    private var pointerTracking: NSTrackingArea?
    private var showsHandleCursor = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updatePointer(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    /// Pressing or letting go of Command over a picture's handle swaps resizing for turning.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window, !isDraggingAnnotation else { return }
        updatePointer(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: event.modifierFlags)
    }

    /// Shows what a drag from under the pointer would do: resize from a handle, or turn
    /// a picture while Command is held.
    private func updatePointer(at location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        if let cursor = handleCursor(at: location, modifiers: modifiers) {
            showsHandleCursor = true
            cursor.set()
            // PDFKit picks a pointer of its own for the same movement; this one has the last word.
            DispatchQueue.main.async { [weak self] in
                if self?.showsHandleCursor == true { cursor.set() }
            }
        } else if showsHandleCursor {
            showsHandleCursor = false
            NSCursor.arrow.set()
        }
    }

    /// The pointer for the handle of the selected thing at a place in this view.
    func handleCursor(at location: CGPoint, modifiers: NSEvent.ModifierFlags) -> NSCursor? {
        // The sides of the text being typed in, which resize its box.
        if editorResize != nil || editorEdge(at: location) != nil { return .resizeLeftRight }
        guard let viewer, let document, !isEditingText,
              let geometry = viewer.selectionGeometry ?? viewer.contentSelectionGeometry, let page = document.page(at: geometry.pageIndex)
        else { return nil }
        var points: [ResizeHandle: CGPoint] = [:]
        for (handle, point) in geometry.handles { points[handle] = convert(point.cgPoint, from: page) }
        let hit = geometry.handles.map(\.handle).first { handle in
            guard let point = points[handle] else { return false }
            return abs(point.x - location.x) <= 7 && abs(point.y - location.y) <= 7
        }
        guard let anchor = hit?.anchor, let left = points[.left], let right = points[.right] else { return nil }
        // The way the handle pulls on screen, from the sides of the thing as they are shown:
        // a page or a picture may be turned.
        func direction(from start: CGPoint, to end: CGPoint) -> CGVector {
            let length = hypot(end.x - start.x, end.y - start.y)
            return length > 0 ? CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length) : .zero
        }
        let across = direction(from: left, to: right)
        // Text has side handles only; up is then square to across.
        let up = points[.bottom].flatMap { bottom in points[.top].map { direction(from: bottom, to: $0) } } ?? CGVector(dx: -across.dy, dy: across.dx)
        let x = (anchor.x - 0.5) * 2, y = (anchor.y - 0.5) * 2
        let pull = CGVector(dx: x * across.dx + y * up.dx, dy: (x * across.dy + y * up.dy) * (isFlipped ? -1 : 1))
        guard hypot(pull.dx, pull.dy) > 0.01 else { return nil }
        let degrees = atan2(pull.dy, pull.dx) * 180 / .pi
        if geometry.canTurn, modifiers.contains(.command), viewer.maskEdit == nil { return PictureCursor.rotate(toward: degrees) }
        return PictureCursor.resize(toward: degrees)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let tool = viewer?.tool, tool != .select, tool.textMarkupKind == nil {
            addCursorRect(bounds, cursor: .crosshair)
        } else if viewer?.formTool != nil {
            addCursorRect(bounds, cursor: .crosshair)
        } else if viewer?.isContentEditing == true {
            switch viewer?.editTool {
            case .redact: addCursorRect(bounds, cursor: .crosshair)
            case .text: addCursorRect(bounds, cursor: .iBeam)
            default: addCursorRect(bounds, cursor: .arrow)
            }
        }
    }

    // MARK: Keyboard and menus

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, viewer?.formTool != nil {
            viewer?.formTool = nil
            return
        }
        if viewer?.handleKeyDown(event) == true { return }
        if viewer?.handleContentKey(event) == true { return }
        if viewer?.handleFieldKey(event) == true { return }
        super.keyDown(with: event)
    }

    @objc func delete(_ sender: Any?) {
        if viewer?.contentSelection != nil {
            viewer?.deleteContentSelection()
        } else {
            viewer?.deleteSelection()
        }
    }

    /// Puts a picture or text from the pasteboard on the page.
    @objc func paste(_ sender: Any?) {
        viewer?.pasteContent()
    }

    override func copy(_ sender: Any?) {
        if viewer?.canCopyContentSelection == true {
            viewer?.copyContentSelection()
        } else {
            super.copy(sender)
        }
    }

    @objc func cut(_ sender: Any?) {
        viewer?.cutContentSelection()
    }

    @objc func duplicate(_ sender: Any?) {
        viewer?.duplicateContentSelection()
    }

    /// Command-D duplicates the selected text or picture, as in Pages. With nothing
    /// selected it stays what it is everywhere else in the app: Add Bookmark.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "d",
           window?.firstResponder === self, viewer?.canArrangeContent == true {
            viewer?.duplicateContentSelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Dropping files and pictures

    private func droppedPicture(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: ViewerModel.pictureTypes.map(\.identifier)]
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: options) || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private func droppedDocuments(_ sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.pdf.identifier]]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard viewer?.sheafDocument?.isEditable == true, document != nil else { return [] }
        return droppedPicture(sender) || !droppedDocuments(sender).isEmpty ? .copy : []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropOperation(sender) != [] }

    /// A picture dropped on a page is placed where it was dropped; PDF files become pages
    /// after the page they were dropped on.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let viewer, let document else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        guard let page = page(for: location, nearest: true) else { return false }
        let pageIndex = document.index(for: page)
        if droppedPicture(sender), let data = ViewerModel.pictureData(from: sender.draggingPasteboard) {
            let point = PDFPoint(convert(location, to: page))
            let center = viewer.content(ofPage: pageIndex)?.geometry.displayPoint(point)
            viewer.addPicture(data, pageIndex: pageIndex, center: center)
            return true
        }
        let files = droppedDocuments(sender)
        guard !files.isEmpty else { return false }
        viewer.insertFiles(files, at: pageIndex + 1)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let viewer, viewer.isContentEditing, let place = pagePoint(of: event), let menu = contentMenu(viewer, at: place.point, pageIndex: place.pageIndex) {
            return menu
        }
        guard let viewer, let place = pagePoint(of: event), let hit = viewer.annotation(at: place.point, pageIndex: place.pageIndex),
              let id = hit.objectID, hit.kind != .other || (hit.subtype == "Widget" && viewer.isFormEditing)
        else { return super.menu(for: event) }
        viewer.selection = AnnotationSelection(pageIndex: place.pageIndex, id: id)
        let menu = NSMenu()
        if hit.kind == .freeText {
            menu.addItem(withTitle: String(localized: "Edit Text"), action: #selector(editSelectedText(_:)), keyEquivalent: "").target = self
        }
        if hit.subtype != "Widget" {
            // Annotations lie over one another in the order they were added, which these change.
            for move in [StackingMove.toFront, .toBack] {
                let item = menu.addItem(withTitle: move.title, action: #selector(restackContent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = move.rawValue
                item.image = NSImage(systemSymbolName: move.systemImage, accessibilityDescription: nil)
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Delete"), action: #selector(delete(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// The menu for the block of text or the picture under a point: what Pages offers
    /// for a thing on a page, as far as a PDF can do it.
    private func contentMenu(_ viewer: ViewerModel, at point: PDFPoint, pageIndex: Int) -> NSMenu? {
        guard let content = viewer.content(ofPage: pageIndex) else { return nil }
        if viewer.maskEdit != nil { viewer.endMaskEditing(commit: true) }
        let place = content.geometry.displayPoint(point)
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, _ action: Selector, image: String? = nil, to target: NSMenu? = nil, tag: Any? = nil) -> NSMenuItem {
            let item = (target ?? menu).addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = tag
            if let image { item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
            return item
        }
        /// Stacking order, lining up, and the pasteboard: the same for text and pictures.
        func addArranging() {
            add(StackingMove.toFront.title, #selector(restackContent(_:)), image: StackingMove.toFront.systemImage, tag: StackingMove.toFront.rawValue)
            add(StackingMove.toBack.title, #selector(restackContent(_:)), image: StackingMove.toBack.systemImage, tag: StackingMove.toBack.rawValue)
            menu.addItem(.separator())
            let align = NSMenuItem(title: String(localized: "Align on Page"), action: nil, keyEquivalent: "")
            align.image = NSImage(systemSymbolName: "align.horizontal.center", accessibilityDescription: nil)
            align.submenu = NSMenu()
            for alignment in PageAlignment.allCases {
                if alignment == .top { align.submenu?.addItem(.separator()) }
                add(alignment.title, #selector(alignContent(_:)), image: alignment.systemImage, to: align.submenu, tag: alignment.rawValue)
            }
            menu.addItem(align)
            menu.addItem(.separator())
            add(String(localized: "Cut"), #selector(cut(_:)))
            add(String(localized: "Copy"), #selector(copy(_:)))
            if viewer.canPasteContent { add(String(localized: "Paste"), #selector(paste(_:))) }
            add(String(localized: "Duplicate"), #selector(duplicate(_:)))
            menu.addItem(.separator())
            add(String(localized: "Add Link…"), #selector(addLinkToContent(_:)))
        }
        // The smallest thing under the pointer, as a click would pick it.
        if let block = content.blocks.filter({ $0.frame.contains(place) }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            viewer.contentSelection = .block(pageIndex: pageIndex, id: block.id)
            guard block.isEditable else {
                add(String(localized: "Copy"), #selector(copy(_:)))
                return menu
            }
            add(String(localized: "Edit Text"), #selector(editSelectedContent(_:)))
            menu.addItem(.separator())
            addArranging()
            menu.addItem(.separator())
            add(String(localized: "Delete"), #selector(delete(_:)))
        } else if let image = content.image(at: place) {
            viewer.contentSelection = .image(pageIndex: pageIndex, id: image.id)
            guard image.isEditable else {
                add(String(localized: "Copy"), #selector(copy(_:)))
                return menu
            }
            addArranging()
            menu.addItem(.separator())
            add(String(localized: "Edit Mask"), #selector(editPictureMask(_:)))
            add(String(localized: "Reset Mask"), #selector(resetPictureMask(_:)))
            add(String(localized: "Replace…"), #selector(replaceSelectedPicture(_:)))
            menu.addItem(.separator())
            add(String(localized: "Rotate Left"), #selector(rotateContent(_:)), image: "rotate.left", tag: 90.0)
            add(String(localized: "Rotate Right"), #selector(rotateContent(_:)), image: "rotate.right", tag: -90.0)
            add(String(localized: "Flip Horizontally"), #selector(flipContent(_:)), image: "arrow.left.and.right.righttriangle.left.righttriangle.right", tag: true)
            add(String(localized: "Flip Vertically"), #selector(flipContent(_:)), image: "arrow.up.and.down.righttriangle.up.righttriangle.down", tag: false)
            menu.addItem(.separator())
            add(String(localized: "Remove Background"), #selector(removePictureBackground(_:)))
            menu.addItem(.separator())
            add(String(localized: "Delete"), #selector(delete(_:)))
        } else {
            guard viewer.canPasteContent else { return nil }
            add(String(localized: "Paste"), #selector(paste(_:)))
        }
        return menu
    }

    @objc private func restackContent(_ sender: NSMenuItem) {
        guard let move = (sender.representedObject as? String).flatMap(StackingMove.init(rawValue:)) else { return }
        viewer?.restackSelection(move)
    }

    @objc private func alignContent(_ sender: NSMenuItem) {
        guard let alignment = (sender.representedObject as? String).flatMap(PageAlignment.init(rawValue:)) else { return }
        viewer?.alignSelection(alignment)
    }

    @objc private func rotateContent(_ sender: NSMenuItem) {
        viewer?.rotateSelectedPicture(by: sender.representedObject as? Double ?? 90)
    }

    @objc private func flipContent(_ sender: NSMenuItem) {
        viewer?.flipSelectedPicture(horizontally: sender.representedObject as? Bool ?? true)
    }

    @objc private func addLinkToContent(_ sender: Any?) {
        viewer?.addLinkToContentSelection()
    }

    @objc private func editPictureMask(_ sender: Any?) {
        viewer?.beginMaskEditing()
    }

    @objc private func resetPictureMask(_ sender: Any?) {
        viewer?.resetMask()
    }

    @objc private func removePictureBackground(_ sender: Any?) {
        viewer?.removeBackgroundOfSelectedPicture()
    }

    @objc private func editSelectedContent(_ sender: Any?) {
        guard let viewer, case .block(let pageIndex, _) = viewer.contentSelection, let block = viewer.selectedBlock else { return }
        viewer.beginEditing(block, pageIndex: pageIndex)
    }

    @objc private func replaceSelectedPicture(_ sender: Any?) {
        viewer?.chooseReplacementPicture()
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

    var isEditingText: Bool { textSession != nil || contentSession != nil }

    /// The text box being typed in, which shows in its editor and nowhere else meanwhile.
    var editedAnnotationID: ObjectID? { textSession?.annotation.objectID }

    // MARK: Typing in the page's own text

    private func contentEditor(
        frame: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment, lineHeight: CGFloat?,
        firstIndent: CGFloat = 0, restIndent: CGFloat = 0, paragraphSpacing: CGFloat = 0
    ) -> NSTextView {
        // A little room at the sides, so the frame does not touch the first and last letters.
        let margin = Self.editorMargin
        let textView = NSTextView(frame: frame.insetBy(dx: -margin, dy: 0))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.firstLineHeadIndent = firstIndent
        paragraph.headIndent = restIndent
        paragraph.paragraphSpacing = paragraphSpacing
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: margin, height: 0)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        textView.wantsLayer = true
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.layer?.borderWidth = 1
        return textView
    }

    private static let editorMargin: CGFloat = 4

    /// Puts an editor over a block of text, set like the block so the words stay in place.
    func beginContentEditing(_ block: TextBlock, pageIndex: Int) {
        endTextEditing(commit: true)
        endContentEditing(commit: true)
        guard let viewer, let frame = viewer.viewRect(block.frame, pageIndex: pageIndex), let first = block.lines.first,
              let baseline = viewer.viewRect(PDFRectangle(x: block.frame.x, y: first.baseline, width: 1, height: 0), pageIndex: pageIndex)
        else { return }
        let scale = scaleFactor
        let size = block.fontSize * scale
        // The document's own font where it can be used, so the text looks as it does on the page.
        let fonts = EditorFont.font(for: block, size: size, editor: viewer.sheafDocument?.editor)
        let font = fonts.primary
        let lineHeight = (block.leading * scale).rounded(.toNearestOrAwayFromZero)
        // The first baseline sits where the block's does: a line of fixed height puts
        // its baseline the font's descent above its bottom edge.
        let top = baseline.minY + lineHeight + font.descender
        let alignment: NSTextAlignment = switch block.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        // A little wider than the block, so a matched font's slightly different widths
        // do not push words onto new lines.
        let slack = max(size * 0.5, 4)
        let x = alignment == .right ? frame.minX - slack : alignment == .center ? frame.minX - slack / 2 : frame.minX
        let height = max(top - frame.minY, lineHeight)
        // A single line may grow to the right, as far as the engine will let it when it sets the text.
        let limit = viewer.content(ofPage: pageIndex)?.rightLimit(of: block) ?? block.frame.x + block.frame.width
        let width = max(limit - block.frame.x, block.frame.width) * scale
        let textView = contentEditor(
            frame: CGRect(x: x, y: top - height, width: width + slack, height: height), font: font, color: block.color.nsColor,
            alignment: alignment, lineHeight: lineHeight,
            firstIndent: block.indents.first * scale, restIndent: block.indents.rest * scale, paragraphSpacing: block.paragraphGap * scale
        )
        // Words the document's font cannot draw are shown in the installed font whole, as
        // the page will have them. The keeper lives as long as the editor.
        if fonts.fallback != nil {
            let keeper = WordFontKeeper(fonts: fonts)
            textView.textStorage?.delegate = keeper
            objc_setAssociatedObject(textView, &Self.keeperKey, keeper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        textView.string = block.flowingText
        // Covers the text on the page, which stays there until the change is made.
        textView.drawsBackground = true
        textView.backgroundColor = viewer.pageColor(around: block.frame, pageIndex: pageIndex)
        // Under the overlay, which draws the handles on its sides.
        addSubview(textView, positioned: .below, relativeTo: overlay)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        contentSession = ContentSession(view: textView, pageIndex: pageIndex, block: block, origin: PDFPoint(x: block.frame.x, y: block.frame.y + block.frame.height), style: NewTextStyle(), top: top, minimumHeight: height)
        fitContentEditor()
        overlay.needsDisplay = true
    }

    /// Puts an empty editor on a page, for typing new text.
    ///
    /// - Parameter point: The top left corner of the text, on the page as displayed.
    func beginNewContentText(at point: PDFPoint, pageIndex: Int, style: NewTextStyle) {
        endTextEditing(commit: true)
        endContentEditing(commit: true)
        guard let viewer, let page = viewer.content(ofPage: pageIndex)?.geometry.displaySize,
              let corner = viewer.viewRect(PDFRectangle(x: point.x, y: point.y, width: 0, height: 0), pageIndex: pageIndex)
        else { return }
        let scale = scaleFactor
        let size = style.fontSize * scale
        let font = NSFont(name: style.fontName, size: size) ?? .systemFont(ofSize: size)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let width = max(page.width - point.x - 18, 72) * scale
        let textView = contentEditor(
            frame: CGRect(x: corner.minX, y: corner.minY - lineHeight, width: width, height: lineHeight), font: font, color: style.color.nsColor,
            alignment: .left, lineHeight: nil
        )
        textView.drawsBackground = false
        // Under the overlay, which draws the handles on its sides.
        addSubview(textView, positioned: .below, relativeTo: overlay)
        window?.makeFirstResponder(textView)
        contentSession = ContentSession(view: textView, pageIndex: pageIndex, block: nil, origin: point, style: style, top: corner.minY, minimumHeight: lineHeight)
        overlay.needsDisplay = true
    }

    /// Grows the editor downwards as lines are added, keeping its top where it is.
    private func fitContentEditor() {
        guard let session = contentSession, let layout = session.view.layoutManager, let container = session.view.textContainer else { return }
        layout.ensureLayout(for: container)
        let height = max(ceil(layout.usedRect(for: container).height), session.minimumHeight)
        session.view.frame = CGRect(x: session.view.frame.minX, y: session.top - height, width: session.view.frame.width, height: height)
    }

    func endContentEditing(commit: Bool) {
        guard let session = contentSession else { return }
        contentSession = nil
        let text = session.view.string
        let width = Double((session.view.frame.width - 2 * Self.editorMargin) / max(scaleFactor, 0.01))
        session.view.delegate = nil
        session.view.removeFromSuperview()
        window?.makeFirstResponder(self)
        overlay.needsDisplay = true
        guard let viewer else { return }
        // The sides of the editor as it was left, on the page as displayed.
        var sides: (left: Double, right: Double)?
        if session.isResized, let page = document?.page(at: session.pageIndex), let geometry = viewer.content(ofPage: session.pageIndex)?.geometry {
            let inner = session.view.frame.insetBy(dx: Self.editorMargin, dy: 0)
            let left = geometry.displayPoint(PDFPoint(convert(CGPoint(x: inner.minX, y: inner.midY), to: page)))
            let right = geometry.displayPoint(PDFPoint(convert(CGPoint(x: inner.maxX, y: inner.midY), to: page)))
            sides = (min(left.x, right.x), max(left.x, right.x))
        }
        if let block = session.block {
            if commit { viewer.commitContentText(text, block: block, pageIndex: session.pageIndex, box: sides) }
        } else {
            var origin = session.origin
            if let sides { origin.x = sides.left }
            viewer.commitNewContentText(commit ? text : "", at: origin, width: width, pageIndex: session.pageIndex, style: session.style)
        }
    }

    var isEditingContent: Bool { contentSession != nil }

    /// Where the editor of the page's text is in this view, while there is one.
    var contentEditorFrame: CGRect? { contentSession?.view.frame }

    #if DEBUG
    /// Drags a side of the text editor the way the mouse would, in automated runs.
    func debugDragEditorSide(left: Bool, by distance: CGFloat) {
        guard let frame = contentSession?.view.frame, let window else { return }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: convert(CGPoint(x: x, y: frame.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let start = left ? frame.minX - 3 : frame.maxX + 3
        guard let down = event(.leftMouseDown, start), let drag = event(.leftMouseDragged, start + distance), let up = event(.leftMouseUp, start + distance) else { return }
        // Through the same test a real click goes through.
        Swift.print("EDIT editor side hit by \(hitTest(superview?.convert(CGPoint(x: start, y: frame.midY), from: self) ?? .zero).map { String(describing: type(of: $0)) } ?? "nothing"), pointer \(handleCursor(at: CGPoint(x: start, y: frame.midY), modifiers: []) == NSCursor.resizeLeftRight ? "resize" : "other")")
        mouseDown(with: down)
        mouseDragged(with: drag)
        mouseUp(with: up)
        Swift.print("EDIT editor now \(Int(contentSession?.view.frame.width ?? 0)) wide, was \(Int(frame.width)), still typing=\(contentSession != nil)")
    }
    #endif

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
        contentSession?.view.string = text
        fitContentEditor()
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
            endContentEditing(commit: true)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        fitContentEditor()
    }

    func textDidEndEditing(_ notification: Notification) {
        // Writing Tools works on the text from a panel of its own; the text stays open under it.
        if let textView = notification.object as? NSTextView, textView.isWritingToolsActive { return }
        endTextEditing(commit: true)
        endContentEditing(commit: true)
    }
}

extension SheafPDFView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:)): viewer?.canPasteContent == true
        case #selector(delete(_:)): viewer?.contentSelection != nil || viewer?.selection != nil
        case #selector(copy(_:)): viewer?.canCopyContentSelection == true || currentSelection?.string?.isEmpty == false
        case #selector(cut(_:)): viewer?.canCutContentSelection == true
        case #selector(duplicate(_:)), #selector(alignContent(_:)), #selector(flipContent(_:)), #selector(rotateContent(_:)): viewer?.canArrangeContent == true
        case #selector(restackContent(_:)):
            (menuItem.representedObject as? String).flatMap(StackingMove.init(rawValue:)).map { viewer?.stackingMoves.contains($0) == true } ?? false
        case #selector(resetPictureMask(_:)): viewer?.selectedImage?.shownPart != nil || viewer?.maskEdit != nil
        default: true
        }
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
        drawContent(of: viewer, in: pdfView, document: document)

        if let editor = pdfView.contentEditorFrame {
            // The sides of the text being typed in can be dragged to make its box narrower or wider.
            for x in [editor.minX, editor.maxX] {
                let square = CGRect(x: (x - 3.5).rounded() + 0.5, y: (editor.midY - 3.5).rounded() + 0.5, width: 7, height: 7)
                NSColor.white.setFill()
                square.fill()
                NSColor.controlAccentColor.setStroke()
                let edge = NSBezierPath(rect: square)
                edge.lineWidth = 1
                edge.stroke()
            }
        }
        if let edit = viewer.maskEdit { drawMask(edit, of: viewer) }
        guard !pdfView.isEditingText, let geometry = viewer.selectionGeometry ?? viewer.contentSelectionGeometry,
              let page = document.page(at: geometry.pageIndex)
        else { return }
        NSColor.controlAccentColor.setStroke()
        let outline: NSBezierPath
        if let corners = geometry.outline, corners.count > 2 {
            // A turned picture is framed along its own sides.
            outline = NSBezierPath()
            for (index, corner) in corners.enumerated() {
                let point = pdfView.convert(corner.cgPoint, from: page)
                if index == 0 { outline.move(to: point) } else { outline.line(to: point) }
            }
            outline.close()
        } else {
            outline = NSBezierPath(rect: pdfView.convert(geometry.frame.cgRect, from: page).insetBy(dx: -0.5, dy: -0.5))
        }
        outline.lineWidth = 1
        outline.stroke()

        for (_, point) in geometry.handles {
            let center = pdfView.convert(point.cgPoint, from: page)
            if geometry.isPicture {
                // Pictures have the small white squares Pages puts on them.
                let square = CGRect(x: (center.x - 3.5).rounded() + 0.5, y: (center.y - 3.5).rounded() + 0.5, width: 7, height: 7)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                shadow.shadowBlurRadius = 1.5
                shadow.shadowOffset = CGSize(width: 0, height: -0.5)
                shadow.set()
                NSColor.white.setFill()
                square.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor(white: 0.35, alpha: 1).setStroke()
                let edge = NSBezierPath(rect: square)
                edge.lineWidth = 0.75
                edge.stroke()
                continue
            }
            let handle = NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            handle.lineWidth = 1.5
            handle.stroke()
        }
        drawAngle(of: viewer)
    }

    /// While a picture's mask is changed: the whole picture, faint where the mask hides
    /// it and as it is where it shows.
    private func drawMask(_ edit: MaskEdit, of viewer: ViewerModel) {
        let whole = edit.whole.corners.compactMap { viewer.viewPoint($0, pageIndex: edit.pageIndex) }
        guard whole.count == 4, let context = NSGraphicsContext.current?.cgContext else { return }
        // The page still shows the picture with the mask it had, which is covered up.
        var before = edit
        before.part = edit.original
        if let old = polygon(before.placement.corners, pageIndex: edit.pageIndex, viewer: viewer) {
            viewer.pageColor(around: before.placement.frame, pageIndex: edit.pageIndex).setFill()
            old.fill()
        }
        if let picture = edit.picture {
            // The picture's own bottom left, bottom right and top left corners. A mirrored
            // picture has its own left on the right.
            let corners = edit.whole.isMirrored ? [whole[1], whole[0], whole[2]] : [whole[0], whole[1], whole[3]]
            let transform = CGAffineTransform(
                a: corners[1].x - corners[0].x, b: corners[1].y - corners[0].y,
                c: corners[2].x - corners[0].x, d: corners[2].y - corners[0].y, tx: corners[0].x, ty: corners[0].y
            )
            for isShown in [false, true] {
                context.saveGState()
                if isShown, let shape = polygon(edit.placement.corners, pageIndex: edit.pageIndex, viewer: viewer) {
                    context.addPath(shape.cgPath)
                    context.clip()
                }
                context.concatenate(transform)
                context.setAlpha(isShown ? 1 : 0.3)
                context.interpolationQuality = .high
                context.draw(picture, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                context.restoreGState()
            }
        }
        if let outline = polygon(edit.whole.corners, pageIndex: edit.pageIndex, viewer: viewer) {
            NSColor.systemGray.setStroke()
            outline.lineWidth = 0.5
            outline.stroke()
        }
    }

    /// While a picture is being turned, its angle next to the pointer, as Pages shows it.
    private func drawAngle(of viewer: ViewerModel) {
        guard let drag = viewer.contentDrag, drag.didMove, case .rotating = drag.mode, let placement = drag.placement,
              let pointer = viewer.viewPoint(drag.pointer, pageIndex: drag.target.pageIndex)
        else { return }
        let degrees = placement.rotation >= 359.95 ? 0 : placement.rotation
        let text = NSAttributedString(
            string: Measurement(value: degrees, unit: UnitAngle.degrees).formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1)))),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        )
        let size = text.size()
        var box = CGRect(x: pointer.x + 16, y: pointer.y - 18 - size.height, width: size.width + 14, height: size.height + 6)
        // Kept in view when the pointer is near an edge.
        if box.maxX > bounds.maxX - 4 { box.origin.x = pointer.x - 16 - box.width }
        if box.minY < bounds.minY + 4 { box.origin.y = pointer.y + 18 }
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }

    /// What editing content adds to the pages in view: found text, redaction previews,
    /// the outlines of what can be picked, and whatever is being dragged.
    private func drawContent(of viewer: ViewerModel, in pdfView: SheafPDFView, document: PDFDocument) {
        let visible = Set(pdfView.visiblePages.map { document.index(for: $0) })

        if viewer.isReplaceVisible {
            for (index, match) in viewer.textMatches.enumerated() where visible.contains(match.pageIndex) {
                let isCurrent = index == viewer.currentMatchIndex
                for frame in match.frames {
                    guard let rect = viewer.viewRect(frame, pageIndex: match.pageIndex), rect.intersects(bounds) else { continue }
                    (isCurrent ? NSColor.systemOrange.withAlphaComponent(0.45) : NSColor.systemYellow.withAlphaComponent(0.4)).setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
                }
            }
        }

        // Redaction marks: frames one can see through, or the black boxes they will become.
        for index in visible {
            guard let page = document.page(at: index) else { continue }
            for mark in viewer.redactionMarks(onPage: index) {
                // The one being dragged is drawn by its stand-in.
                if let drag = viewer.drag, drag.original?.objectID == mark.objectID, drag.didMove { continue }
                let rect = pdfView.convert(mark.rect.cgRect, from: page)
                guard rect.intersects(bounds) else { continue }
                if viewer.previewsRedactions {
                    NSColor.black.setFill()
                    rect.fill()
                } else {
                    NSColor.systemRed.withAlphaComponent(0.14).setFill()
                    rect.fill()
                    NSColor.systemRed.setStroke()
                    let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                    outline.lineWidth = 1
                    outline.stroke()
                }
            }
        }

        guard viewer.isContentEditing, !pdfView.isEditingContent else { return }
        if viewer.editTool == .select {
            NSColor.systemGray.withAlphaComponent(0.55).setStroke()
            for index in visible {
                guard let content = viewer.content(ofPage: index) else { continue }
                let frames = content.blocks.filter(\.isEditable).map(\.frame)
                let pictures = content.images.filter(\.isEditable)
                // A page set letter by letter has thousands of pieces; outlining them all would hide it.
                guard frames.count + pictures.count < 1500 else { continue }
                for frame in frames {
                    guard let rect = viewer.viewRect(frame, pageIndex: index), rect.intersects(bounds) else { continue }
                    let outline = NSBezierPath(rect: rect.insetBy(dx: -1.5, dy: -1.5))
                    outline.lineWidth = 0.5
                    outline.stroke()
                }
                for picture in pictures {
                    guard let rect = viewer.viewRect(picture.frame, pageIndex: index), rect.intersects(bounds),
                          let outline = polygon(picture.placement.corners, pageIndex: index, viewer: viewer)
                    else { continue }
                    outline.lineWidth = 0.5
                    outline.stroke()
                }
            }
        }

        guard let drag = viewer.contentDrag, drag.didMove, let page = document.page(at: drag.target.pageIndex),
              let from = viewer.viewRect(drag.original, pageIndex: drag.target.pageIndex), let to = viewer.viewRect(drag.frame, pageIndex: drag.target.pageIndex)
        else { return }
        // Text being made narrower or wider shows only its new box until it is set again.
        if case .resizing = drag.mode, drag.originalPlacement == nil { return }
        // The thing stays on the page until the mouse is let go, so it is faded where it
        // was and shown where it is going.
        NSColor.white.withAlphaComponent(0.7).setFill()
        if let old = drag.originalPlacement, let new = drag.placement {
            // A picture, which may be turned: its corners say where it was and where it goes.
            let before = old.corners.compactMap { viewer.viewPoint($0, pageIndex: drag.target.pageIndex) }
            let after = new.corners.compactMap { viewer.viewPoint($0, pageIndex: drag.target.pageIndex) }
            guard before.count == 4, after.count == 4, let shape = polygon(old.corners, pageIndex: drag.target.pageIndex, viewer: viewer) else { return }
            shape.fill()
            func square(_ corners: [CGPoint]) -> CGAffineTransform {
                CGAffineTransform(
                    a: corners[1].x - corners[0].x, b: corners[1].y - corners[0].y,
                    c: corners[3].x - corners[0].x, d: corners[3].y - corners[0].y, tx: corners[0].x, ty: corners[0].y
                )
            }
            if let snapshot = drag.snapshot, let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.concatenate(square(before).inverted().concatenating(square(after)))
                // Only the picture itself goes along, not what lies around a turned one.
                context.addPath(shape.cgPath)
                context.clip()
                context.setAlpha(0.92)
                context.draw(snapshot, in: from)
                context.restoreGState()
            }
        } else {
            from.fill()
            if let snapshot = drag.snapshot, let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setAlpha(0.92)
                context.draw(snapshot, in: to)
                context.restoreGState()
            }
        }
        let pageFrame = pdfView.convert(page.bounds(for: .cropBox), from: page)
        NSColor.systemYellow.setStroke()
        for x in drag.verticalGuides {
            guard let at = viewer.viewRect(PDFRectangle(x: x, y: 0, width: 0, height: 0), pageIndex: drag.target.pageIndex) else { continue }
            let line = NSBezierPath()
            line.move(to: CGPoint(x: at.minX, y: pageFrame.minY))
            line.line(to: CGPoint(x: at.minX, y: pageFrame.maxY))
            line.lineWidth = 1
            line.stroke()
        }
        for y in drag.horizontalGuides {
            guard let at = viewer.viewRect(PDFRectangle(x: 0, y: y, width: 0, height: 0), pageIndex: drag.target.pageIndex) else { continue }
            let line = NSBezierPath()
            line.move(to: CGPoint(x: pageFrame.minX, y: at.minY))
            line.line(to: CGPoint(x: pageFrame.maxX, y: at.minY))
            line.lineWidth = 1
            line.stroke()
        }
    }

    /// A shape through points on a page as displayed, in this view.
    private func polygon(_ points: [PDFPoint], pageIndex: Int, viewer: ViewerModel) -> NSBezierPath? {
        let corners = points.compactMap { viewer.viewPoint($0, pageIndex: pageIndex) }
        guard corners.count == points.count, corners.count > 2 else { return nil }
        let path = NSBezierPath()
        path.move(to: corners[0])
        for corner in corners.dropFirst() { path.line(to: corner) }
        path.close()
        return path
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
