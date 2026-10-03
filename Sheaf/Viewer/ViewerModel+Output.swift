import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Printing and exporting.
extension ViewerModel {
    static let exportImageTypes: [UTType] = [.png, .jpeg, .tiff, .heic]
    /// Pixels per inch for exported page images.
    static let exportResolution: CGFloat = 144

    func printDocument() {
        guard let document, let window,
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo,
              let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true)
        else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// File > Export: a copy of the document as PDF, or the current page as an image.
    func export() {
        guard let window, document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf] + Self.exportImageTypes
        panel.showsContentTypes = true
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (window.title as NSString).deletingPathExtension
        panel.message = String(localized: "Image formats export the current page.")
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let type = panel.currentContentType ?? UTType(filenameExtension: url.pathExtension) ?? .pdf
            do {
                try write(to: url, as: type)
            } catch {
                window.presentError(error)
            }
        }
    }

    func write(to url: URL, as type: UTType) throws {
        if type.conforms(to: .pdf) {
            guard let sourceData else { throw CocoaError(.fileWriteUnknown) }
            try sourceData.write(to: url, options: .atomic)
            return
        }
        guard let page = document?.page(at: currentPageIndex) else { throw CocoaError(.fileWriteUnknown) }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let scale = Self.exportResolution / 72
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let image = page.thumbnail(of: pixels, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: Self.exportResolution,
            kCGImagePropertyDPIHeight: Self.exportResolution,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
