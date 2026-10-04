import AppKit
import PDFKit
import SheafKit

/// Draws the annotations of one page as the vectors they are, over PDFKit's page.
///
/// PDFKit puts one of these on every page it shows and moves and zooms it along with
/// the page. Each annotation is a layer holding a picture drawn at the zoom in use, and
/// drawn again when the zoom changes, so a signature stays sharp at any size.
final class PageAnnotationView: NSView {
    private weak var pdfView: SheafPDFView?
    private weak var page: PDFPage?

    private struct Drawn {
        var layer: CALayer
        var item: SharpAnnotation
        /// The pixels per point the picture was drawn with.
        var scale: CGFloat
    }

    private var drawn: [String: Drawn] = [:]
    private var pending: DispatchWorkItem?

    init(pdfView: SheafPDFView, page: PDFPage) {
        self.pdfView = pdfView
        self.page = page
        super.init(frame: .zero)
        // The view holds layers of its own making, not drawing of its own.
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PageAnnotationView is created in code")
    }

    // Clicks go to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the page's annotations as they are now.
    func reload() {
        guard let pdfView, let viewer = pdfView.viewer, let page, let document = pdfView.document, document === page.document, let layer else {
            clear()
            return
        }
        let items = viewer.sharpAnnotations(onPage: document.index(for: page))
        // Page space to this view. PDFKit turns the view along with a turned page, so
        // only the corner of what shows of the page has to be taken off.
        let box = page.bounds(for: .cropBox)
        let transform = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        let scale = pictureScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var kept: [String: Drawn] = [:]
        for (order, item) in items.enumerated() {
            var entry = drawn[item.key] ?? Drawn(layer: CALayer(), item: item, scale: 0)
            if entry.layer.superlayer == nil {
                entry.layer.contentsGravity = .resize
                entry.layer.magnificationFilter = .linear
                layer.addSublayer(entry.layer)
            }
            entry.layer.zPosition = CGFloat(order)
            if entry.item != item || entry.scale == 0 || isStale(entry.scale, for: scale) {
                entry.item = item
                entry.scale = draw(item, into: entry.layer, through: transform, at: scale)
            }
            kept[item.key] = entry
        }
        for (key, entry) in drawn where kept[key] == nil { entry.layer.removeFromSuperlayer() }
        drawn = kept
        CATransaction.commit()
    }

    private func clear() {
        for entry in drawn.values { entry.layer.removeFromSuperlayer() }
        drawn = [:]
    }

    /// Draws the pictures again a moment after the zoom changed. While it is changing
    /// the pictures there are stretch with the page, which looks right in motion.
    func zoomChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The pixels to a point of the page that a picture needs to look sharp now.
    private var pictureScale: CGFloat {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return max(backing * (pdfView?.scaleFactor ?? 1), 1)
    }

    private func isStale(_ old: CGFloat, for new: CGFloat) -> Bool {
        abs(old - new) > 0.04 * new
    }

    /// Draws an annotation into a layer and puts the layer where the annotation is.
    ///
    /// - Returns: The scale asked for, so the picture is not drawn again until that changes.
    private func draw(_ item: SharpAnnotation, into target: CALayer, through transform: CGAffineTransform, at wanted: CGFloat) -> CGFloat {
        let place = item.frame.applying(transform)
        target.frame = place
        target.contents = nil
        guard place.width > 0, place.height > 0, place.width.isFinite, place.height.isFinite,
              let provider = CGDataProvider(data: item.look as CFData), let look = CGPDFDocument(provider)?.page(at: 1)
        else { return wanted }
        let size = look.getBoxRect(.mediaBox).size
        guard size.width > 0, size.height > 0 else { return wanted }
        // A very large annotation at a very high zoom is drawn a little coarser, to keep
        // the picture within what memory and the graphics card take.
        let limit = min(8192 / max(place.width, place.height), (24_000_000 / (place.width * place.height)).squareRoot())
        let scale = max(min(wanted, limit), 0.25)
        let width = Int((place.width * scale).rounded(.up)), height = Int((place.height * scale).rounded(.up))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return wanted }
        context.scaleBy(x: CGFloat(width) / place.width, y: CGFloat(height) / place.height)
        context.translateBy(x: -place.minX, y: -place.minY)
        context.concatenate(transform)
        // The look is a page the size of the annotation, stretched onto where it is.
        context.translateBy(x: item.frame.minX, y: item.frame.minY)
        context.scaleBy(x: item.frame.width / size.width, y: item.frame.height / size.height)
        context.drawPDFPage(look)
        target.contents = context.makeImage()
        return wanted
    }
}

extension SheafPDFView: PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PageAnnotationView(pdfView: self, page: page)
        annotationViews.add(overlay)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        (overlayView as? PageAnnotationView)?.reload()
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        (overlayView as? PageAnnotationView).map(annotationViews.remove)
    }

    /// Draws the annotations of the pages in view again, after the document or a drag changed them.
    func refreshAnnotationViews() {
        for view in annotationViews.allObjects { view.reload() }
    }
}
