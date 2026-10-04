import AppKit
import ObjectiveC
import SheafKit

/// Puts Sheaf's save options into the panel of File > Save As, and of the first Save
/// of a new document, and applies them to what is written.
///
/// SwiftUI owns the document class behind `DocumentGroup` and gives no way to add to its
/// save panel. AppKit does: every document is asked to prepare the panel before it is
/// shown. So that one method, and the one that writes the file afterwards, are given an
/// override on SwiftUI's document class, each calling the original. With no option
/// chosen nothing is changed, and saving goes exactly as it did.
enum SavePanelOptions {
    private static var prepared: Set<ObjectIdentifier> = []
    nonisolated(unsafe) private static var optionsKey = 0

    /// Call with any document of the app. The first call for a class sets things up.
    static func install(for document: NSDocument) {
        guard let kind = object_getClass(document) else { return }
        install(in: kind)
    }

    /// Sets a document class up. Done at launch for the classes SwiftUI has made for
    /// the app's document types, before any document is read.
    static func install(in kind: AnyClass) {
        guard prepared.insert(ObjectIdentifier(kind)).inserted else { return }
        overridePreparing(in: kind)
        overrideSaving(in: kind)
        MailReply.overrideReading(in: kind)
        MailReply.overrideSavePanel(in: kind)
        MailReply.overrideClosing(in: kind)
    }

    /// Sets up the classes of every kind of document the app opens.
    static func installAtLaunch() {
        let controller = NSDocumentController.shared
        for type in SheafDocument.readableContentTypes {
            if let kind = controller.documentClass(forType: type.identifier) { install(in: kind) }
        }
    }

    /// Gives a class its own version of a method, which gets the one it had to call on.
    static func override(_ selector: Selector, in kind: AnyClass, with make: (IMP) -> Any) {
        guard let method = class_getInstanceMethod(kind, selector) else { return }
        let original = method_getImplementation(method)
        let replacement = imp_implementationWithBlock(make(original))
        // Added to this class when it only inherits the method, so other kinds of document are not touched.
        if !class_addMethod(kind, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }

    private static func overridePreparing(in kind: AnyClass) {
        let selector = #selector(NSDocument.prepareSavePanel(_:))
        override(selector, in: kind) { original in
            typealias Original = @convention(c) (NSDocument, Selector, NSSavePanel) -> Bool
            let block: @convention(block) (NSDocument, NSSavePanel) -> Bool = { document, panel in
                let result = unsafeBitCast(original, to: Original.self)(document, selector, panel)
                nonisolated(unsafe) let document = document, panel = panel
                MainActor.assumeIsolated { addOptions(to: panel, of: document) }
                return result
            }
            return block
        }
    }

    private static func overrideSaving(in kind: AnyClass) {
        let selector = #selector(NSDocument.save(to:ofType:for:completionHandler:))
        override(selector, in: kind) { original in
            typealias Completion = @convention(block) (NSError?) -> Void
            typealias Original = @convention(c) (NSDocument, Selector, NSURL, NSString, UInt, @escaping Completion) -> Void
            let block: @convention(block) (NSDocument, NSURL, NSString, UInt, @escaping Completion) -> Void = { document, url, type, operation, completion in
                nonisolated(unsafe) let saved = document
                let outcome = MainActor.assumeIsolated { applyOptions(to: saved, operation: operation) }
                if let failure = outcome.failure {
                    completion(failure as NSError)
                    return
                }
                guard outcome.changed else {
                    return unsafeBitCast(original, to: Original.self)(document, selector, url, type, operation, completion)
                }
                // Making the document what the options say counts as a change to it, and
                // AppKit takes note of that a moment after this, when it may already have
                // been saved. What was saved is the changed document, so once the save is
                // through and that note is in, the document is marked as saved again.
                let finished: Completion = { error in
                    completion(error)
                    guard error == nil else { return }
                    DispatchQueue.main.async {
                        DispatchQueue.main.async { saved.updateChangeCount(.changeCleared) }
                    }
                }
                unsafeBitCast(original, to: Original.self)(document, selector, url, type, operation, finished)
            }
            return block
        }
    }

    private static func addOptions(to panel: NSSavePanel, of document: NSDocument) {
        // Only for documents shown in a Sheaf window that can be changed, and only when nothing else has put a view there.
        guard panel.accessoryView == nil, let viewer = ViewerModel.viewer(of: document), viewer.sheafDocument?.isEditable == true else {
            objc_setAssociatedObject(document, &optionsKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        let model = SaveOptionsModel(showsFormat: false)
        panel.accessoryView = model.accessoryView()
        objc_setAssociatedObject(document, &optionsKey, model, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    #if DEBUG
    /// Stands in for the panel in automated runs.
    static func debugAttach(_ model: SaveOptionsModel, to document: NSDocument) {
        install(for: document)
        objc_setAssociatedObject(document, &optionsKey, model, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    #endif

    /// Makes the document what the options chosen in the panel say, just before it is written.
    ///
    /// - Returns: Whether the document was changed, and what went wrong, in which case nothing is saved.
    private static func applyOptions(to document: NSDocument, operation: UInt) -> (changed: Bool, failure: (any Error)?) {
        guard let model = objc_getAssociatedObject(document, &optionsKey) as? SaveOptionsModel else { return (false, nil) }
        objc_setAssociatedObject(document, &optionsKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // Only saves that came through the panel: Save As, Save To, and the first Save of a document with no file yet.
        let throughPanel = operation == NSDocument.SaveOperationType.saveAsOperation.rawValue
            || operation == NSDocument.SaveOperationType.saveToOperation.rawValue
            || (operation == NSDocument.SaveOperationType.saveOperation.rawValue && document.fileURL == nil)
        let options = model.pdfOptions
        guard throughPanel, !options.isPlain, let viewer = ViewerModel.viewer(of: document), let sheafDocument = viewer.sheafDocument else { return (false, nil) }
        do {
            let source = Toolbox.Source(data: sheafDocument.currentData, name: viewer.documentName, password: sheafDocument.password)
            let result = try Toolbox.save(source, with: options)
            // The document in the window becomes what is saved, so the two stay the same. Undo goes back.
            guard sheafDocument.replaceContents(String(localized: "Save Options"), with: result.data, password: result.password) else {
                return (false, CocoaError(.fileWriteUnknown))
            }
            return (true, nil)
        } catch {
            return (false, error)
        }
    }
}

extension ViewerModel {
    /// The viewers of the open documents.
    static let all = NSHashTable<ViewerModel>.weakObjects()

    /// The viewer whose window shows a document.
    static func viewer(of document: NSDocument) -> ViewerModel? {
        all.allObjects.first { ($0.window?.windowController?.document as? NSDocument) === document }
    }

    /// Makes the save panel of this viewer's document offer Sheaf's options.
    func prepareSaveOptions() {
        Self.all.add(self)
        if let document = window?.windowController?.document as? NSDocument { SavePanelOptions.install(for: document) }
        refreshMailOrigin()
    }
}
