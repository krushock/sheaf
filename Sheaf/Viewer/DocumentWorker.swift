import AppKit
import PDFKit

/// Does slow, read-only work on a private copy of the document, off the main actor.
///
/// PDFKit objects are not safe to share between threads, so this actor parses its own
/// `PDFDocument` from the same bytes and only hands back plain values.
actor DocumentWorker {
    private let document: PDFDocument?

    init(data: Data, password: String?) {
        let document = PDFDocument(data: data)
        if let document, let password {
            document.unlock(withPassword: password)
        }
        self.document = document
    }

    /// A page rendered with its annotations, at most `maxPixelSize` on its long side.
    func thumbnail(pageIndex: Int, maxPixelSize: CGFloat) -> CGImage? {
        guard let page = document?.page(at: pageIndex) else { return nil }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxPixelSize / max(size.width, size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return page.thumbnail(of: target, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
