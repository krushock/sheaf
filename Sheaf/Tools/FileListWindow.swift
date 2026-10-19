import AppKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// Files handed to a tool window from elsewhere: the Welcome window, the Services menu.
@Observable
final class ToolInbox {
    static let shared = ToolInbox()

    var mergeURLs: [URL] = []
    var imageURLs: [URL] = []
    /// A tool to show once a document that is being opened has its window.
    var pendingSheets: [URL: ToolSheet] = [:]
    /// Documents on their way to the Compare window.
    var pendingComparison: (original: CompareSource?, revised: CompareSource?)? {
        didSet { if pendingComparison != nil { comparisonRequests += 1 } }
    }

    private(set) var comparisonRequests = 0

    /// Opens windows by name. Set by the first window to appear, since only views can ask.
    @ObservationIgnored var openWindow: OpenWindowAction? {
        didSet {
            guard let openWindow else { return }
            for id in waiting { openWindow(id: id) }
            waiting = []
        }
    }

    @ObservationIgnored private var waiting: [String] = []

    /// Shows a tool window, now or as soon as that is possible.
    func open(_ id: String) {
        NSApp.activate()
        if let openWindow { openWindow(id: id) } else { waiting.append(id) }
    }
}

/// One file in a tool window's list.
struct ListedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var detail = ""
    /// For a PDF, which pages to take. Empty means all of them.
    var pages = ""
    var pageCount = 0
    /// Set while a PDF still needs its password before it can be used.
    var isProtected = false
    var password: String?
}

/// The list of files shared by the merge and images windows: add, drop, reorder, remove.
struct FileList<Detail: View>: View {
    @Binding var files: [ListedFile]
    @Binding var selection: Set<ListedFile.ID>
    let types: [UTType]
    let emptyTitle: LocalizedStringKey
    let emptyImage: String
    let emptyDetail: LocalizedStringKey
    let add: ([URL]) -> Void
    @ViewBuilder let detail: (Binding<ListedFile>) -> Detail

    var body: some View {
        Group {
            if files.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyImage)
                } description: {
                    Text(emptyDetail)
                } actions: {
                    Button("Add Files…", action: choose)
                }
            } else {
                List(selection: $selection) {
                    ForEach($files) { $file in
                        HStack(spacing: 10) {
                            FileThumbnail(url: file.url, size: CGSize(width: 34, height: 42))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.url.deletingPathExtension().lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(file.detail)
                                    .font(.caption)
                                    .foregroundStyle(file.isProtected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            }
                            Spacer(minLength: 8)
                            detail($file)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { files.remove(atOffsets: $0) }
                }
                .onDeleteCommand {
                    files.removeAll { selection.contains($0.id) }
                    selection = []
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let usable = urls.filter { url in
                UTType(filenameExtension: url.pathExtension).map { type in types.contains { type.conforms(to: $0) } } ?? false
            }
            add(usable)
            return !usable.isEmpty
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

/// The plus and minus under a list, as in System Settings.
struct ListControls: View {
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: add) {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .help("Add files")
            .accessibilityLabel("Add Files")
            Divider().frame(height: 14)
            Button(action: remove) {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .disabled(!canRemove)
            .help("Remove the selected files")
            .accessibilityLabel("Remove Files")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Merge

/// File > New from PDFs: join documents into a new one.
struct MergeWindow: View {
    static let windowID = "merge"

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var files: [ListedFile] = []
    @State private var selection: Set<ListedFile.ID> = []
    @State private var addsBookmarks = true
    @State private var isWorking = false
    @State private var failure: (any Error)?
    private var inbox = ToolInbox.shared

    var body: some View {
        VStack(spacing: 0) {
            FileList(
                files: $files, selection: $selection, types: SheafDocument.readableContentTypes,
                emptyTitle: "No Documents", emptyImage: "doc.on.doc",
                emptyDetail: "Drag PDFs and pictures here. They are joined in the order listed.",
                add: add
            ) { $file in
                if file.isProtected {
                    Button("Enter Password…") { unlock(file.id) }
                } else if file.pageCount > 1 {
                    TextField("Pages", text: $file.pages, prompt: Text("All Pages"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .help("Which pages to take, such as 1-3, 5. Leave empty for all.")
                }
            }
            Divider()
            HStack(spacing: 12) {
                ListControls(canRemove: !selection.isEmpty, add: { chooseFiles() }) {
                    files.removeAll { selection.contains($0.id) }
                    selection = []
                }
                Toggle("Add a Bookmark for Each Document", isOn: $addsBookmarks)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Merge", action: merge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.count < 1 || isWorking || files.contains(where: \.isProtected) || pageSelections == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 380)
        .navigationTitle("New from PDFs")
        .onAppear(perform: takeInbox)
        .onChange(of: inbox.mergeURLs) { takeInbox() }
        .alert("The documents could not be merged.", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text([failure?.localizedDescription, (failure as? any LocalizedError)?.recoverySuggestion].compactMap(\.self).joined(separator: " "))
        }
    }

    private func takeInbox() {
        guard !inbox.mergeURLs.isEmpty else { return }
        add(inbox.mergeURLs)
        inbox.mergeURLs = []
        #if DEBUG
        if UserDefaults.standard.string(forKey: "SnapshotInsertPassword") != nil {
            for file in files where file.isProtected { unlock(file.id) }
        }
        if UserDefaults.standard.bool(forKey: "SnapshotAutoRun") { merge() }
        #endif
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SheafDocument.readableContentTypes
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            var file = ListedFile(url: url)
            examine(&file)
            files.append(file)
        }
    }

    /// Works out what a file is and how many pages it has, with the password it has so far.
    private func examine(_ file: inout ListedFile) {
        guard var source = try? Toolbox.Source(url: file.url) else {
            file.detail = String(localized: "Could not be read. Remove it to continue.")
            file.isProtected = true
            return
        }
        guard source.isPDF else {
            file.pageCount = 1
            file.detail = String(localized: "Picture")
            return
        }
        source.password = file.password
        do {
            let count = try source.editor().pageCount()
            file.pageCount = count
            file.isProtected = false
            let pages = count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages")
            file.detail = file.password == nil ? pages : String(localized: "\(pages), unlocked")
        } catch ToolError.protectedSource, ToolError.wrongPassword {
            file.isProtected = true
            file.detail = String(localized: "Protected with a password.")
        } catch {
            file.isProtected = true
            file.detail = String(localized: "Could not be read. Remove it to continue.")
        }
    }

    /// Asks for a protected file's password until it opens or the person gives up.
    private func unlock(_ id: ListedFile.ID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let name = files[index].url.deletingPathExtension().lastPathComponent
        var wasWrong = false
        while let password = PasswordRequest.ask(named: name, wasWrong: wasWrong) {
            files[index].password = password
            examine(&files[index])
            if !files[index].isProtected { return }
            files[index].password = nil
            wasWrong = true
        }
    }

    /// Each file's chosen pages, or `nil` while a range cannot be read.
    private var pageSelections: [[Int]?]? {
        var result: [[Int]?] = []
        for file in files {
            let text = file.pages.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                result.append(nil)
            } else if let indexes = try? PageRanges.parse(text, pageCount: file.pageCount) {
                result.append(indexes)
            } else {
                return nil
            }
        }
        return result
    }

    private var summary: String {
        guard let selections = pageSelections else { return String(localized: "Check the page ranges.") }
        let total = zip(files, selections).reduce(0) { $0 + ($1.1?.count ?? $1.0.pageCount) }
        return total == 0 ? "" : (total == 1 ? String(localized: "1 page") : String(localized: "\(total) pages"))
    }

    private func merge() {
        guard let selections = pageSelections else { return }
        let urls = files.map(\.url), passwords = files.map(\.password), bookmarks = addsBookmarks
        isWorking = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Data, any Error> in
                Result {
                    let parts = try zip(zip(urls, passwords), selections).map { file, pages -> MergeSource in
                        var source = try Toolbox.Source(url: file.0)
                        source.password = file.1
                        let editor = source.isPDF
                            ? try source.editor()
                            : PDFEditor(try PDFFile(data: try PDFGenerator.document(fromImageData: source.data)))
                        return MergeSource(document: editor, title: source.name, pageIndexes: pages)
                    }
                    return try PDFGenerator.merged(parts, bookmarksPerDocument: bookmarks)
                }
            }.value
            isWorking = false
            switch outcome {
            case .success(let data):
                SheafDocument.openUntitled(data, named: String(localized: "Merged"))
                files = []
                dismissWindow(id: Self.windowID)
            case .failure(let error):
                failure = error
            }
        }
    }
}

// MARK: - Images

/// File > New from Images: one page per picture.
struct ImagesWindow: View {
    static let windowID = "images"

    private enum Paper: String, CaseIterable, Identifiable {
        case fit, a4, letter

        var id: Self { self }
    }

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var files: [ListedFile] = []
    @State private var selection: Set<ListedFile.ID> = []
    @State private var paper = Paper.fit
    @State private var margin = 0.0
    @State private var straightens = false
    @State private var isWorking = false
    @State private var failure: (any Error)?
    private var inbox = ToolInbox.shared

    var body: some View {
        VStack(spacing: 0) {
            FileList(
                files: $files, selection: $selection, types: SheafDocument.importableImageTypes,
                emptyTitle: "No Pictures", emptyImage: "photo.on.rectangle",
                emptyDetail: "Drag pictures here. Each one becomes a page, in the order listed.",
                add: add
            ) { _ in EmptyView() }
            Divider()
            Form {
                Picker("Page Size", selection: $paper) {
                    Text("Same as Each Picture").tag(Paper.fit)
                    Text("A4").tag(Paper.a4)
                    Text("US Letter").tag(Paper.letter)
                }
                Picker("Margins", selection: $margin) {
                    Text("None").tag(0.0)
                    Text("Narrow").tag(18.0)
                    Text("Normal").tag(36.0)
                    Text("Wide").tag(72.0)
                }
                Toggle("Straighten Photos of Documents", isOn: $straightens)
                    .help("Finds the sheet of paper in each photo, cuts it out and squares it up.")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 12) {
                ListControls(canRemove: !selection.isEmpty, add: { chooseFiles() }) {
                    files.removeAll { selection.contains($0.id) }
                    selection = []
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Text(files.isEmpty ? "" : (files.count == 1 ? String(localized: "1 page") : String(localized: "\(files.count) pages")))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || isWorking)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("New from Images")
        .onAppear(perform: takeInbox)
        .onChange(of: inbox.imageURLs) { takeInbox() }
        .alert("The document could not be made.", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure?.localizedDescription ?? "")
        }
    }

    private func takeInbox() {
        guard !inbox.imageURLs.isEmpty else { return }
        add(inbox.imageURLs)
        inbox.imageURLs = []
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SnapshotAutoRun") { create() }
        #endif
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SheafDocument.importableImageTypes
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            var file = ListedFile(url: url, pageCount: 1)
            if let type = UTType(filenameExtension: url.pathExtension) { file.detail = type.localizedDescription ?? "" }
            files.append(file)
        }
    }

    private func create() {
        let urls = files.map(\.url), straightens = straightens
        let options = ImageDocumentOptions(
            paper: paper == .fit ? .fitImage : .fixed(paper == .a4 ? .a4 : .letter), margin: margin
        )
        isWorking = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Data, any Error> in
                Result {
                    let pictures = try urls.map { try Toolbox.Source(url: $0).data }
                    return try Toolbox.document(fromImages: pictures, options: options, straightens: straightens)
                }
            }.value
            isWorking = false
            switch outcome {
            case .success(let data):
                SheafDocument.openUntitled(data, named: String(localized: "Images"))
                files = []
                dismissWindow(id: Self.windowID)
            case .failure(let error):
                failure = error
            }
        }
    }
}
