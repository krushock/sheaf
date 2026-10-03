import AppKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// The grid of pages: pick, drag to reorder, drop files in, drag pages out.
struct PageOrganizer: NSViewRepresentable {
    let viewer: ViewerModel

    func makeCoordinator() -> Coordinator { Coordinator(viewer: viewer) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let collection = OrganizerCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(PageCell.self, forItemWithIdentifier: PageCell.identifier)
        collection.delegate = context.coordinator
        collection.viewer = viewer
        collection.registerForDraggedTypes([ViewerModel.pagePasteboardType, .fileURL])
        collection.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setAccessibilityLabel(String(localized: "Pages"))
        context.coordinator.attach(to: collection)

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(
            pages: viewer.pageIDs, selection: viewer.pageSelection, size: viewer.organizerPageSize,
            stale: viewer.thumbnailEdits
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout, NSFilePromiseProviderDelegate {
        let viewer: ViewerModel
        private weak var collection: OrganizerCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<Int, ObjectID>?
        private var pages: [ObjectID] = []
        private var size = 0.0
        private var stale: [ObjectID: Int] = [:]
        private var isSyncingSelection = false
        private var didTakeFocus = false
        /// What a drag to another app delivers, worked out when the drag starts.
        private var promisedData: Data?
        private var promisedName = ""
        private let promiseQueue = OperationQueue()

        init(viewer: ViewerModel) {
            self.viewer = viewer
        }

        func attach(to collection: OrganizerCollectionView) {
            self.collection = collection
            dataSource = NSCollectionViewDiffableDataSource<Int, ObjectID>(collectionView: collection) { [weak self] collection, indexPath, id in
                let item = collection.makeItem(withIdentifier: PageCell.identifier, for: indexPath)
                if let cell = item as? PageCell, let self { cell.show(page: id, number: indexPath.item + 1, viewer: self.viewer) }
                return item
            }
        }

        func sync(pages newPages: [ObjectID], selection: Set<ObjectID>, size newSize: Double, stale newStale: [ObjectID: Int]) {
            guard let collection, let dataSource else { return }
            if newSize != size {
                size = newSize
                collection.collectionViewLayout?.invalidateLayout()
            }
            if newPages != pages {
                let isFirst = pages.isEmpty
                pages = newPages
                var snapshot = NSDiffableDataSourceSnapshot<Int, ObjectID>()
                snapshot.appendSections([0])
                snapshot.appendItems(newPages)
                dataSource.apply(snapshot, animatingDifferences: !isFirst)
            }
            // Page numbers and pictures of the cells on screen, which may have moved or changed.
            let changed = newStale != stale
            stale = newStale
            for indexPath in collection.indexPathsForVisibleItems() {
                guard let cell = collection.item(at: indexPath) as? PageCell, newPages.indices.contains(indexPath.item) else { continue }
                cell.update(number: indexPath.item + 1, reloading: changed, viewer: viewer)
            }

            let wanted = Set(newPages.indices.filter { selection.contains(newPages[$0]) }.map { IndexPath(item: $0, section: 0) })
            if collection.selectionIndexPaths != wanted {
                isSyncingSelection = true
                collection.selectionIndexPaths = wanted
                isSyncingSelection = false
            }
            if !didTakeFocus, collection.window != nil {
                didTakeFocus = true
                collection.window?.makeFirstResponder(collection)
                if let first = wanted.min() { collection.scrollToItems(at: [first], scrollPosition: .centeredVertically) }
            } else if !didTakeFocus {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let collection = self.collection, !self.didTakeFocus, collection.window != nil else { return }
                    self.didTakeFocus = true
                    collection.window?.makeFirstResponder(collection)
                }
            }
        }

        // MARK: Layout

        func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            // Every cell has the same box; pages of other shapes are fitted inside it.
            NSSize(width: size + 2 * PageCell.padding, height: size * 1.3 + PageCell.labelHeight + 2 * PageCell.padding)
        }

        // MARK: Selection

        private func selectionChanged(in collection: NSCollectionView) {
            guard !isSyncingSelection else { return }
            viewer.pageSelection = Set(collection.selectionIndexPaths.compactMap { pages.indices.contains($0.item) ? pages[$0.item] : nil })
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(in: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(in: collectionView)
        }

        // MARK: Dragging pages

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            viewer.canEditPages || viewer.sheafDocument != nil
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            // One of the dragged pages also promises a file, holding all of them, for drops
            // on the Finder and other apps.
            let dragged = collectionView.selectionIndexPaths.contains(indexPath) ? collectionView.selectionIndexPaths : [indexPath]
            if indexPath == dragged.min() {
                let promise = PagePromise(fileType: UTType.pdf.identifier, delegate: self)
                promise.pageIndex = indexPath.item
                return promise
            }
            let item = NSPasteboardItem()
            item.setString(String(indexPath.item), forType: ViewerModel.pagePasteboardType)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            let indexes = indexPaths.map(\.item).sorted()
            promisedData = viewer.data(forPages: indexes)
            promisedName = viewer.nameForPages(indexes)
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            promisedData = nil
        }

        func collectionView(
            _ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            guard viewer.canEditPages else { return [] }
            // Between pages, never onto one.
            dropOperation.pointee = .before
            if draggingInfo.draggingSource as? NSCollectionView === collectionView { return .move }
            let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return urls.contains(where: ViewerModel.canInsert) ? .copy : []
        }

        func collectionView(
            _ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            let pasteboard = draggingInfo.draggingPasteboard
            if draggingInfo.draggingSource as? NSCollectionView === collectionView {
                let indexes = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: ViewerModel.pagePasteboardType).flatMap(Int.init) }
                guard !indexes.isEmpty else { return false }
                viewer.movePages(indexes, to: indexPath.item)
                return true
            }
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                .filter(ViewerModel.canInsert)
            guard !urls.isEmpty else { return false }
            viewer.insertFiles(urls, at: indexPath.item)
            return true
        }

        // MARK: File promises

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            MainActor.assumeIsolated { promisedName + ".pdf" }
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
            let data = DispatchQueue.main.sync { MainActor.assumeIsolated { promisedData } }
            do {
                guard let data else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }
    }
}

/// A file promise that also says which page it stands for, so the same drag can reorder
/// pages inside the window.
nonisolated final class PagePromise: NSFilePromiseProvider, @unchecked Sendable {
    /// Set once, before the promise goes on the pasteboard.
    nonisolated(unsafe) var pageIndex = 0
    private static let pageType = NSPasteboard.PasteboardType("com.valeryburtsev.sheaf.page")

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [Self.pageType] + super.writableTypes(for: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.pageType ? String(pageIndex) : super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == Self.pageType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

/// The collection view, with the keyboard, double-click and menu behavior of a page grid.
final class OrganizerCollectionView: NSCollectionView {
    weak var viewer: ViewerModel?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return }
        viewer?.openPage(at: indexPath.item)
    }

    override func keyDown(with event: NSEvent) {
        guard let viewer else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            if viewer.canDeleteTargetPages { viewer.deletePages(viewer.targetPageIndexes) } else { NSSound.beep() }
        case 36, 76: // return, enter
            if let first = viewer.targetPageIndexes.first { viewer.openPage(at: first) }
        case 53: // escape
            viewer.isOrganizing = false
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let viewer, viewer.canEditPages else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            // A click on a page outside the selection picks that page alone.
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
                delegate?.collectionView?(self, didSelectItemsAt: [indexPath])
            }
        } else {
            deselectAll(nil)
            delegate?.collectionView?(self, didDeselectItemsAt: [])
        }
        let menu = NSMenu()
        let hasTargets = !viewer.targetPageIndexes.isEmpty
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if hasTargets {
            add(String(localized: "Rotate Left"), #selector(rotateLeft(_:)))
            add(String(localized: "Rotate Right"), #selector(rotateRight(_:)))
            menu.addItem(.separator())
            add(String(localized: "Duplicate"), #selector(duplicate(_:)))
            add(String(localized: "Delete"), #selector(delete(_:)), enabled: viewer.canDeleteTargetPages)
            menu.addItem(.separator())
            add(String(localized: "Copy"), #selector(copy(_:)))
        }
        add(String(localized: "Paste"), #selector(paste(_:)), enabled: viewer.canPastePages)
        menu.addItem(.separator())
        add(String(localized: "Insert Blank Page"), #selector(insertBlankPage(_:)))
        add(String(localized: "Insert from File…"), #selector(insertFromFile(_:)))
        if hasTargets {
            menu.addItem(.separator())
            add(String(localized: "Open as New Document"), #selector(extract(_:)))
        }
        return menu
    }

    // MARK: Actions, reached from the menus and the responder chain

    @objc func rotateLeft(_ sender: Any?) { viewer.map { $0.rotatePages($0.targetPageIndexes, by: -90) } }
    @objc func rotateRight(_ sender: Any?) { viewer.map { $0.rotatePages($0.targetPageIndexes, by: 90) } }
    @objc func duplicate(_ sender: Any?) { viewer.map { $0.duplicatePages($0.targetPageIndexes) } }
    @objc func delete(_ sender: Any?) { viewer.map { $0.deletePages($0.targetPageIndexes) } }
    @objc func copy(_ sender: Any?) { viewer.map { $0.copyPages($0.targetPageIndexes) } }
    @objc func paste(_ sender: Any?) { viewer?.pastePages() }
    @objc func insertBlankPage(_ sender: Any?) { viewer?.insertBlankPage() }
    @objc func insertFromFile(_ sender: Any?) { viewer?.chooseFilesToInsert() }
    @objc func extract(_ sender: Any?) { viewer.map { $0.extractPages($0.targetPageIndexes) } }

    @objc func cut(_ sender: Any?) {
        guard let viewer, viewer.canDeleteTargetPages else { return NSSound.beep() }
        viewer.copyPages(viewer.targetPageIndexes)
        viewer.deletePages(viewer.targetPageIndexes)
    }

}

extension OrganizerCollectionView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let viewer else { return false }
        switch menuItem.action {
        case #selector(delete(_:)), #selector(cut(_:)): return viewer.canDeleteTargetPages
        case #selector(copy(_:)), #selector(duplicate(_:)): return !viewer.targetPageIndexes.isEmpty
        case #selector(paste(_:)): return viewer.canPastePages
        default: return true
        }
    }
}

/// One page in the grid: its picture, its number, and a highlight when picked.
final class PageCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("page")
    static let padding = 8.0
    static let labelHeight = 22.0

    private let picture = PagePictureView()
    private let label = NSTextField(labelWithString: "")
    private let highlight = NSView()
    private var page: ObjectID?
    private var loading: Task<Void, Never>?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.layer?.cornerCurve = .continuous
        root.addSubview(highlight)

        root.addSubview(picture)

        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        root.addSubview(label)
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        highlight.frame = bounds
        label.frame = NSRect(x: 4, y: Self.padding - 2, width: bounds.width - 8, height: 16)
        picture.frame = NSRect(
            x: Self.padding, y: Self.padding + Self.labelHeight,
            width: bounds.width - 2 * Self.padding, height: bounds.height - 2 * Self.padding - Self.labelHeight
        )
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        let showsSelection = isSelected || highlightState == .forSelection
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.layer?.backgroundColor = showsSelection ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        }
        label.textColor = showsSelection ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    func show(page id: ObjectID, number: Int, viewer: ViewerModel) {
        let isSamePage = page == id
        page = id
        if !isSamePage { picture.image = nil }
        update(number: number, reloading: true, viewer: viewer)
        updateHighlight()
    }

    func update(number: Int, reloading: Bool, viewer: ViewerModel) {
        label.stringValue = String(number)
        view.setAccessibilityLabel(String(localized: "Page \(number)"))
        guard reloading || picture.image == nil, let page else { return }
        loading?.cancel()
        loading = Task { [weak self] in
            // Looked up afresh: the page may have moved since the cell was made.
            guard let index = viewer.pageIDs.firstIndex(of: page) else { return }
            let image = await viewer.thumbnail(forPage: index)
            guard !Task.isCancelled, let self, self.page == page else { return }
            self.picture.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        page = nil
        picture.image = nil
    }
}

/// Draws a page's picture fitted in its box, on white, with a soft shadow.
final class PagePictureView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Until the picture arrives, a sheet of the usual proportions holds its place.
        let ratio = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 0.77
        let area = bounds.insetBy(dx: 4, dy: 4)
        var size = CGSize(width: area.width, height: area.width / ratio)
        if size.height > area.height { size = CGSize(width: area.height * ratio, height: area.height) }
        let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(frame)
        context.restoreGState()
        if let image {
            context.interpolationQuality = .high
            context.draw(image, in: frame)
        }
    }
}
