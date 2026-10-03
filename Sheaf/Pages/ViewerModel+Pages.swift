import AppKit
import PDFKit
import SheafKit
import UniformTypeIdentifiers

/// The sheets that tools show on a document window.
enum ToolSheet: String, Identifiable {
    case watermark, headerFooter, info, password, reduce, split, exportImages, scanner

    var id: Self { self }
}

/// Adding, removing, turning and rearranging pages.
extension ViewerModel {
    static let pagePasteboardType = NSPasteboard.PasteboardType("com.valeryburtsev.sheaf.page")

    var canEditPages: Bool { sheafDocument?.isEditable == true }

    /// The pages a command acts on: the ones picked in the organizer, or the page being read.
    var targetPageIndexes: [Int] {
        if isOrganizing {
            return pageIDs.indices.filter { pageSelection.contains(pageIDs[$0]) }
        }
        return pageCount > 0 ? [currentPageIndex] : []
    }

    /// Whether removing the target pages would leave at least one page.
    var canDeleteTargetPages: Bool {
        let targets = targetPageIndexes
        return canEditPages && !targets.isEmpty && targets.count < pageCount
    }

    func organizerDidToggle() {
        pdfView.endTextEditing(commit: true)
        selection = nil
        if isOrganizing {
            isMarkupVisible = false
            isFormEditing = false
            // Start with the page being read picked, so commands have something to act on.
            if pageIDs.indices.contains(currentPageIndex) { pageSelection = [pageIDs[currentPageIndex]] }
        }
    }

    /// Leaves the organizer and shows a page.
    func openPage(at index: Int) {
        isOrganizing = false
        DispatchQueue.main.async { [weak self] in self?.goToPage(index: index) }
    }

    private func name(_ singular: String, _ plural: String, count: Int) -> String {
        count == 1 ? singular : plural
    }

    /// Runs a change to the pages and then picks the pages it names.
    private func changePages(_ name: String, _ change: (inout PDFEditor, inout EditEffect) throws -> [ObjectID]) {
        guard let picked = sheafDocument?.apply(name, { editor, effect in
            effect.reloadsDisplay = true
            return try change(&editor, &effect)
        }) else { return }
        // Shown at once, not a moment later, so a command that follows straight away
        // counts pages as they now are.
        if let sheafDocument { show(sheafDocument) }
        if !picked.isEmpty { pageSelection = Set(picked) }
    }

    // MARK: Turning and removing

    func rotatePages(_ indexes: [Int], by degrees: Int) {
        guard !indexes.isEmpty else { return }
        changePages(degrees < 0 ? String(localized: "Rotate Left") : String(localized: "Rotate Right")) { editor, effect in
            for index in indexes { try editor.rotatePage(at: index, by: degrees) }
            effect.pages = Set(indexes)
            return []
        }
    }

    func deletePages(_ indexes: [Int]) {
        guard !indexes.isEmpty, indexes.count < pageCount else { return }
        changePages(name(String(localized: "Delete Page"), String(localized: "Delete Pages"), count: indexes.count)) { editor, _ in
            try editor.removePages(at: indexes)
            return []
        }
    }

    func duplicatePages(_ indexes: [Int]) {
        guard !indexes.isEmpty else { return }
        changePages(name(String(localized: "Duplicate Page"), String(localized: "Duplicate Pages"), count: indexes.count)) { editor, _ in
            // From the back, so earlier page numbers stay valid as copies are added.
            try indexes.sorted(by: >).map { try editor.duplicatePage(at: $0) }
        }
    }

    func splitPagesInHalf(_ indexes: [Int], direction: SplitDirection) {
        guard !indexes.isEmpty else { return }
        changePages(String(localized: "Split Pages")) { editor, effect in
            try editor.splitPagesInHalf(at: indexes, direction: direction)
            // Every page from the first one cut onward shows something else now.
            effect.pages = Set((indexes.min() ?? 0)..<(try editor.pageCount()))
            return []
        }
    }

    // MARK: Moving

    /// Moves pages so that they sit, in their current order, before the page that is now
    /// at `destination`. Pass the page count to move them to the end.
    func movePages(_ indexes: [Int], to destination: Int) {
        let moving = indexes.sorted()
        guard !moving.isEmpty, pageCount > 1 else { return }
        var order = Array(0..<pageCount)
        order.removeAll { moving.contains($0) }
        let insertion = destination - moving.filter { $0 < destination }.count
        order.insert(contentsOf: moving, at: min(max(insertion, 0), order.count))
        guard order != Array(0..<pageCount) else { return }
        changePages(name(String(localized: "Move Page"), String(localized: "Move Pages"), count: moving.count)) { editor, _ in
            try editor.arrangePages(order)
            return []
        }
    }

    // MARK: Adding

    /// Where new pages go: after the last picked page, or after the page being read.
    var insertionIndex: Int {
        (targetPageIndexes.max() ?? pageCount - 1) + 1
    }

    func insertBlankPage(at index: Int? = nil) {
        let position = min(index ?? insertionIndex, pageCount)
        changePages(String(localized: "Insert Blank Page")) { editor, _ in
            // The same size as its neighbor, so it does not stand out.
            let neighbor = try editor.geometry(ofPageAt: max(position - 1, 0)).displaySize
            return [try editor.insertBlankPage(size: neighbor, at: position)]
        }
        showInserted(at: position)
    }

    /// Asks for PDFs or pictures and adds their pages.
    func chooseFilesToInsert(at index: Int? = nil) {
        guard let window else { return }
        let position = min(index ?? insertionIndex, pageCount)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SheafDocument.readableContentTypes
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose PDFs or pictures to add to the document.")
        panel.prompt = String(localized: "Insert")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.insertFiles(panel.urls, at: position)
        }
    }

    /// Adds the pages of PDFs, and pictures as pages, in the order given.
    func insertFiles(_ urls: [URL], at index: Int) {
        var items: [Data] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                NSApp.presentError(CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url]))
                return
            }
            items.append(data)
        }
        insertItems(items, names: urls.map { $0.deletingPathExtension().lastPathComponent }, at: index)
    }

    /// Adds PDF or picture data as pages. A PDF that is protected with a password asks for it.
    ///
    /// - Parameter names: What to call each item when asking for its password.
    func insertItems(_ items: [Data], names: [String] = [], at index: Int) {
        guard !items.isEmpty else { return }
        // Read each PDF first, so a wrong password never leaves the change half done.
        var sources: [(data: Data, file: PDFFile?)] = []
        var needsPassword: [Int] = []
        for (offset, data) in items.enumerated() {
            guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else {
                sources.append((data, nil))
                continue
            }
            do {
                sources.append((data, try PDFFile(data: data)))
            } catch SheafError.passwordRequired, SheafError.incorrectPassword {
                sources.append((data, nil))
                needsPassword.append(offset)
            } catch {
                NSApp.presentError(ToolError.unreadable(offset < names.count ? names[offset] : String(localized: "The document")))
                return
            }
        }
        guard !needsPassword.isEmpty else { return insert(sources, at: index) }
        // Asked a moment later: this may be running in the middle of a drop.
        DispatchQueue.main.async { [self] in
            var skipped: Set<Int> = []
            for offset in needsPassword {
                let name = offset < names.count ? names[offset] : String(localized: "The document")
                if let file = PasswordRequest.open(sources[offset].data, named: name, on: window) {
                    sources[offset].file = file
                } else {
                    skipped.insert(offset)
                }
            }
            insert(sources.enumerated().filter { !skipped.contains($0.offset) }.map(\.element), at: index)
        }
    }

    private func insert(_ sources: [(data: Data, file: PDFFile?)], at index: Int) {
        guard !sources.isEmpty else { return }
        let position = min(max(index, 0), pageCount)
        changePages(String(localized: "Insert Pages")) { editor, _ in
            var added: [ObjectID] = []
            for source in sources {
                if let file = source.file {
                    added += try editor.insertPages(from: PDFEditor(file), at: position + added.count)
                } else {
                    // A picture gets a page the size of its neighbor, as a scan would.
                    let paper = (try? editor.geometry(ofPageAt: max(position - 1, 0)).displaySize) ?? .a4
                    added.append(try editor.insertImagePage(source.data, options: ImageDocumentOptions(paper: .fixed(paper)), at: position + added.count))
                }
            }
            return added
        }
        showInserted(at: position)
    }

    /// Adds what a camera or scanner on another device sent: scans as PDFs, photos as pictures.
    func insertImported(_ providers: [NSItemProvider]) {
        let position = insertionIndex
        Task {
            var items: [Data] = []
            for provider in providers {
                let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ? .pdf : .image
                let data: Data? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
                }
                // A photo of a sheet of paper is cut out and squared up, as a scanner would.
                if let data { items.append(type == .image ? DocumentStraightener.straightened(data) ?? data : data) }
            }
            insertItems(items, at: position)
        }
    }

    private func showInserted(at index: Int) {
        guard !isOrganizing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.goToPage(index: index) }
    }

    // MARK: Taking pages out

    /// The chosen pages as a document of their own, or `nil` if that fails.
    func data(forPages indexes: [Int]) -> Data? {
        guard !indexes.isEmpty, let editor = sheafDocument?.editor else { return nil }
        return try? editor.extractingPages(indexes)
    }

    /// Opens the chosen pages as a new, unsaved document.
    func extractPages(_ indexes: [Int]) {
        guard let data = data(forPages: indexes) else { return }
        SheafDocument.openUntitled(data, named: nameForPages(indexes))
    }

    /// A name for a document made of some of this one's pages.
    func nameForPages(_ indexes: [Int]) -> String {
        let pages = PageRanges.description(of: indexes)
        return indexes.count == 1
            ? String(localized: "\(documentName) page \(pages)")
            : String(localized: "\(documentName) pages \(pages)")
    }

    /// The document's name without its extension.
    var documentName: String {
        let title = window?.title ?? ""
        let name = (title as NSString).deletingPathExtension
        return name.isEmpty ? String(localized: "Untitled") : name
    }

    // MARK: Copy and paste

    func copyPages(_ indexes: [Int]) {
        guard let data = data(forPages: indexes) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .pdf)
    }

    var canPastePages: Bool {
        canEditPages && NSPasteboard.general.availableType(from: [.pdf, .fileURL, .png, .tiff]) != nil
    }

    func pastePages() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .pdf) {
            insertItems([data], at: insertionIndex)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertFiles(urls.filter(Self.canInsert), at: insertionIndex)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            insertItems([data], at: insertionIndex)
        }
    }

    /// Whether a file is a PDF or a picture that can become a page.
    static func canInsert(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return SheafDocument.readableContentTypes.contains { type.conforms(to: $0) }
    }
}

/// Problems a tool can run into that have a plain explanation.
enum ToolError: LocalizedError {
    case protectedSource
    case wrongPassword
    case nothingToDo
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .protectedSource: String(localized: "One of the documents is protected with a password.")
        case .wrongPassword: String(localized: "The password is not correct.")
        case .nothingToDo: String(localized: "There is nothing to do.")
        case .unreadable(let name): String(localized: "“\(name)” could not be read.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .protectedSource: String(localized: "Enter its password, or leave it out.")
        case .wrongPassword, .nothingToDo: nil
        case .unreadable: String(localized: "It may be damaged, or not a PDF or picture.")
        }
    }
}
