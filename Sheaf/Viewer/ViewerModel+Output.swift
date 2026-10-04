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
        // Printed from the document as it would be saved, read afresh: the one on screen
        // has the annotations Sheaf draws itself switched off.
        guard let window, let sourceData, let document = PDFDocument(data: sourceData),
              sheafDocument?.password.map(document.unlock(withPassword:)) ?? true,
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo,
              let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true)
        else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// File > Export: a copy of the document as PDF, with the options Preview's save
    /// dialog has, or the page being read as a picture.
    func export() {
        guard let window, document != nil, let sourceData else { return }
        let panel = NSSavePanel()
        let options = SaveOptionsModel(showsFormat: true)
        panel.allowedContentTypes = [options.format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (window.title as NSString).deletingPathExtension
        panel.accessoryView = options.accessoryView()
        // The name takes the extension of the format as it is chosen.
        options.onFormatChange = { [weak panel] format in panel?.allowedContentTypes = [format.contentType] }
        let source = Toolbox.Source(data: sourceData, name: documentName, password: sheafDocument?.password)
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do {
                if options.format == .pdf {
                    let chosen = options.pdfOptions
                    if chosen.isPlain {
                        try sourceData.write(to: url, options: .atomic)
                    } else {
                        // Pictures may be made smaller, which takes a while on a long document.
                        activeSheet = .working
                        defer { activeSheet = nil }
                        let data = try await Task.detached(priority: .userInitiated) { try Toolbox.save(source, with: chosen).data }.value
                        try data.write(to: url, options: .atomic)
                    }
                } else {
                    try writePicture(to: url, as: options.format.contentType, resolution: min(max(options.resolution, 18), 1200), quality: options.quality)
                }
            } catch {
                window.presentError(error)
            }
        }
    }

    /// The page being read as a picture file, annotations included.
    private func writePicture(to url: URL, as type: UTType, resolution: Double, quality: Double) throws {
        // From the document as it would be saved, read afresh: the one on screen has
        // the annotations Sheaf draws itself switched off.
        guard let sourceData, let fresh = PDFDocument(data: sourceData),
              sheafDocument?.password.map(fresh.unlock(withPassword:)) ?? true,
              let page = fresh.page(at: currentPageIndex),
              let data = Toolbox.image(of: page, as: type, resolution: resolution, quality: quality)
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
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
        let drawn = sheafDocument?.withAllAnnotationsDrawnByPDFKit(onPage: currentPageIndex) {
            page.thumbnail(of: pixels, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
        } ?? nil
        guard let image = drawn,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: Self.exportResolution,
            kCGImagePropertyDPIHeight: Self.exportResolution,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Tools > Compare with…: this document as the original, and another to be chosen as the revised one.
    func compareWithAnother() {
        guard let sheafDocument else { return }
        let original = CompareSource(data: sheafDocument.currentData, name: window?.title ?? documentName, password: sheafDocument.password)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = String(localized: "Choose the document to compare this one with.")
        panel.prompt = String(localized: "Compare")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = CompareModel.read(url)
        if let message = result.message {
            editMessage = message
            return
        }
        guard let revised = result.source else { return }
        ToolInbox.shared.compare(original: original, revised: revised)
    }
}
