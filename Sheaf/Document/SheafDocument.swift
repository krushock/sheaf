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
    /// The looks of annotations drawn over the page, kept while the annotation stays as it is.
    @ObservationIgnored private var sharpLooks: [ObjectID: (model: Annotation, item: SharpAnnotation?)] = [:]
    /// PDFKit's annotations that are switched off because Sheaf draws them.
    @ObservationIgnored private let hiddenNatives = NSHashTable<PDFAnnotation>.weakObjects()
    /// Goes up each time one is switched off, so PDFKit can be told to draw the page again.
    @ObservationIgnored private(set) var nativeChanges = 0
    /// Posted when what is on the pages changed, straight away, so drawing can keep up
    /// within the same turn of the run loop.
    static let didChangeDisplay = Notification.Name("SheafDocumentDidChangeDisplay")
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
        let start = Date()
        pdf = PDFDocument(data: contents.data)
        let afterPDFKit = Date()
        openEngine(password: nil)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SnapshotTimings") {
            print("TIMING open: PDFKit \(Int(afterPDFKit.timeIntervalSince(start) * 1000)) ms, engine \(Int(Date().timeIntervalSince(afterPDFKit) * 1000)) ms, \(contents.data.count / 1_048_576) MB")
        }
        #endif
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
            #if DEBUG
            print("SAVE snapshot failed: \(error)")
            #endif
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
        let start = Date()
        refreshSaveSnapshot()
        let afterSnapshot = Date()
        if effect.reloadsDisplay {
            reloadDisplay()
        } else if let pdf {
            for page in effect.pages { display.sync(page: page, of: pdf, with: next) }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SnapshotTimings") {
            print("TIMING install: snapshot \(Int(afterSnapshot.timeIntervalSince(start) * 1000)) ms, display \(Int(Date().timeIntervalSince(afterSnapshot) * 1000)) ms, reload=\(effect.reloadsDisplay)")
        }
        #endif
        NotificationCenter.default.post(name: Self.didChangeDisplay, object: self)
        guard let previous, let undoManager else { return }
        let token = UUID()
        undoStates[token] = (previous, effect, previousPassword ?? password)
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.restore(token) }
        }
        if let name, !undoManager.isUndoing, !undoManager.isRedoing { undoManager.setActionName(name) }
        nudgeRunLoop()
    }

    /// AppKit closes an undo step, and only then counts the document as changed, at the
    /// end of handling an event. A change that arrives any other way, as the result of
    /// background work does, would leave the step open and the document looking unchanged
    /// until the next event, and quitting in between would not save it. An empty event
    /// gives AppKit its cue at once.
    private func nudgeRunLoop() {
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: false)
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
        sharpLooks = [:]
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

    /// The annotations of a page that are drawn over it as vectors, in the order they
    /// lie in. PDFKit's own drawing of each is switched off as it is handed out.
    ///
    /// - Parameters:
    ///   - draft: An annotation as a drag has it now, standing in for the one with the
    ///     number given, or added to the page when that is `nil`.
    ///   - hidden: Annotations to leave out, such as a text box being typed in.
    func sharpAnnotations(onPage index: Int, draft: (replacing: ObjectID?, annotation: Annotation)? = nil, hidden: Set<ObjectID> = []) -> [SharpAnnotation] {
        guard let editor, let pdf else { return [] }
        var result: [SharpAnnotation] = []
        var live: Set<ObjectID> = []
        for model in (try? editor.annotations(onPageAt: index)) ?? [] {
            guard model.isDrawnSharply, let id = model.objectID else { continue }
            live.insert(id)
            var item: SharpAnnotation?
            if let draft, draft.replacing == id {
                // Its look as it is being changed, or the look it has in the file stretched over where it is now.
                let moved = draft.annotation
                if let appearance = moved.appearance() {
                    item = SharpAnnotation(key: "\(id.number)", frame: appearance.bounds.cgRect, look: appearance.previewPDF())
                } else if let stored = sharpLooks[id]?.item?.look ?? (try? editor.storedAppearancePreview(of: id)) {
                    item = SharpAnnotation(key: "\(id.number)", frame: moved.rect.cgRect, look: stored)
                }
            } else if let known = sharpLooks[id], known.model == model {
                item = known.item
            } else if let stored = try? editor.storedAppearancePreview(of: id) {
                // What the file holds, which is what any reader will show.
                item = SharpAnnotation(key: "\(id.number)", frame: model.rect.cgRect, look: stored)
                sharpLooks[id] = (model, item)
            } else {
                sharpLooks[id] = (model, nil)
            }
            // Without a look of its own in the file, PDFKit goes on drawing it.
            guard let item else { continue }
            if let native = display.annotation(for: id, page: index, of: pdf), native.shouldDisplay {
                native.shouldDisplay = false
                hiddenNatives.add(native)
                nativeChanges += 1
            }
            if !hidden.contains(id) { result.append(item) }
        }
        if let draft, draft.replacing == nil, draft.annotation.isDrawnSharply, let appearance = draft.annotation.appearance() {
            result.append(SharpAnnotation(key: "new", frame: appearance.bounds.cgRect, look: appearance.previewPDF()))
        }
        return result
    }

    /// Runs something that draws a page through PDFKit, such as making a thumbnail, with
    /// the annotations Sheaf draws itself switched back on for the moment.
    func withAllAnnotationsDrawnByPDFKit<Result>(onPage index: Int, _ body: () -> Result) -> Result {
        guard let page = pdf?.page(at: index) else { return body() }
        let hidden = page.annotations.filter { hiddenNatives.contains($0) && !$0.shouldDisplay }
        for annotation in hidden { annotation.shouldDisplay = true }
        defer { for annotation in hidden { annotation.shouldDisplay = false } }
        return body()
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
