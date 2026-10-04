import AppKit
import PDFKit
import SheafKit

/// Where on the page something is lined up.
enum PageAlignment: String, CaseIterable, Identifiable {
    case left, center, right, top, middle, bottom

    var id: Self { self }

    var title: String {
        switch self {
        case .left: String(localized: "Left")
        case .center: String(localized: "Center")
        case .right: String(localized: "Right")
        case .top: String(localized: "Top")
        case .middle: String(localized: "Middle")
        case .bottom: String(localized: "Bottom")
        }
    }

    var systemImage: String {
        switch self {
        case .left: "align.horizontal.left"
        case .center: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .middle: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }
}

extension StackingMove {
    var title: String {
        switch self {
        case .toFront: String(localized: "Bring to Front")
        case .forward: String(localized: "Bring Forward")
        case .backward: String(localized: "Send Backward")
        case .toBack: String(localized: "Send to Back")
        }
    }

    var systemImage: String {
        switch self {
        case .toFront: "square.3.layers.3d.top.filled"
        case .forward: "square.2.layers.3d.top.filled"
        case .backward: "square.2.layers.3d.bottom.filled"
        case .toBack: "square.3.layers.3d.bottom.filled"
        }
    }
}

/// A picture's mask being changed: which part of the whole picture shows.
struct MaskEdit {
    var pageIndex: Int
    var imageID: Int
    /// Where the whole picture is, masked or not.
    var whole: ImagePlacement
    /// The part that shows, in fractions of the whole from its bottom left corner.
    var part: PDFRectangle
    var original: PDFRectangle
    /// The whole picture as the file has it, to show what the mask hides.
    var picture: CGImage?
    /// What a drag in progress started from. A handle resizes the part; none moves it.
    var drag: (handle: ResizeHandle?, start: PDFPoint, part: PDFRectangle)?

    /// Where the part that shows is on the page.
    var placement: ImagePlacement {
        var shown = whole
        shown.center = whole.point(atFractionX: part.x + part.width / 2, y: part.y + part.height / 2)
        shown.width = whole.width * part.width
        shown.height = whole.height * part.height
        return shown
    }
}

/// Arranging the text and pictures on a page: their stacking order, where they line up,
/// and the things a picture can have done to it.
extension ViewerModel {
    // MARK: Stacking order

    /// The moves that would change how the selection is stacked. Things on a page cover
    /// what was drawn before them; a move only counts when something overlaps.
    var stackingMoves: Set<StackingMove> {
        guard let sheafDocument, sheafDocument.isEditable, let editor = sheafDocument.editor else { return [] }
        let key: String
        if let target = contentSelection, isContentEditing {
            key = "\(sheafDocument.revision)/\(sheafDocument.generation)/\(target)"
        } else if let selection, selectedAnnotation?.subtype != "Widget" {
            key = "\(sheafDocument.revision)/\(sheafDocument.generation)/\(selection.pageIndex)/\(selection.id)"
        } else {
            return []
        }
        if let cached = stackingCache, cached.key == key { return cached.moves }
        var moves: Set<StackingMove> = []
        if isContentEditing, let target = contentSelection {
            switch target {
            case .block(let pageIndex, let id): moves = (try? editor.stackingMoves(forBlock: id, onPageAt: pageIndex)) ?? []
            case .image(let pageIndex, let id): moves = (try? editor.stackingMoves(forImage: id, onPageAt: pageIndex)) ?? []
            }
        } else if let selection {
            moves = (try? editor.stackingMoves(forAnnotation: selection.id, onPageAt: selection.pageIndex)) ?? []
        }
        stackingCache = (key, moves)
        return moves
    }

    func restackSelection(_ move: StackingMove) {
        guard stackingMoves.contains(move) else { return }
        if isContentEditing, let target = contentSelection {
            switch target {
            case .block(let pageIndex, let id):
                changeContent(move.title, pageIndex: pageIndex, following: selectedBlock?.frame) { try $0.restack(block: id, onPageAt: pageIndex, move) }
            case .image(let pageIndex, let id):
                let frame = selectedImage?.frame
                changeContent(move.title, pageIndex: pageIndex) { try $0.restack(image: id, onPageAt: pageIndex, move) }
                // Pictures are numbered in the order they are drawn, which just changed.
                if let frame, let images = content(ofPage: pageIndex)?.images {
                    func distance(_ image: PageImage) -> Double { abs(image.frame.x - frame.x) + abs(image.frame.y - frame.y) + abs(image.frame.width - frame.width) }
                    let nearest = images.map(distance).min() ?? 0
                    let same = images.filter { distance($0) <= nearest + 0.01 }
                    // Of pictures in the very same place, the one moved is now the first or the last.
                    let found = move == .toBack || move == .backward ? same.first : same.last
                    if let found { contentSelection = .image(pageIndex: pageIndex, id: found.id) }
                }
            }
        } else if let selection {
            sheafDocument?.apply(move.title) { editor, effect in
                effect.pages = [selection.pageIndex]
                try editor.restack(annotation: selection.id, onPageAt: selection.pageIndex, move)
            }
        }
    }

    // MARK: Lining up

    /// Whether the selection is text or a picture that can be moved about the page.
    var canArrangeContent: Bool {
        isContentEditing && maskEdit == nil && (selectedBlock?.isEditable == true || selectedImage?.isEditable == true)
    }

    /// Lines the selection up with an edge or the middle of the page, as Pages does with one thing selected.
    func alignSelection(_ alignment: PageAlignment) {
        guard canArrangeContent, let target = contentSelection, let page = content(ofPage: target.pageIndex)?.geometry.displaySize,
              let frame = selectedBlock?.frame ?? selectedImage?.frame
        else { return }
        var moved = frame
        switch alignment {
        case .left: moved.x = 0
        case .center: moved.x = (page.width - frame.width) / 2
        case .right: moved.x = page.width - frame.width
        case .top: moved.y = page.height - frame.height
        case .middle: moved.y = (page.height - frame.height) / 2
        case .bottom: moved.y = 0
        }
        guard abs(moved.x - frame.x) + abs(moved.y - frame.y) > 0.01 else { return }
        let pageIndex = target.pageIndex
        switch target {
        case .block(_, let id):
            changeContent(String(localized: "Align Text"), pageIndex: pageIndex, following: moved) {
                try $0.moveText(ofBlock: id, onPageAt: pageIndex, dx: moved.x - frame.x, dy: moved.y - frame.y)
            }
        case .image(_, let id):
            changeContent(String(localized: "Align Picture"), pageIndex: pageIndex, following: moved) { try $0.setImageFrame(moved, ofImage: id, onPageAt: pageIndex) }
        }
    }

    // MARK: Pictures

    func flipSelectedPicture(horizontally: Bool) {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable, maskEdit == nil else { return }
        changeContent(horizontally ? String(localized: "Flip Horizontally") : String(localized: "Flip Vertically"), pageIndex: pageIndex, following: image.frame) {
            try $0.flipImage(id, onPageAt: pageIndex, horizontally: horizontally)
        }
    }

    func setSelectedPictureOpacity(_ opacity: Double) {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable, abs(image.opacity - opacity) > 0.0005 else { return }
        changeContent(String(localized: "Change Opacity"), pageIndex: pageIndex, coalescing: "picture-opacity", following: image.frame) {
            try $0.setImageOpacity(opacity, ofImage: id, onPageAt: pageIndex)
        }
    }

    /// The whole of a picture as the file has it: upright, unmasked, a pixel for each of its own.
    func pictureImage(of image: PageImage, pageIndex: Int) -> CGImage? {
        guard let data = try? sheafDocument?.editor?.pictureDocument(forImage: image.id, onPageAt: pageIndex),
              let page = PDFDocument(data: data)?.page(at: 0)
        else { return nil }
        let box = page.bounds(for: .mediaBox)
        // Very large pictures are taken smaller; nothing here needs more.
        let scale = min(1, 4096 / max(box.width, box.height, 1))
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// What shows of the selected picture, as an image: the part inside its mask.
    private func shownPicture(of image: PageImage, pageIndex: Int) -> CGImage? {
        guard let whole = pictureImage(of: image, pageIndex: pageIndex) else { return nil }
        guard var part = image.shownPart else { return whole }
        // The part is given the way the picture shows; the file has a mirrored one the other way round.
        if image.placement.isMirrored { part.x = 1 - part.x - part.width }
        let width = Double(whole.width), height = Double(whole.height)
        // Rows of an image count from the top.
        let rect = CGRect(x: part.x * width, y: (1 - part.y - part.height) * height, width: part.width * width, height: part.height * height).integral
        return whole.cropping(to: rect) ?? whole
    }

    /// Puts the selected picture on the pasteboard. Returns whether it could.
    @discardableResult
    func copySelectedPicture() -> Bool {
        guard case .image(let pageIndex, _) = contentSelection, let image = selectedImage, let picture = shownPicture(of: image, pageIndex: pageIndex) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: picture)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = bitmap.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }

    var canCopyContentSelection: Bool { isContentEditing && (selectedBlock != nil || selectedImage != nil) }

    var canCutContentSelection: Bool { canArrangeContent }

    func cutContentSelection() {
        guard canCutContentSelection else { return }
        if selectedImage != nil {
            guard copySelectedPicture() else { return NSSound.beep() }
        } else {
            copyContentSelection()
        }
        guard let target = contentSelection else { return }
        contentSelection = nil
        switch target {
        case .block(let pageIndex, let id):
            changeContent(String(localized: "Cut"), pageIndex: pageIndex) { try $0.removeText(ofBlock: id, onPageAt: pageIndex) }
        case .image(let pageIndex, let id):
            changeContent(String(localized: "Cut"), pageIndex: pageIndex) { try $0.removeImage(id, onPageAt: pageIndex) }
        }
    }

    /// Makes a copy of the selection a little down and to the right, on top, and selects it.
    func duplicateContentSelection() {
        guard canArrangeContent, let target = contentSelection, let frame = selectedBlock?.frame ?? selectedImage?.frame,
              let page = content(ofPage: target.pageIndex)?.geometry.displaySize
        else { return }
        // Kept on the page: back the other way when there is no room.
        var dx = frame.x + frame.width + 12 <= page.width ? 12.0 : -12.0
        var dy = frame.y - 12 >= 0 ? -12.0 : 12.0
        if let block = selectedBlock {
            // Text lying over text would read as one muddle of lines, so a copy of text
            // goes clear of the original: below it, or above when there is no room.
            let gap = max(block.fontSize * 2.5, 24)
            dx = 0
            dy = frame.y - frame.height - gap >= 0 ? -(frame.height + gap) : frame.height + gap
        }
        let copy = PDFRectangle(x: frame.x + dx, y: frame.y + dy, width: frame.width, height: frame.height)
        let pageIndex = target.pageIndex
        switch target {
        case .block(_, let id):
            changeContent(String(localized: "Duplicate"), pageIndex: pageIndex, following: copy) { try $0.duplicateText(ofBlock: id, onPageAt: pageIndex, dx: dx, dy: dy) }
        case .image(_, let id):
            changeContent(String(localized: "Duplicate"), pageIndex: pageIndex) { try $0.duplicateImage(id, onPageAt: pageIndex, dx: dx, dy: dy) }
            // The copy is drawn last.
            if let last = content(ofPage: pageIndex)?.images.last { contentSelection = .image(pageIndex: pageIndex, id: last.id) }
        }
    }

    /// Puts a link over the selected text or picture, and shows it in the markup tools,
    /// where its target is set.
    func addLinkToContentSelection() {
        guard let target = contentSelection, let geometry = content(ofPage: target.pageIndex)?.geometry,
              let frame = selectedBlock?.frame ?? selectedImage?.frame
        else { return }
        let link = Annotation(kind: .link, rect: geometry.pageRect(frame))
        let pageIndex = target.pageIndex
        isMarkupVisible = true
        guard let id = add(link, pageIndex: pageIndex, name: String(localized: "Add Link")) else { return }
        selection = AnnotationSelection(pageIndex: pageIndex, id: id)
        isInspectorVisible = true
    }

    /// Takes the background out of the selected picture, leaving what it is a picture of.
    func removeBackgroundOfSelectedPicture() {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable, !isRemovingBackground,
              let sheafDocument, let picture = pictureImage(of: image, pageIndex: pageIndex)
        else { return }
        let revision = sheafDocument.revision
        isRemovingBackground = true
        Task {
            // Finding the subject takes a moment, so it is done off the main thread.
            let lifted = await Task.detached { SubjectLifter.subject(of: picture) }.value
            isRemovingBackground = false
            // The document may have changed while that ran.
            guard sheafDocument.revision == revision, contentSelection == .image(pageIndex: pageIndex, id: id) else { return }
            guard let lifted else {
                editMessage = String(localized: "No subject stands out from a background in this picture.")
                return
            }
            changeContent(String(localized: "Remove Background"), pageIndex: pageIndex, following: image.frame) {
                try $0.replaceImage(id, onPageAt: pageIndex, with: lifted, keepingShape: true)
            }
        }
    }

    // MARK: Masking

    /// Starts changing which part of the selected picture shows.
    func beginMaskEditing() {
        guard isContentEditing, case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable else { return }
        contentDrag = nil
        let part = image.shownPart ?? PDFRectangle(x: 0, y: 0, width: 1, height: 1)
        maskEdit = MaskEdit(pageIndex: pageIndex, imageID: id, whole: image.unmaskedPlacement, part: part, original: part, picture: pictureImage(of: image, pageIndex: pageIndex))
    }

    /// Stops changing the mask, keeping what was set or not.
    func endMaskEditing(commit: Bool) {
        guard let edit = maskEdit else { return }
        maskEdit = nil
        guard commit, edit.part != edit.original else { return }
        let whole = edit.part.x < 0.0005 && edit.part.y < 0.0005 && edit.part.width > 0.9995 && edit.part.height > 0.9995
        changeContent(String(localized: "Mask Picture"), pageIndex: edit.pageIndex, following: edit.placement.frame) {
            try $0.setImageMask(whole ? nil : edit.part, ofImage: edit.imageID, onPageAt: edit.pageIndex)
        }
    }

    /// Shows the whole of the selected picture again.
    func resetMask() {
        if maskEdit != nil {
            maskEdit?.part = PDFRectangle(x: 0, y: 0, width: 1, height: 1)
            endMaskEditing(commit: true)
            return
        }
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable, image.shownPart != nil else { return }
        changeContent(String(localized: "Reset Mask"), pageIndex: pageIndex, following: image.unmaskedPlacement.frame) { try $0.setImageMask(nil, ofImage: id, onPageAt: pageIndex) }
    }

    /// A press of the mouse while a mask is being changed. A handle resizes the part
    /// that shows, inside it moves it over the picture, and outside the picture is done.
    func maskMouseDown(at point: PDFPoint, pageIndex: Int) {
        guard var edit = maskEdit else { return }
        guard pageIndex == edit.pageIndex else { return endMaskEditing(commit: true) }
        let shown = edit.placement
        let reach = 7 / max(Double(pdfView.scaleFactor), 0.1)
        let handle = ResizeHandle.frameHandles.first { handle in
            guard let anchor = handle.anchor else { return false }
            let at = shown.point(atFractionX: anchor.x, y: anchor.y)
            return abs(at.x - point.x) <= reach && abs(at.y - point.y) <= reach
        }
        if handle == nil, !edit.whole.contains(point) { return endMaskEditing(commit: true) }
        edit.drag = (handle, point, edit.part)
        maskEdit = edit
    }

    func maskMouseDragged(to point: PDFPoint) {
        guard var edit = maskEdit, let drag = edit.drag, edit.whole.width > 0, edit.whole.height > 0 else { return }
        // Along the picture's own sides, as fractions of it.
        func fraction(_ point: PDFPoint) -> PDFPoint {
            let local = edit.whole.local(point)
            return PDFPoint(x: local.x / edit.whole.width + 0.5, y: local.y / edit.whole.height + 0.5)
        }
        let now = fraction(point), start = fraction(drag.start)
        var part = drag.part
        if let anchor = drag.handle?.anchor {
            var (left, bottom, right, top) = (part.x, part.y, part.x + part.width, part.y + part.height)
            let minimum = 0.02
            if anchor.x == 0 { left = min(max(now.x, 0), right - minimum) }
            if anchor.x == 1 { right = max(min(now.x, 1), left + minimum) }
            if anchor.y == 0 { bottom = min(max(now.y, 0), top - minimum) }
            if anchor.y == 1 { top = max(min(now.y, 1), bottom + minimum) }
            part = PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom)
        } else {
            part.x = min(max(part.x + now.x - start.x, 0), 1 - part.width)
            part.y = min(max(part.y + now.y - start.y, 0), 1 - part.height)
        }
        edit.part = part
        maskEdit = edit
    }

    func maskMouseUp() {
        maskEdit?.drag = nil
    }
}
