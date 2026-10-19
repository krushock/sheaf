import AppKit
import PDFKit
import SheafKit
import UniformTypeIdentifiers

/// What clicking and dragging on a page does while editing its content.
enum EditTool: String, CaseIterable, Identifiable {
    case select, text, redact

    var id: Self { self }

    var title: String {
        switch self {
        case .select: String(localized: "Select")
        case .text: String(localized: "Text")
        case .redact: String(localized: "Redact")
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .redact: "rectangle.fill"
        }
    }

    var help: String {
        switch self {
        case .select: String(localized: "Select, move and change text and pictures")
        case .text: String(localized: "Click a page to type new text")
        case .redact: String(localized: "Drag over what should be removed for good")
        }
    }
}

/// A block of text or a picture, by where it is.
enum ContentTarget: Hashable {
    case block(pageIndex: Int, id: Int)
    case image(pageIndex: Int, id: Int)

    var pageIndex: Int {
        switch self {
        case .block(let pageIndex, _), .image(let pageIndex, _): pageIndex
        }
    }
}

/// How text made with the text tool looks.
struct NewTextStyle: Equatable {
    var fontName = "Helvetica"
    var fontSize = 12.0
    var color = PDFColor.black
}

/// A drag in progress on a block of text or a picture. Frames are on the page as displayed.
struct ContentDrag {
    enum Mode {
        case moving
        case resizing(ResizeHandle)
        case rotating
    }

    var target: ContentTarget
    var mode: Mode
    var start: PDFPoint
    var original: PDFRectangle
    var frame: PDFRectangle
    /// A picture's place, size and angle, at the start and now. Text has only its frame.
    var originalPlacement: ImagePlacement?
    var placement: ImagePlacement?
    /// Where the pointer is, on the page as displayed.
    var pointer = PDFPoint(x: 0, y: 0)
    /// What the thing looks like, to show at the place it is dragged to.
    var snapshot: CGImage?
    /// Places other things line up with: positions across the page, and up it.
    var verticalGuides: [Double] = []
    var horizontalGuides: [Double] = []
    var didMove = false
}

/// Editing what pages draw: text and pictures.
extension ViewerModel {
    // MARK: Reading pages

    /// What a page draws. Read once per change to the document.
    func content(ofPage index: Int) -> PageContent? {
        guard let sheafDocument, let editor = sheafDocument.editor else { return nil }
        if let cached = contentCache[index], cached.revision == sheafDocument.revision, cached.generation == sheafDocument.generation {
            return cached.content
        }
        guard let content = try? editor.pageContent(at: index) else { return nil }
        if contentCache.count > 24 { contentCache = [:] }
        contentCache[index] = (sheafDocument.revision, sheafDocument.generation, content)
        return content
    }

    var selectedBlock: TextBlock? {
        guard case .block(let pageIndex, let id) = contentSelection else { return nil }
        _ = sheafDocument?.revision
        return content(ofPage: pageIndex)?.blocks.first { $0.id == id }
    }

    var selectedImage: PageImage? {
        guard case .image(let pageIndex, let id) = contentSelection else { return nil }
        _ = sheafDocument?.revision
        return content(ofPage: pageIndex)?.images.first { $0.id == id }
    }

    /// The selected thing's frame on the page as displayed.
    private var selectedFrame: PDFRectangle? {
        selectedBlock?.frame ?? selectedImage?.frame
    }

    func contentEditingDidToggle() {
        pdfView.endContentEditing(commit: true)
        endMaskEditing(commit: true)
        contentSelection = nil
        contentDrag = nil
        editTool = .select
        selection = nil
        if isContentEditing {
            isMarkupVisible = false
            isFormEditing = false
        } else {
            previewsRedactions = false
        }
        pdfView.window?.invalidateCursorRects(for: pdfView)
        pdfView.overlay.needsDisplay = true
    }

    /// Drops a selection that no longer names anything, after an edit or Undo.
    func contentDidChange() {
        if contentSelection != nil, selectedBlock == nil, selectedImage == nil { contentSelection = nil }
        stackingCache = nil
        if isReplaceVisible, !replaceQuery.isEmpty { scheduleTextSearch(keepingPlace: true) }
    }

    // MARK: Geometry

    /// A frame on the page as displayed, in the view.
    func viewRect(_ frame: PDFRectangle, pageIndex: Int) -> CGRect? {
        guard let page = document?.page(at: pageIndex), let geometry = content(ofPage: pageIndex)?.geometry else { return nil }
        return pdfView.convert(geometry.pageRect(frame).cgRect, from: page)
    }

    /// A point on the page as displayed, in the view.
    func viewPoint(_ point: PDFPoint, pageIndex: Int) -> CGPoint? {
        guard let page = document?.page(at: pageIndex), let geometry = content(ofPage: pageIndex)?.geometry else { return nil }
        return pdfView.convert(geometry.pagePoint(point).cgPoint, from: page)
    }

    /// The frame and handles of the selected block or picture, for the overlay.
    var contentSelectionGeometry: SelectionGeometry? {
        guard let target = contentSelection, let geometry = content(ofPage: target.pageIndex)?.geometry else { return nil }
        if let edit = maskEdit {
            // While a mask is changed, the handles are those of the part that shows.
            let shown = edit.placement
            let handles = ResizeHandle.frameHandles.compactMap { handle in
                handle.anchor.map { (handle, geometry.pagePoint(shown.point(atFractionX: $0.x, y: $0.y))) }
            }
            return SelectionGeometry(pageIndex: edit.pageIndex, frame: geometry.pageRect(shown.frame), handles: handles, outline: shown.corners.map(geometry.pagePoint), isPicture: true)
        }
        if let image = selectedImage, image.isEditable {
            // Handles sit on the picture's own corners and sides, however it is turned.
            let placement = contentDrag?.placement ?? image.placement
            let handles = ResizeHandle.frameHandles.compactMap { handle in
                handle.anchor.map { (handle, geometry.pagePoint(placement.point(atFractionX: $0.x, y: $0.y))) }
            }
            return SelectionGeometry(
                pageIndex: target.pageIndex, frame: geometry.pageRect(placement.frame), handles: handles,
                outline: placement.corners.map(geometry.pagePoint), isPicture: true, canTurn: true
            )
        }
        guard let frame = contentDrag?.frame ?? selectedFrame else { return nil }
        var handles: [(ResizeHandle, PDFPoint)] = []
        if selectedBlock?.isEditable == true {
            // Text has a handle on each side: its box is as tall as its lines make it,
            // and only the width is there to set.
            handles = [
                (.left, geometry.pagePoint(PDFPoint(x: frame.x, y: frame.y + frame.height / 2))),
                (.right, geometry.pagePoint(PDFPoint(x: frame.x + frame.width, y: frame.y + frame.height / 2))),
            ]
        }
        return SelectionGeometry(pageIndex: target.pageIndex, frame: geometry.pageRect(frame), handles: handles, isPicture: true)
    }

    /// The side handle of a block of text that a point on the page as displayed is on.
    private func handle(of block: TextBlock, at point: PDFPoint) -> ResizeHandle? {
        let reach = contentReach, middle = block.frame.y + block.frame.height / 2
        guard abs(point.y - middle) <= reach else { return nil }
        if abs(point.x - block.frame.x) <= reach { return .left }
        if abs(point.x - block.frame.x - block.frame.width) <= reach { return .right }
        return nil
    }

    /// The handle of a picture that a point on the page as displayed is on.
    private func handle(of image: PageImage, at point: PDFPoint) -> ResizeHandle? {
        let reach = contentReach, placement = image.placement
        return ResizeHandle.frameHandles.first { handle in
            guard let anchor = handle.anchor else { return false }
            let at = placement.point(atFractionX: anchor.x, y: anchor.y)
            return abs(at.x - point.x) <= reach && abs(at.y - point.y) <= reach
        }
    }

    private var contentReach: Double { 7 / max(Double(pdfView.scaleFactor), 0.1) }

    // MARK: Mouse

    /// A click on a page while the editing tools are out. Always takes the click: text is
    /// not selected for copying in this mode, it is picked up in blocks.
    func contentMouseDown(at pagePoint: PDFPoint, pageIndex: Int, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let sheafDocument, sheafDocument.isEditable, let content = content(ofPage: pageIndex) else { return false }
        let point = content.geometry.displayPoint(pagePoint)
        if maskEdit != nil {
            maskMouseDown(at: point, pageIndex: pageIndex)
            return true
        }

        switch editTool {
        case .redact:
            selection = nil
            contentSelection = nil
            let draft = Annotation(kind: .redact, rect: PDFRectangle(x: pagePoint.x, y: pagePoint.y, width: 0, height: 0))
            drag = DragSession(mode: .creating, pageIndex: pageIndex, start: pagePoint, original: nil, draft: draft)
            return true

        case .text:
            contentSelection = nil
            pdfView.beginNewContentText(at: point, pageIndex: pageIndex, style: newTextStyle)
            return true

        case .select:
            // A redaction mark is an annotation, and is picked, moved and resized like one.
            if let selection, selection.pageIndex == pageIndex, let mark = selectedAnnotation, mark.kind == .redact {
                if mouseDown(onMark: mark, at: pagePoint, pageIndex: pageIndex) { return true }
            }
            if let mark = annotation(at: pagePoint, pageIndex: pageIndex), mark.kind == .redact, let id = mark.objectID {
                contentSelection = nil
                selection = AnnotationSelection(pageIndex: pageIndex, id: id)
                drag = DragSession(mode: .moving, pageIndex: pageIndex, start: pagePoint, original: mark, draft: mark)
                return true
            }
            selection = nil

            // A handle of the picture already picked: dragging it resizes the picture, and
            // turns it while Command is held, as in Pages.
            if let image = selectedImage, contentSelection?.pageIndex == pageIndex, image.isEditable, let handle = handle(of: image, at: point) {
                let placement = image.placement
                contentDrag = ContentDrag(
                    target: .image(pageIndex: pageIndex, id: image.id), mode: modifiers.contains(.command) ? .rotating : .resizing(handle),
                    start: point, original: placement.frame, frame: placement.frame, originalPlacement: placement, placement: placement, pointer: point
                )
                return true
            }

            // A side handle of the text already picked sets the width its lines are fitted to.
            if let block = selectedBlock, contentSelection?.pageIndex == pageIndex, block.isEditable, clickCount < 2, let handle = handle(of: block, at: point) {
                contentDrag = ContentDrag(target: .block(pageIndex: pageIndex, id: block.id), mode: .resizing(handle), start: point, original: block.frame, frame: block.frame, pointer: point)
                return true
            }

            // Text lies on top of pictures, so it is tried first. The smallest block
            // under the click wins, which makes a caption on a big picture reachable.
            if let block = content.blocks.filter({ $0.frame.contains(point) }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                contentSelection = .block(pageIndex: pageIndex, id: block.id)
                if clickCount >= 2 {
                    beginEditing(block, pageIndex: pageIndex)
                } else if block.isEditable {
                    contentDrag = ContentDrag(target: .block(pageIndex: pageIndex, id: block.id), mode: .moving, start: point, original: block.frame, frame: block.frame)
                }
                return true
            }
            // A turned picture is hit on the picture itself, not on the box around it.
            func isHit(_ image: PageImage) -> Bool { image.isEditable ? image.contains(point) : image.frame.contains(point) }
            if let image = content.images.filter(isHit).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                contentSelection = .image(pageIndex: pageIndex, id: image.id)
                if clickCount >= 2, image.isEditable {
                    // A double click shows the mask to change, as in Pages.
                    beginMaskEditing()
                } else if image.isEditable {
                    let placement = image.placement
                    contentDrag = ContentDrag(
                        target: .image(pageIndex: pageIndex, id: image.id), mode: .moving,
                        start: point, original: placement.frame, frame: placement.frame, originalPlacement: placement, placement: placement, pointer: point
                    )
                }
                return true
            }
            contentSelection = nil
            return true
        }
    }

    /// A click on the selected redaction mark: on a handle to resize it.
    private func mouseDown(onMark mark: Annotation, at point: PDFPoint, pageIndex: Int) -> Bool {
        let reach = contentReach
        let handle = ResizeHandle.frameHandles.first { handle in
            guard let anchor = handle.anchor else { return false }
            return abs(mark.rect.x + anchor.x * mark.rect.width - point.x) <= reach && abs(mark.rect.y + anchor.y * mark.rect.height - point.y) <= reach
        }
        guard let handle else { return false }
        drag = DragSession(mode: .resizing(handle), pageIndex: pageIndex, start: point, original: mark, draft: mark)
        return true
    }

    func contentMouseDragged(to pagePoint: PDFPoint, modifiers: NSEvent.ModifierFlags = []) {
        if let edit = maskEdit, let geometry = content(ofPage: edit.pageIndex)?.geometry {
            return maskMouseDragged(to: geometry.displayPoint(pagePoint))
        }
        guard var session = contentDrag, let content = content(ofPage: session.target.pageIndex) else { return }
        let point = content.geometry.displayPoint(pagePoint)
        let page = content.geometry.displaySize
        let dx = point.x - session.start.x, dy = point.y - session.start.y
        // A click that wobbles is not a drag.
        if !session.didMove, abs(dx) + abs(dy) < 3 / max(Double(pdfView.scaleFactor), 0.1) { return }
        if !session.didMove {
            session.didMove = true
            session.snapshot = snapshot(of: session.original, pageIndex: session.target.pageIndex)
        }
        session.pointer = point
        session.verticalGuides = []
        session.horizontalGuides = []
        let old = session.original
        switch session.mode {
        case .moving:
            var frame = old
            frame.x = min(max(old.x + dx, 0), max(page.width - old.width, 0))
            frame.y = min(max(old.y + dy, 0), max(page.height - old.height, 0))
            (frame, session.verticalGuides, session.horizontalGuides) = snapped(frame, target: session.target, in: content)
            session.frame = frame
            // The box around a turned picture has the picture's center.
            session.placement?.center = PDFPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)

        case .resizing(let handle) where session.originalPlacement == nil:
            // A block of text: one side follows the pointer, the other stays.
            var frame = old
            let narrowest = 24.0
            if handle == .left {
                frame.x = min(max(point.x, 0), old.x + old.width - narrowest)
                frame.width = old.x + old.width - frame.x
            } else {
                frame.width = max(min(point.x, page.width) - old.x, narrowest)
            }
            session.frame = frame

        case .resizing(let handle):
            guard let anchor = handle.anchor, let old = session.originalPlacement, old.width > 0, old.height > 0 else { return }
            // Worked out along the picture's own sides, so a turned picture keeps its angle.
            let pointer = old.local(point)
            var (left, bottom, right, top) = (-old.width / 2, -old.height / 2, old.width / 2, old.height / 2)
            let minimum = 8.0
            if anchor.x == 0 { left = min(pointer.x, right - minimum) }
            if anchor.x == 1 { right = max(pointer.x, left + minimum) }
            if anchor.y == 0 { bottom = min(pointer.y, top - minimum) }
            if anchor.y == 1 { top = max(pointer.y, bottom + minimum) }
            if anchor.x != 0.5, anchor.y != 0.5, Preferences.pictureKeepsProportionsValue || modifiers.contains(.shift) {
                // A corner keeps the picture's proportions, as in Pages, unless that is
                // switched off in the Format panel; Shift keeps them then.
                let scale = max((right - left) / old.width, (top - bottom) / old.height)
                let width = old.width * scale, height = old.height * scale
                if anchor.x == 0 { left = right - width } else { right = left + width }
                if anchor.y == 0 { bottom = top - height } else { top = bottom + height }
            }
            var placement = old
            placement.width = right - left
            placement.height = top - bottom
            placement.center = old.point(atFractionX: 0.5 + (left + right) / 2 / old.width, y: 0.5 + (bottom + top) / 2 / old.height)
            session.placement = placement
            session.frame = placement.frame

        case .rotating:
            guard let old = session.originalPlacement else { return }
            // The picture turns about its center by as much as the pointer has gone around it.
            let from = atan2(session.start.y - old.center.y, session.start.x - old.center.x)
            let to = atan2(point.y - old.center.y, point.x - old.center.x)
            var degrees = old.rotation + (to - from) * 180 / .pi
            if modifiers.contains(.shift) {
                degrees = (degrees / 45).rounded() * 45
            } else {
                // Upright and on its side are easy to land on.
                let square = (degrees / 90).rounded() * 90
                degrees = abs(degrees - square) < 1.5 ? square : (degrees * 10).rounded() / 10
            }
            degrees = degrees.truncatingRemainder(dividingBy: 360)
            if degrees < 0 { degrees += 360 }
            var placement = old
            placement.rotation = degrees
            session.placement = placement
            session.frame = placement.frame
        }
        contentDrag = session
    }

    func contentMouseUp() {
        maskMouseUp()
        guard let session = contentDrag else { return }
        contentDrag = nil
        guard session.didMove else { return }
        let pageIndex = session.target.pageIndex
        switch session.target {
        case .block(_, let id):
            guard session.frame != session.original else { return }
            if case .resizing = session.mode {
                // The same words, fitted to the new width. The top line stays where it is.
                guard let text = content(ofPage: pageIndex)?.blocks.first(where: { $0.id == id })?.flowingText else { return }
                let box = TextRestyle(left: session.frame.x, right: session.frame.x + session.frame.width)
                let top = PDFRectangle(x: session.frame.x, y: session.original.y, width: session.frame.width, height: session.original.height)
                changeContent(String(localized: "Resize Text"), pageIndex: pageIndex, following: top) { try $0.replaceText(ofBlock: id, onPageAt: pageIndex, with: text, restyle: box) }
                return
            }
            let dx = session.frame.x - session.original.x, dy = session.frame.y - session.original.y
            changeContent(String(localized: "Move Text"), pageIndex: pageIndex, following: session.frame) { try $0.moveText(ofBlock: id, onPageAt: pageIndex, dx: dx, dy: dy) }
        case .image(_, let id):
            guard let placement = session.placement, placement != session.originalPlacement else { return }
            let name = switch session.mode {
            case .moving: String(localized: "Move Picture")
            case .resizing: String(localized: "Resize Picture")
            case .rotating: String(localized: "Rotate Picture")
            }
            changeContent(name, pageIndex: pageIndex, following: placement.frame) { try $0.setImagePlacement(placement, ofImage: id, onPageAt: pageIndex) }
        }
    }

    /// Moves a frame onto the nearest lines other things on the page lie on.
    private func snapped(_ frame: PDFRectangle, target: ContentTarget, in content: PageContent) -> (PDFRectangle, [Double], [Double]) {
        let page = content.geometry.displaySize
        var others: [PDFRectangle] = []
        for block in content.blocks where target != .block(pageIndex: target.pageIndex, id: block.id) { others.append(block.frame) }
        for image in content.images where target != .image(pageIndex: target.pageIndex, id: image.id) { others.append(image.frame) }
        // Many small pieces of text would put a guide everywhere; the nearest few are enough.
        others = Array(others.sorted { abs($0.y - frame.y) + abs($0.x - frame.x) < abs($1.y - frame.y) + abs($1.x - frame.x) }.prefix(40))

        var xs = [page.width / 2], ys = [page.height / 2]
        for other in others {
            xs += [other.x, other.x + other.width / 2, other.x + other.width]
            ys += [other.y, other.y + other.height / 2, other.y + other.height]
        }
        let reach = 5 / max(Double(pdfView.scaleFactor), 0.1)
        func nearest(_ lines: [Double], to edges: [Double]) -> (shift: Double, line: Double)? {
            var best: (shift: Double, line: Double)?
            for line in lines {
                for edge in edges where abs(line - edge) <= reach && abs(line - edge) < abs(best?.shift ?? .infinity) {
                    best = (line - edge, line)
                }
            }
            return best
        }
        var result = frame
        var vertical: [Double] = [], horizontal: [Double] = []
        if let hit = nearest(xs, to: [frame.x, frame.x + frame.width / 2, frame.x + frame.width]) {
            result.x += hit.shift
            vertical = [hit.line]
        }
        if let hit = nearest(ys, to: [frame.y, frame.y + frame.height / 2, frame.y + frame.height]) {
            result.y += hit.shift
            horizontal = [hit.line]
        }
        return (result, vertical, horizontal)
    }

    /// A picture of part of a page, as it looks now.
    func snapshot(of frame: PDFRectangle, pageIndex: Int) -> CGImage? {
        guard let page = document?.page(at: pageIndex), frame.width > 0, frame.height > 0 else { return nil }
        let scale = min(max(Double(pdfView.scaleFactor) * Double(pdfView.window?.backingScaleFactor ?? 2), 1), 6)
        let width = Int((frame.width * scale).rounded(.up)), height = Int((frame.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height < 36_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -frame.x, y: -frame.y)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// The color of the page where a frame's corner is, for covering what is being changed.
    func pageColor(around frame: PDFRectangle, pageIndex: Int) -> NSColor {
        guard let image = snapshot(of: PDFRectangle(x: frame.x - 1.5, y: frame.y + frame.height + 0.5, width: 1, height: 1), pageIndex: pageIndex),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) >= 4
        else { return .white }
        return NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }

    // MARK: Changing pages

    /// Makes a change to what a page draws, and keeps the selection on the thing changed.
    ///
    /// - Parameter frame: Where the selected thing is after the change, when it is still there.
    @discardableResult
    func changeContent(
        _ name: String, pageIndex: Int, coalescing key: String? = nil, following frame: PDFRectangle? = nil,
        _ change: (inout PDFEditor) throws -> Void
    ) -> Bool {
        guard let sheafDocument else { return false }
        let wasBlock = if case .block = contentSelection { true } else { false }
        let done = sheafDocument.apply(name, coalescing: key) { editor, effect in
            try change(&editor)
            effect.pages = [pageIndex]
            // PDFKit only sees a change to what a page draws by reading the document again.
            effect.reloadsDisplay = true
            return true
        } ?? false
        guard done else { return false }
        if let frame, let content = content(ofPage: pageIndex) {
            // A block's number is its place among the page's blocks, which an edit can change.
            func distance(_ other: PDFRectangle) -> Double { abs(other.x - frame.x) + abs(other.y + other.height - frame.y - frame.height) }
            if wasBlock, let block = content.blocks.min(by: { distance($0.frame) < distance($1.frame) }) {
                contentSelection = .block(pageIndex: pageIndex, id: block.id)
            } else if !wasBlock, let image = content.images.min(by: { distance($0.frame) < distance($1.frame) }) {
                contentSelection = .image(pageIndex: pageIndex, id: image.id)
            }
        }
        // Shown at once, not a moment later when the window notices the document changed.
        show(sheafDocument)
        return true
    }

    func deleteContentSelection() {
        guard let target = contentSelection else { return }
        contentSelection = nil
        switch target {
        case .block(let pageIndex, let id):
            changeContent(String(localized: "Delete Text"), pageIndex: pageIndex) { try $0.removeText(ofBlock: id, onPageAt: pageIndex) }
        case .image(let pageIndex, let id):
            changeContent(String(localized: "Delete Picture"), pageIndex: pageIndex) { try $0.removeImage(id, onPageAt: pageIndex) }
        }
    }

    func nudgeContentSelection(dx: Double, dy: Double) {
        guard let target = contentSelection else { return }
        let pageIndex = target.pageIndex
        switch target {
        case .block(_, let id):
            guard let block = selectedBlock, block.isEditable else { return }
            var frame = block.frame
            frame.x += dx
            frame.y += dy
            changeContent(String(localized: "Move Text"), pageIndex: pageIndex, coalescing: "nudge-text", following: frame) {
                try $0.moveText(ofBlock: id, onPageAt: pageIndex, dx: dx, dy: dy)
            }
        case .image(_, let id):
            guard let image = selectedImage, image.isEditable else { return }
            var frame = image.frame
            frame.x += dx
            frame.y += dy
            changeContent(String(localized: "Move Picture"), pageIndex: pageIndex, coalescing: "nudge-picture", following: frame) {
                try $0.setImageFrame(frame, ofImage: id, onPageAt: pageIndex)
            }
        }
    }

    // MARK: Text

    func beginEditing(_ block: TextBlock, pageIndex: Int) {
        guard block.isEditable else {
            NSSound.beep()
            return
        }
        contentDrag = nil
        pdfView.beginContentEditing(block, pageIndex: pageIndex)
    }

    /// Stores what was typed over a block of text.
    ///
    /// - Parameter box: The sides of the editor, on the page as displayed, when it was
    ///   made narrower or wider while typing. The lines are fitted to it.
    func commitContentText(_ text: String, block: TextBlock, pageIndex: Int, box: (left: Double, right: Double)? = nil) {
        guard text != block.flowingText || box != nil else { return }
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlank { contentSelection = nil }
        let restyle = TextRestyle(left: box?.left, right: box?.right)
        var frame = block.frame
        if let box { (frame.x, frame.width) = (box.left, box.right - box.left) }
        let name = isBlank ? String(localized: "Delete Text") : text == block.flowingText ? String(localized: "Resize Text") : String(localized: "Edit Text")
        changeContent(name, pageIndex: pageIndex, following: isBlank ? nil : frame) {
            try $0.replaceText(ofBlock: block.id, onPageAt: pageIndex, with: text, restyle: restyle)
        }
    }

    /// Adds what was typed with the text tool to the page.
    ///
    /// - Parameter origin: The top left corner of the text, on the page as displayed.
    ///   - width: Where lines wrap. `nil` keeps each paragraph on one line.
    func commitNewContentText(_ text: String, at origin: PDFPoint, width: Double? = nil, pageIndex: Int, style: NewTextStyle) {
        editTool = .select
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let added = changeContent(String(localized: "Add Text"), pageIndex: pageIndex) {
            try $0.addText(text, toPageAt: pageIndex, at: origin, width: width, fontName: style.fontName, fontSize: style.fontSize, color: style.color)
        }
        // The new text is the block that starts nearest to where it was typed.
        guard added, let content = content(ofPage: pageIndex) else { return }
        let block = content.blocks.min { abs($0.frame.x - origin.x) + abs($0.frame.y + $0.frame.height - origin.y) < abs($1.frame.x - origin.x) + abs($1.frame.y + $1.frame.height - origin.y) }
        if let block { contentSelection = .block(pageIndex: pageIndex, id: block.id) }
    }

    /// Sets the selected block again in another font, size or color.
    func restyleSelectedBlock(_ name: String, coalescing key: String? = nil, _ restyle: TextRestyle) {
        guard case .block(let pageIndex, let id) = contentSelection, let block = selectedBlock, block.isEditable else { return }
        changeContent(name, pageIndex: pageIndex, coalescing: key, following: block.frame) { editor in
            if let color = restyle.color, restyle == TextRestyle(color: color) {
                // Only the color: every glyph stays exactly where it is.
                try editor.setTextColor(color, ofBlock: id, onPageAt: pageIndex)
            } else {
                try editor.replaceText(ofBlock: id, onPageAt: pageIndex, with: block.flowingText, restyle: restyle)
            }
        }
    }

    // MARK: Pictures

    static let pictureTypes: [UTType] = [.jpeg, .png, .heic, .tiff, .gif, .bmp, .webP]

    /// The page a new thing goes on, and the middle of what is visible of it, as displayed.
    private func placeForNewContent() -> (pageIndex: Int, center: PDFPoint)? {
        guard let page = pdfView.currentPage, let document else { return nil }
        let pageIndex = document.index(for: page)
        guard let geometry = content(ofPage: pageIndex)?.geometry else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let visible = pdfView.convert(pdfView.bounds, to: page).intersection(bounds)
        let area = visible.isNull || visible.isEmpty ? bounds : visible
        return (pageIndex, geometry.displayPoint(PDFPoint(x: area.midX, y: area.midY)))
    }

    /// Adds a picture to a page, centered on a point, and selects it.
    ///
    /// - Parameter center: On the page as displayed. `nil` is the middle of what is in view.
    /// - Parameter tool: For a picture a generative model made, its name, which the picture
    ///   then carries in its metadata.
    func addPicture(_ data: Data, pageIndex: Int? = nil, center: PDFPoint? = nil, generatedBy tool: String? = nil) {
        guard let place = placeForNewContent() else { return }
        let pageIndex = pageIndex ?? place.pageIndex
        guard let page = content(ofPage: pageIndex)?.geometry.displaySize else { return }
        let center = center ?? place.center
        isContentEditing = true
        editTool = .select
        var placed: PDFRectangle?
        let added = changeContent(String(localized: "Add Picture"), pageIndex: pageIndex) { editor in
            // At its natural size, but no more than half the page, then moved to the spot.
            var frame = try editor.addImage(data, toPageAt: pageIndex, generatedBy: tool)
            let scale = min(1, page.width * 0.5 / frame.width, page.height * 0.5 / frame.height)
            frame.width *= scale
            frame.height *= scale
            frame.x = min(max(center.x - frame.width / 2, 0), max(page.width - frame.width, 0))
            frame.y = min(max(center.y - frame.height / 2, 0), max(page.height - frame.height, 0))
            guard let id = try editor.pageContent(at: pageIndex).images.last?.id else { return }
            try editor.setImageFrame(frame, ofImage: id, onPageAt: pageIndex)
            placed = frame
        }
        guard added, let placed, let content = content(ofPage: pageIndex) else { return }
        let image = content.images.min { abs($0.frame.x - placed.x) + abs($0.frame.y - placed.y) < abs($1.frame.x - placed.x) + abs($1.frame.y - placed.y) }
        if let image { contentSelection = .image(pageIndex: pageIndex, id: image.id) }
    }

    /// Asks for a picture file and adds it to the page being read.
    func choosePictureToAdd() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.pictureTypes
        panel.message = String(localized: "Choose a picture to add to the page.")
        panel.prompt = String(localized: "Add")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            self?.addPicture(data)
        }
    }

    /// Asks for a picture file and puts it in the selected picture's place.
    func chooseReplacementPicture() {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.pictureTypes
        panel.message = String(localized: "Choose a picture to put in this one's place.")
        panel.prompt = String(localized: "Replace")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            self?.changeContent(String(localized: "Replace Picture"), pageIndex: pageIndex, following: image.frame) {
                try $0.replaceImage(id, onPageAt: pageIndex, with: data)
            }
        }
    }

    // MARK: Pasteboard

    /// Whether the pasteboard holds something that can go on a page.
    var canPasteContent: Bool {
        guard sheafDocument?.isEditable == true else { return false }
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) || pasteboard.string(forType: .string)?.isEmpty == false
    }

    /// Puts the pasteboard's picture or text on the page being read.
    func pasteContent() {
        let pasteboard = NSPasteboard.general
        if let data = Self.pictureData(from: pasteboard) {
            addPicture(data)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty, let place = placeForNewContent() {
            isContentEditing = true
            let style = newTextStyle
            // Roughly centered on the middle of what is in view.
            let origin = PDFPoint(x: max(place.center.x - 120, 18), y: place.center.y + style.fontSize)
            commitNewContentText(text, at: origin, pageIndex: place.pageIndex, style: style)
        }
    }

    func copyContentSelection() {
        if selectedImage != nil {
            if !copySelectedPicture() { NSSound.beep() }
            return
        }
        guard let block = selectedBlock else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.text, forType: .string)
    }

    /// A picture from a pasteboard, as the bytes of an image file.
    static func pictureData(from pasteboard: NSPasteboard) -> Data? {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: pictureTypes.map(\.identifier)]) as? [URL])?.first,
           let data = try? Data(contentsOf: url) {
            return data
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return data }
        }
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first { return image.tiffRepresentation }
        return nil
    }

    /// Moves the selection to the next piece of text or picture on the page, in reading
    /// order, so the page can be worked through from the keyboard.
    func selectNextContent(backwards: Bool = false) {
        guard editTool == .select else { return }
        let pageIndex = contentSelection?.pageIndex ?? currentPageIndex
        guard let content = content(ofPage: pageIndex) else { return }
        // From the top of the page down, and from the left on each row.
        var targets: [(target: ContentTarget, frame: PDFRectangle)] = content.blocks.map { (.block(pageIndex: pageIndex, id: $0.id), $0.frame) }
            + content.images.map { (.image(pageIndex: pageIndex, id: $0.id), $0.frame) }
        targets.sort { a, b in
            let topA = a.frame.y + a.frame.height, topB = b.frame.y + b.frame.height
            return abs(topA - topB) > 4 ? topA > topB : a.frame.x < b.frame.x
        }
        guard !targets.isEmpty else { return }
        let current = targets.firstIndex { $0.target == contentSelection }
        let next = current.map { ($0 + (backwards ? -1 : 1) + targets.count) % targets.count } ?? (backwards ? targets.count - 1 : 0)
        selection = nil
        contentSelection = targets[next].target
        // Bring it into view if it is not.
        if let page = document?.page(at: pageIndex), let rect = viewRect(targets[next].frame, pageIndex: pageIndex), !pdfView.bounds.contains(rect) {
            pdfView.go(to: content.geometry.pageRect(targets[next].frame).cgRect.insetBy(dx: -40, dy: -80), on: page)
        }
    }

    /// What VoiceOver says about the selected text or picture.
    var contentSelectionDescription: String? {
        if let block = selectedBlock {
            let text = block.text.replacingOccurrences(of: "\n", with: " ")
            return String(localized: "Text: \(String(text.prefix(200)))")
        }
        if let image = selectedImage {
            return String(localized: "Picture, \(Int(image.frame.width)) by \(Int(image.frame.height)) points")
        }
        return nil
    }

    // MARK: Keyboard

    /// Handles a key press on the page while editing content. Returns `false` to pass it on.
    func handleContentKey(_ event: NSEvent) -> Bool {
        guard isContentEditing else { return false }
        if maskEdit != nil {
            // Return keeps the mask, Escape leaves it as it was; nothing else happens meanwhile.
            switch event.keyCode {
            case 36, 76: endMaskEditing(commit: true)
            case 53: endMaskEditing(commit: false)
            default: return !event.modifierFlags.contains(.command)
            }
            return true
        }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            guard contentSelection != nil else { return false }
            deleteContentSelection()
        case 53: // escape
            guard contentSelection != nil || editTool != .select else { return false }
            contentSelection = nil
            editTool = .select
        case 36, 76: // return, enter
            if selectedImage?.isEditable == true {
                beginMaskEditing()
                return true
            }
            guard case .block(let pageIndex, _) = contentSelection, let block = selectedBlock else { return false }
            beginEditing(block, pageIndex: pageIndex)
        case 48: // tab
            selectNextContent(backwards: event.modifierFlags.contains(.shift))
        case 123 where contentSelection != nil: nudgeContentSelection(dx: -step, dy: 0)
        case 124 where contentSelection != nil: nudgeContentSelection(dx: step, dy: 0)
        case 125 where contentSelection != nil: nudgeContentSelection(dx: 0, dy: -step)
        case 126 where contentSelection != nil: nudgeContentSelection(dx: 0, dy: step)
        default: return false
        }
        return true
    }
}
