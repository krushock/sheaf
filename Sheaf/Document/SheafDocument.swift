import AppKit
import PDFKit
import SheafKit
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// The bytes of a PDF file, as read from disk or as they will be written.
nonisolated struct PDFContents: Sendable {
    var data: Data
}

/// What saving will write: the original bytes followed by the changes, or a complete
/// replacement when the document cannot be saved by appending.
nonisolated struct SaveSnapshot: Sendable {
    var original: Data
    var appended = Data()
    var replacement: Data?

    var data: Data { replacement ?? original + appended }
}

/// What an edit touched, so the screen can catch up with the document.
struct EditEffect {
    /// Pages whose annotations changed.
    var pages: Set<Int> = []
    /// Set when page content or page order changed, which PDFKit can only pick up by
    /// reading the document again.
    var reloadsDisplay = false
}

/// One open document. All file reading and writing for the app goes through this file.
///
/// Two things describe the document. `editor` is the truth: SheafKit's view of the file
/// plus every change made so far, and what gets saved. `pdf` is PDFKit's copy, kept in
/// step with the editor so the screen shows the same thing.
///
/// This uses `ReferenceFileDocument` on purpose. The URL-based `Document` protocol new in
/// macOS 27 deadlocks in 27.0.1 whenever AppKit reads a document on the main thread, which
/// is what Duplicate and Revert do. Revisit when that is fixed.
@MainActor @Observable
final class SheafDocument: ReferenceFileDocument {
    nonisolated static let importableImageTypes: [UTType] = [.jpeg, .png, .heic, .tiff, .webP, .gif, .bmp]
        + [UTType("public.avif")].compactMap(\.self)

    nonisolated static let readableContentTypes: [UTType] = [.pdf] + importableImageTypes
    nonisolated static let writableContentTypes: [UTType] = [.pdf]

    /// The PDF bytes as opened. Never modified; edits are appended when saving.
    nonisolated let contents: PDFContents

    /// PDFKit's view of the document, used for display. Created when the window appears.
    private(set) var pdf: PDFDocument?

    /// The bytes `pdf` was last read from, for background work on a private copy.
    var displayData: Data { reloadedData ?? contents.data }

    @ObservationIgnored private var reloadedData: Data?

    /// The document with all edits so far. `nil` while locked, or if the engine cannot
    /// read a file that PDFKit can, in which case the document is view-only.
    private(set) var editor: PDFEditor?

    /// The password that unlocked the document.
    private(set) var password: String?

    /// Changes whenever `pdf` is replaced, so views can start over.
    private(set) var generation = 0

    /// Changes with every edit, so lists built from the document can refresh.
    private(set) var revision = 0

    /// The pages the latest edit, undo or redo touched.
    @ObservationIgnored private(set) var lastChangedPages: Set<Int> = []

    /// Set by the window, so edits can be undone and mark the document as changed.
    @ObservationIgnored weak var undoManager: UndoManager?

    @ObservationIgnored private var display = AnnotationDisplay()
    @ObservationIgnored private var undoStates: [UUID: (editor: PDFEditor, effect: EditEffect, password: String?)] = [:]
    @ObservationIgnored private var lastCoalescing: (key: String, time: Date)?

    /// SwiftUI takes the snapshot for saving on a background thread, sometimes while the
    /// main thread waits for it. So what to save is worked out on the main thread after
    /// every edit and kept here, where any thread can pick it up.
    @ObservationIgnored private nonisolated let saved: Mutex<SaveSnapshot>

    /// A new document: one empty page at the size chosen in Settings.
    nonisolated init() {
        let paper = Preferences.value(Preferences.newDocumentPaper, default: NewDocumentPaper.system)
        // Generating an empty page cannot fail short of memory exhaustion.
        contents = PDFContents(data: (try? PDFGenerator.blankDocument(pageSize: paper.pageSize)) ?? Data())
        saved = Mutex(SaveSnapshot(original: contents.data))
    }

    // SwiftUI calls this off the main thread when opening, and on it for Duplicate and Revert.
    nonisolated init(configuration: ReadConfiguration) throws {
        guard let file = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            if configuration.contentType.conforms(to: .pdf) {
                // Validates that this is a PDF. A locked document is fine: the window asks
                // for the password.
                _ = try PDFInspector.summary(of: file)
                contents = PDFContents(data: file)
            } else {
                contents = PDFContents(data: try PDFGenerator.document(fromImageData: file))
            }
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
        saved = Mutex(SaveSnapshot(original: contents.data))
    }

    // MARK: Opening

    /// Parses the document. Called when its window appears.
    func loadIfNeeded() {
        guard pdf == nil else { return }
        pdf = PDFDocument(data: contents.data)
        openEngine(password: nil)
        generation += 1
    }

    /// Tries a password on a locked document.
    func unlock(with candidate: String) -> Bool {
        guard let pdf, pdf.unlock(withPassword: candidate) else { return false }
        password = candidate
        openEngine(password: candidate)
        generation += 1
        return true
    }

    private func openEngine(password: String?) {
        guard let file = try? PDFFile(data: contents.data, password: password) else { return }
        let editor = PDFEditor(file)
        self.editor = editor
        display = AnnotationDisplay(base: editor)
    }

    /// Whether the document can be changed.
    var isEditable: Bool { editor != nil }

    // MARK: Saving

    nonisolated func snapshot(contentType: UTType) throws -> SaveSnapshot {
        saved.withLock { $0 }
    }

    // SwiftUI calls this off the main thread.
    nonisolated func fileWrapper(snapshot: SaveSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot.data)
    }

    /// The document as it will be written.
    var currentData: Data { saved.withLock { $0.data } }

    private func refreshSaveSnapshot() {
        guard let editor else { return }
        // Usually the bytes as opened. After the document was written out afresh, to
        // compress it or change its password, those bytes instead.
        var snapshot = SaveSnapshot(original: editor.base.data)
        do {
            if let appended = try editor.appendedBytes() {
                snapshot.appended = appended
            } else {
                snapshot.replacement = try editor.rewritten()
            }
        } catch {
            // Keep the last good snapshot rather than save something half-made.
            return
        }
        saved.withLock { $0 = snapshot }
    }

    // MARK: Editing

    /// Makes a change to the document, shows it, and registers it for Undo.
    ///
    /// - Parameters:
    ///   - name: What the Edit menu calls the change, as in "Undo Add Highlight".
    ///   - coalescing: A key that merges a run of similar changes, such as dragging a slider,
    ///     into one undo step.
    ///   - change: Edits the document and says which pages it touched.
    /// - Returns: Whatever `change` returns, or `nil` if the change failed.
    @discardableResult
    func apply<Result>(
        _ name: String, coalescing key: String? = nil,
        _ change: (inout PDFEditor, inout EditEffect) throws -> Result
    ) -> Result? {
        guard let current = editor else { return nil }
        var next = current
        var effect = EditEffect()
        let result: Result
        do {
            result = try change(&next, &effect)
        } catch {
            NSApp.presentError(error)
            return nil
        }
        let continuesRun = key != nil && key == lastCoalescing?.key && Date().timeIntervalSince(lastCoalescing?.time ?? .distantPast) < 1.5
        lastCoalescing = key.map { ($0, Date()) }
        install(next, effect: effect, registeringUndoTo: continuesRun ? nil : current, name: name)
        return result
    }

    /// Replaces the whole document with bytes written out afresh, as compressing it or
    /// changing its password does. Undo brings the previous bytes back.
    ///
    /// - Parameter password: What opens the new bytes, or `nil` when they are not protected.
    @discardableResult
    func replaceContents(_ name: String, with data: Data, password newPassword: String?) -> Bool {
        guard let current = editor, let file = try? PDFFile(data: data, password: newPassword) else { return false }
        let previousPassword = password
        password = newPassword
        lastCoalescing = nil
        install(PDFEditor(file), effect: EditEffect(reloadsDisplay: true), registeringUndoTo: current, previousPassword: previousPassword, name: name)
        return true
    }

    private func install(_ next: PDFEditor, effect: EditEffect, registeringUndoTo previous: PDFEditor?, previousPassword: String?? = nil, name: String?) {
        editor = next
        lastChangedPages = effect.pages
        revision += 1
        refreshSaveSnapshot()
        if effect.reloadsDisplay {
            reloadDisplay()
        } else if let pdf {
            for page in effect.pages { display.sync(page: page, of: pdf, with: next) }
        }
        guard let previous, let undoManager else { return }
        let token = UUID()
        undoStates[token] = (previous, effect, previousPassword ?? password)
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.restore(token) }
        }
        if let name, !undoManager.isUndoing, !undoManager.isRedoing { undoManager.setActionName(name) }
    }

    private func restore(_ token: UUID) {
        guard let state = undoStates.removeValue(forKey: token), let current = editor else { return }
        lastCoalescing = nil
        let replaced = password
        password = state.password
        install(state.editor, effect: state.effect, registeringUndoTo: current, previousPassword: replaced, name: nil)
    }

    /// Reads the edited document into PDFKit again.
    private func reloadDisplay() {
        let data = currentData
        guard let editor, let document = PDFDocument(data: data) else { return }
        // Also when it is not locked: the owner password lifts limits on copying and printing.
        if let password { document.unlock(withPassword: password) }
        pdf = document
        reloadedData = data
        display = AnnotationDisplay(base: editor)
        generation += 1
    }

    // MARK: New documents

    /// Opens bytes as a new, unsaved document in its own window, the way Duplicate does.
    static func openUntitled(_ data: Data, named name: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name).appendingPathExtension("pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            // The file becomes the new document's unsaved contents, so it is not removed here.
            // Asking for a copy instead would add "copy" to the name.
            let document = try NSDocumentController.shared.duplicateDocument(withContentsOf: url, copying: false, displayName: name)
            // Duplicating names the result "name copy"; this is not a copy of anything.
            document.displayName = name
            for controller in document.windowControllers { controller.synchronizeWindowTitleWithDocumentName() }
        } catch {
            NSApp.presentError(error)
        }
    }

    // MARK: Annotations on screen

    /// The document's annotation that a PDFKit annotation on a page stands for.
    func objectID(of annotation: PDFAnnotation, onPage index: Int) -> ObjectID? {
        guard let pdf else { return nil }
        return display.objectID(of: annotation, page: index, of: pdf)
    }

    /// The PDFKit annotation showing one of the document's annotations.
    func displayedAnnotation(_ id: ObjectID, onPage index: Int) -> PDFAnnotation? {
        guard let pdf else { return nil }
        return display.annotation(for: id, page: index, of: pdf)
    }

    func annotation(_ id: ObjectID, onPage index: Int) -> Annotation? {
        (try? editor?.annotations(onPageAt: index))?.first { $0.objectID == id }
    }
}
