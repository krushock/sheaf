import AppKit
import ImageIO
import PDFKit
import SheafKit
import UniformTypeIdentifiers

/// The file tools as plain functions on bytes, shared by the windows, the menus and
/// Shortcuts. None of them touch the screen, so they can run off the main thread.
nonisolated enum Toolbox {
    /// One file handed to a tool.
    struct Source: Sendable {
        var data: Data
        /// The file's name without its extension.
        var name: String
        var password: String?

        init(data: Data, name: String, password: String? = nil) {
            self.data = data
            self.name = name
            self.password = password
        }

        /// Reads a file the user picked or dropped.
        init(url: URL) throws {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            self.init(data: try Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        }

        var isPDF: Bool { data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil }

        func editor() throws -> PDFEditor {
            do {
                return PDFEditor(try PDFFile(data: data, password: password))
            } catch SheafError.passwordRequired {
                throw ToolError.protectedSource
            } catch SheafError.incorrectPassword {
                throw password == nil ? ToolError.protectedSource : ToolError.wrongPassword
            } catch {
                throw ToolError.unreadable(name)
            }
        }
    }

    // MARK: Joining and making

    /// Joins PDFs, and pictures as pages, in the order given.
    static func merge(_ sources: [Source], bookmarksPerDocument: Bool = true) throws -> Data {
        guard !sources.isEmpty else { throw ToolError.nothingToDo }
        let parts = try sources.map { source -> MergeSource in
            if source.isPDF { return MergeSource(document: try source.editor(), title: source.name) }
            let page = try PDFGenerator.document(fromImageData: source.data)
            return MergeSource(document: PDFEditor(try PDFFile(data: page)), title: source.name)
        }
        return try PDFGenerator.merged(parts, bookmarksPerDocument: bookmarksPerDocument)
    }

    /// A document with one page per picture.
    ///
    /// - Parameter straightens: Looks for a sheet of paper in each picture and, where it
    ///   finds one, uses the sheet squared up instead of the whole photograph.
    static func document(fromImages images: [Data], options: ImageDocumentOptions = ImageDocumentOptions(), straightens: Bool = false) throws -> Data {
        guard !images.isEmpty else { throw ToolError.nothingToDo }
        let pictures = straightens ? images.map { DocumentStraightener.straightened($0) ?? $0 } : images
        return try PDFGenerator.document(fromImages: pictures, options: options)
    }

    // MARK: Changing one document

    static func compress(_ source: Source, options: CompressionOptions, progress: (@Sendable (Double) -> Bool)? = nil) throws -> Data {
        try source.editor().compressed(options, progress: progress)
    }

    static func split(_ source: Source, into parts: [SplitPart]) throws -> [Data] {
        let editor = try source.editor()
        return try parts.map { try editor.extractingPages($0.pageIndexes) }
    }

    static func extract(_ source: Source, pages: String) throws -> Data {
        let editor = try source.editor()
        return try editor.extractingPages(try PageRanges.parse(pages, pageCount: try editor.pageCount()))
    }

    static func protect(_ source: Source, userPassword: String, ownerPassword: String? = nil, permissions: Permissions = .all) throws -> Data {
        try source.editor().rewritten(protection: .password(user: userPassword, owner: ownerPassword, permissions: permissions))
    }

    static func unprotect(_ source: Source) throws -> Data {
        try source.editor().rewritten(protection: .none)
    }

    /// Applies a change and gives back the whole document, written by appending.
    static func edit(_ source: Source, _ change: (inout PDFEditor) throws -> Void) throws -> Data {
        var editor = try source.editor()
        try change(&editor)
        return try editor.serialized()
    }

    // MARK: Pictures of pages

    /// Draws pages as pictures.
    ///
    /// - Parameters:
    ///   - resolution: Pixels per inch.
    ///   - quality: For JPEG and HEIC, from 0 to 1.
    ///   - each: Called with each picture's bytes and the page's index. Return `false` to stop.
    static func renderPages(
        _ source: Source, pages: [Int]? = nil, as type: UTType, resolution: Double, quality: Double = 0.9,
        each: (Data, Int) throws -> Bool
    ) throws {
        guard let document = PDFDocument(data: source.data) else { throw ToolError.unreadable(source.name) }
        if document.isLocked {
            guard let password = source.password, document.unlock(withPassword: password) else { throw ToolError.protectedSource }
        }
        for index in pages ?? Array(0..<document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            guard let data = image(of: page, as: type, resolution: resolution, quality: quality) else { throw CocoaError(.fileWriteUnknown) }
            if try !each(data, index) { return }
        }
    }

    static func image(of page: PDFPage, as type: UTType, resolution: Double, quality: Double) -> Data? {
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let scale = resolution / 72
        let width = max(Int((size.width * scale).rounded()), 1), height = max(Int((size.height * scale).rounded()), 1)
        // Too large to hold in memory comfortably; the resolution is brought down to fit.
        let limit = 16_000.0
        let fit = min(1, limit / Double(max(width, height)))
        let pixels = (width: max(Int(Double(width) * fit), 1), height: max(Int(Double(height) * fit), 1))
        guard let context = CGContext(
            data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale * fit, y: scale * fit)
        // Annotations are drawn with the page, as they would print.
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        page.draw(with: .cropBox, to: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: resolution * fit, kCGImagePropertyDPIHeight: resolution * fit,
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: Names

    /// A file name that is safe to use, from text such as a bookmark's title.
    static func fileName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(120))
    }

    /// Names for the parts of a split: the bookmark's title when there is one, the page
    /// numbers otherwise. Repeated names get a number.
    static func names(for parts: [SplitPart], baseName: String) -> [String] {
        var used: [String: Int] = [:]
        return parts.map { part in
            let label = part.title.map(fileName).flatMap { $0.isEmpty ? nil : $0 } ?? PageRanges.description(of: part.pageIndexes)
            var name = "\(baseName) – \(label)"
            used[name, default: 0] += 1
            if let count = used[name], count > 1 { name += " \(count)" }
            return name
        }
    }

    /// Writes data into a folder under a name, adding a number if the name is taken.
    @discardableResult
    static func write(_ data: Data, named name: String, extension fileExtension: String, in folder: URL) throws -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(attempt)").appendingPathExtension(fileExtension)
            attempt += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
