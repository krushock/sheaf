import AppIntents
import Foundation
import PDFKit
import SheafKit
import UniformTypeIdentifiers

// The file tools as actions for Shortcuts. Each takes files and gives files back, so they
// chain with one another and with Finder's Quick Actions. None of them opens a window.

private nonisolated func source(_ file: IntentFile, password: String? = nil) -> Toolbox.Source {
    let name = (file.filename as NSString).deletingPathExtension
    return Toolbox.Source(data: file.data, name: name.isEmpty ? "Document" : name, password: password?.isEmpty == true ? nil : password)
}

private nonisolated func pdf(_ data: Data, named name: String) -> IntentFile {
    IntentFile(data: data, filename: name + ".pdf", type: .pdf)
}

/// Runs a tool off the main thread, where the actions themselves live.
private func background<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

struct MergePDFsIntent: AppIntent {
    static let title: LocalizedStringResource = "Merge PDFs"
    static let description = IntentDescription("Joins PDFs and pictures into one PDF, in the order given.", categoryName: "Documents")

    @Parameter(title: "Files", supportedContentTypes: [.pdf, .image])
    var files: [IntentFile]

    @Parameter(title: "Bookmark Each Document", default: true)
    var bookmarks: Bool

    @Parameter(title: "Password", description: "Used for any of the PDFs that is protected.")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Merge \(\.$files)") {
            \.$bookmarks
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        // The password is tried on every file; files that are not protected ignore it.
        let sources = files.map { source($0, password: password) }, bookmarks = bookmarks
        let data = try await background { try Toolbox.merge(sources, bookmarksPerDocument: bookmarks) }
        return .result(value: pdf(data, named: "Merged"))
    }
}

nonisolated enum IntentPaper: String, AppEnum {
    case fit, a4, letter

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Page Size"
    static let caseDisplayRepresentations: [IntentPaper: DisplayRepresentation] = [
        .fit: "Same as Each Picture", .a4: "A4", .letter: "US Letter",
    ]
}

struct ImagesToPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Make PDF from Images"
    static let description = IntentDescription("Makes a PDF with one page per picture. JPEG pictures go in without being recompressed.", categoryName: "Documents")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Page Size", default: .fit)
    var paper: IntentPaper

    @Parameter(title: "Straighten Photos of Documents", default: false)
    var straightens: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Make a PDF from \(\.$images)") {
            \.$paper
            \.$straightens
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let options = ImageDocumentOptions(paper: paper == .fit ? .fitImage : .fixed(paper == .a4 ? .a4 : .letter))
        let pictures = images.map(\.data), straightens = straightens
        let data = try await background { try Toolbox.document(fromImages: pictures, options: options, straightens: straightens) }
        let name = images.count == 1 ? (images[0].filename as NSString).deletingPathExtension : "Images"
        return .result(value: pdf(data, named: name))
    }
}

nonisolated enum IntentCompression: String, AppEnum {
    case exact, balanced, smallest

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reduction"
    static let caseDisplayRepresentations: [IntentCompression: DisplayRepresentation] = [
        .exact: "Keep Everything Exact", .balanced: "Balanced", .smallest: "Smallest",
    ]

    var options: CompressionOptions {
        switch self {
        case .exact: .lossless
        case .balanced: .balanced
        case .smallest: .smallest
        }
    }
}

struct ReduceFileSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Reduce PDF File Size"
    static let description = IntentDescription("Makes a PDF smaller by packing it tightly and, if asked, scaling down its pictures.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Reduction", default: .balanced)
    var level: IntentCompression

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Reduce the size of \(\.$file) to \(\.$level)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let options = level.options
        let data = try await background { try Toolbox.compress(input, options: options) }
        // Never hand back something larger than what came in.
        return .result(value: pdf(data.count < input.data.count ? data : input.data, named: input.name))
    }
}

struct SplitPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Split PDF"
    static let description = IntentDescription("Cuts a PDF into several, each with the same number of pages.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Pages in Each", default: 1, inclusiveRange: (1, 10_000))
    var size: Int

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Split \(\.$file) every \(\.$size) pages") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let input = source(file, password: password)
        let size = size
        let (documents, names) = try await background {
            let parts = SplitPlan.every(size, pageCount: try input.editor().pageCount())
            return (try Toolbox.split(input, into: parts), Toolbox.names(for: parts, baseName: input.name))
        }
        return .result(value: zip(documents, names).map { pdf($0, named: $1) })
    }
}

struct ExtractPagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract PDF Pages"
    static let description = IntentDescription("Makes a new PDF from some of a PDF's pages, such as 1-3, 5.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Pages", description: "Page numbers and ranges, such as 1-3, 5, 8-")
    var pages: String

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Extract pages \(\.$pages) from \(\.$file)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let pages = pages
        let data = try await background { try Toolbox.extract(input, pages: pages) }
        return .result(value: pdf(data, named: "\(input.name) pages \(pages)"))
    }
}

nonisolated enum IntentImageFormat: String, AppEnum {
    case png, jpeg, tiff, heic

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Image Format"
    static let caseDisplayRepresentations: [IntentImageFormat: DisplayRepresentation] = [
        .png: "PNG", .jpeg: "JPEG", .tiff: "TIFF", .heic: "HEIC",
    ]

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .heic: .heic
        }
    }
}

struct PDFToImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Images from PDF"
    static let description = IntentDescription("Draws each page of a PDF as a picture.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Format", default: .png)
    var format: IntentImageFormat

    @Parameter(title: "Pixels per Inch", default: 144, inclusiveRange: (36, 1200))
    var resolution: Int

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Make \(\.$format) images from \(\.$file)") {
            \.$resolution
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let input = source(file, password: password)
        let type = format.type, resolution = Double(resolution)
        let fileExtension = type.preferredFilenameExtension ?? format.rawValue
        let pictures = try await background {
            var pictures: [Data] = []
            try Toolbox.renderPages(input, as: type, resolution: resolution) { data, _ in
                pictures.append(data)
                return true
            }
            return pictures
        }
        return .result(value: pictures.enumerated().map { index, data in
            IntentFile(data: data, filename: "\(input.name) \(index + 1).\(fileExtension)", type: type)
        })
    }
}

struct AddWatermarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Watermark to PDF"
    static let description = IntentDescription("Writes text such as “Draft” across every page of a PDF.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Text", default: "Draft")
    var text: String

    @Parameter(title: "Opacity", default: 0.3, inclusiveRange: (0.05, 1))
    var opacity: Double

    @Parameter(title: "Repeat Across the Page", default: false)
    var isTiled: Bool

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add the watermark \(\.$text) to \(\.$file)") {
            \.$opacity
            \.$isTiled
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        var watermark = Watermark(content: .text(text))
        watermark.opacity = opacity
        watermark.isTiled = isTiled
        if isTiled { watermark.fontSize = 36 }
        let mark = watermark
        let data = try await background { try Toolbox.edit(input) { try $0.addWatermark(mark) } }
        return .result(value: pdf(data, named: input.name))
    }
}

struct AddPageNumbersIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Page Numbers to PDF"
    static let description = IntentDescription("Numbers the pages of a PDF at the bottom of each page.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Text", description: "Use {page} for the page number and {pages} for the page count.", default: "{page}")
    var text: String

    @Parameter(title: "First Number", default: 1)
    var firstNumber: Int

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Number the pages of \(\.$file) as \(\.$text)") {
            \.$firstNumber
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        var spec = HeaderFooter()
        spec.footer.center = text
        spec.firstNumber = firstNumber
        let lines = spec
        let data = try await background { try Toolbox.edit(input) { try $0.addHeaderFooter(lines, documentName: input.name) } }
        return .result(value: pdf(data, named: input.name))
    }
}

struct ProtectPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Protect PDF with Password"
    static let description = IntentDescription("Encrypts a PDF with AES 256-bit, so it needs a password to open.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "New Password")
    var newPassword: String

    @Parameter(title: "Current Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Protect \(\.$file) with \(\.$newPassword)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        guard !newPassword.isEmpty else { throw ToolError.nothingToDo }
        let newPassword = newPassword
        let data = try await background { try Toolbox.protect(input, userPassword: newPassword) }
        return .result(value: pdf(data, named: input.name))
    }
}

struct RemovePDFPasswordIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Password from PDF"
    static let description = IntentDescription("Saves a protected PDF without its password. The password is needed to do so.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Password")
    var password: String

    static var parameterSummary: some ParameterSummary {
        Summary("Remove the password \(\.$password) from \(\.$file)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let data = try await background { try Toolbox.unprotect(input) }
        return .result(value: pdf(data, named: input.name))
    }
}

struct RotatePDFPagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Rotate PDF Pages"
    static let description = IntentDescription("Turns pages of a PDF by a quarter turn or more.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Quarter Turns Clockwise", default: 1, inclusiveRange: (1, 3))
    var turns: Int

    @Parameter(title: "Pages", description: "Page numbers and ranges, such as 1-3, 5. Leave empty for all pages.")
    var pages: String?

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Rotate \(\.$file) by \(\.$turns) quarter turns") {
            \.$pages
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let turns = turns
        let chosen = pages.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let data = try await background {
            try Toolbox.edit(input) { editor in
                let count = try editor.pageCount()
                let indexes = try chosen.map { try PageRanges.parse($0, pageCount: count) } ?? Array(0..<count)
                for index in Set(indexes) { try editor.rotatePage(at: index, by: turns * 90) }
            }
        }
        return .result(value: pdf(data, named: input.name))
    }
}

struct RecognizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Recognize Text in PDF"
    static let description = IntentDescription("Reads the text in scanned pages and lays it over them invisibly, so the PDF can be searched and copied from.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Recognize the text in \(\.$file)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let data = try await background { try Toolbox.recognizeText(input).data }
        return .result(value: pdf(data, named: input.name))
    }
}

struct PDFToWordIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Word Document from PDF"
    static let description = IntentDescription("Carries a PDF's text over into a Word file, with its fonts, sizes, colors and pictures.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Make a Word document from \(\.$file)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let data = try await background { try Toolbox.word(input) }
        return .result(value: IntentFile(data: data, filename: input.name + ".docx", type: UTType(filenameExtension: "docx")))
    }
}

struct PDFToExcelIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Excel Workbook from PDF"
    static let description = IntentDescription("Puts each page's text into a sheet, in rows and columns as it is on the page.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Make an Excel workbook from \(\.$file)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let data = try await background { try Toolbox.excel(input) }
        return .result(value: IntentFile(data: data, filename: input.name + ".xlsx", type: UTType(filenameExtension: "xlsx")))
    }
}

struct ConvertToPDFAIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert PDF to PDF/A"
    static let description = IntentDescription("Makes a PDF fit for long-term archiving: fonts inside the file, a color profile, no scripts or password.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$file) to PDF/A") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = source(file, password: password)
        let data = try await background { try Toolbox.archival(input).data }
        return .result(value: pdf(data, named: input.name))
    }
}

/// A saved flow, as Shortcuts sees it.
nonisolated struct FlowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Flow"
    static let defaultQuery = FlowQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct FlowQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [FlowEntity] {
        FlowFile.read().filter { identifiers.contains($0.id) }.map { FlowEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [FlowEntity] {
        FlowFile.read().map { FlowEntity(id: $0.id, name: $0.name) }
    }
}

struct RunFlowIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Flow on Files"
    static let description = IntentDescription("Runs one of the flows saved in Sheaf on PDFs and pictures, and gives back the results.", categoryName: "Documents")

    @Parameter(title: "Flow")
    var flow: FlowEntity

    @Parameter(title: "Files", supportedContentTypes: [.pdf, .image])
    var files: [IntentFile]

    @Parameter(title: "Password", description: "Used for any of the PDFs that is protected.")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$flow) on \(\.$files)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let id = flow.id
        guard let saved = FlowFile.read().first(where: { $0.id == id }) else { throw ToolError.nothingToDo }
        let sources = files.map { source($0, password: password) }
        let outputs = try await background { try FlowRunner.run(saved, on: sources) }
        return .result(value: outputs.map { output in
            IntentFile(data: output.data, filename: "\(output.name).\(output.fileExtension)", type: UTType(filenameExtension: output.fileExtension))
        })
    }
}

nonisolated enum IntentSummaryKind: String, AppEnum {
    case summary, keyPoints

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kind of Summary"
    static let caseDisplayRepresentations: [IntentSummaryKind: DisplayRepresentation] = [
        .summary: "Summary", .keyPoints: "Key Points",
    ]
}

struct SummarizePDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize PDF"
    static let description = IntentDescription("Sums up what a PDF says, with Apple Intelligence on this Mac. A scanned PDF has to have its text recognized first.", categoryName: "Documents")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    @Parameter(title: "As", default: .summary)
    var kind: IntentSummaryKind

    @Parameter(title: "Password", description: "Used if the PDF is protected.")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Summarize \(\.$file) as \(\.$kind)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = file.data, password = password
        let pages = try await background {
            guard let document = PDFDocument(data: data) else { throw ToolError.nothingToDo }
            if document.isLocked, !document.unlock(withPassword: password ?? "") { throw ToolError.nothingToDo }
            return (0..<document.pageCount).map { PageText(pageIndex: $0, text: document.page(at: $0)?.string ?? "") }
        }
        // By the model chosen in Settings, as in the app.
        let reading = try await DocumentReader.summarize(pages, as: kind == .summary ? .summary : .keyPoints, using: Preferences.readingEngineValue) { _ in }
        return .result(value: reading.text)
    }
}

/// The actions Shortcuts and Spotlight offer without any setting up.
struct SheafShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MergePDFsIntent(), phrases: ["Merge PDFs with \(.applicationName)"], shortTitle: "Merge PDFs", systemImageName: "doc.on.doc")
        AppShortcut(intent: ReduceFileSizeIntent(), phrases: ["Reduce a PDF with \(.applicationName)"], shortTitle: "Reduce File Size", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: ImagesToPDFIntent(), phrases: ["Make a PDF from images with \(.applicationName)"], shortTitle: "Images to PDF", systemImageName: "photo.on.rectangle")
        AppShortcut(intent: SplitPDFIntent(), phrases: ["Split a PDF with \(.applicationName)"], shortTitle: "Split PDF", systemImageName: "square.split.2x1")
        AppShortcut(intent: PDFToImagesIntent(), phrases: ["Make images from a PDF with \(.applicationName)"], shortTitle: "PDF to Images", systemImageName: "photo.stack")
    }
}
