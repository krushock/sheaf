import AppKit
import PDFKit
import SheafKit
import SwiftUI

/// Identifies one drawing of a page's thumbnail.
struct ThumbnailVersion: Hashable {
    let page: ObjectID
    let edits: Int
}

/// One search hit.
struct SearchResult: Identifiable {
    let id: Int
    let selection: PDFSelection
    let pageIndex: Int
}

/// The state and actions of one viewer window. Owns the `PDFView` and mirrors what it
/// shows into observable properties, so SwiftUI views and menu commands stay in sync.
@Observable
final class ViewerModel: NSObject {
    @ObservationIgnored let pdfView = SheafPDFView()
    /// The window showing this viewer. Set by the view, since the pages are not always in it.
    @ObservationIgnored weak var window: NSWindow?
    /// The document being shown, which every edit goes through.
    @ObservationIgnored private(set) weak var sheafDocument: SheafDocument?

    private(set) var document: PDFDocument?
    private(set) var pageCount = 0
    private(set) var currentPageIndex = 0
    private(set) var isFitToWindow = true
    private(set) var canZoomIn = false
    private(set) var canZoomOut = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    var layout: PageLayout {
        didSet { applyLayout() }
    }

    var sidebarMode: SidebarMode
    var isSidebarVisible: Bool
    var isGoToPagePresented = false

    // MARK: Markup state

    /// Whether the row of markup tools is showing.
    var isMarkupVisible = false {
        didSet {
            if !isMarkupVisible { tool = .select }
            if isMarkupVisible { isFormEditing = false }
        }
    }

    var isInspectorVisible = false
    var isFlattenConfirmationPresented = false
    var isSignaturePickerPresented = false
    var isSignatureCreatorPresented = false

    var tool = MarkupTool.select {
        didSet {
            if tool != oldValue { pdfView.window?.invalidateCursorRects(for: pdfView) }
            if tool != .select { selection = nil }
        }
    }

    /// The look each tool gives to what it makes next.
    var styles: [MarkupTool: MarkupStyle] = [:]

    /// The annotation picked on the page, if any.
    var selection: AnnotationSelection? {
        didSet { if selection != oldValue { pdfView.overlay.needsDisplay = true } }
    }

    /// Incremented to ask the inspector to put the cursor in the comment field.
    private(set) var commentFocusRequests = 0

    /// How many times each page's look has changed, so views know to draw its thumbnail again.
    private(set) var thumbnailEdits: [ObjectID: Int] = [:]

    /// Pages edited since the document was last read into the background copy. Their
    /// thumbnails have to come from the page on screen.
    @ObservationIgnored private var pagesAheadOfWorker: Set<ObjectID> = []

    // MARK: Page organizer state

    /// The document's pages in order, each named by the object that holds it. A page keeps
    /// its name when it is moved, which is how thumbnails and the selection follow it.
    private(set) var pageIDs: [ObjectID] = []

    /// Whether the grid of pages is showing instead of the pages themselves.
    var isOrganizing = false {
        didSet { if isOrganizing != oldValue { organizerDidToggle() } }
    }

    /// The pages picked in the organizer.
    var pageSelection: Set<ObjectID> = []

    /// The width of a page in the organizer, in points.
    var organizerPageSize: Double = Preferences.organizerPageSize {
        didSet { UserDefaults.standard.set(organizerPageSize, forKey: Preferences.organizerPageSizeKey) }
    }

    /// The tool sheet showing on the window, if any.
    var activeSheet: ToolSheet?

    // MARK: Form state

    /// Whether the row of form tools is showing. While it is, clicking a field selects it
    /// for moving and changing; otherwise clicking a field fills it in.
    var isFormEditing = false {
        didSet { if isFormEditing != oldValue { formEditingDidToggle() } }
    }

    /// The kind of field the next drag on a page makes.
    var formTool: FormTool? {
        didSet { if formTool != oldValue { pdfView.window?.invalidateCursorRects(for: pdfView) } }
    }

    /// The field the keyboard acts on while filling in a form.
    var focusedWidget: ObjectID? {
        didSet { if focusedWidget != oldValue { pdfView.overlay.needsDisplay = true } }
    }

    /// Whether fields that can be filled in are tinted, so they are easy to find.
    var highlightsFields = UserDefaults.standard.object(forKey: Preferences.highlightsFields) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(highlightsFields, forKey: Preferences.highlightsFields)
            pdfView.overlay.needsDisplay = true
        }
    }

    var isResetFormConfirmationPresented = false
    var isFlattenFormConfirmationPresented = false
    /// What Detect Fields found, to tell the person.
    var detectionMessage: String?

    /// Where the next signature goes: into a signature field that was clicked.
    @ObservationIgnored var signatureTarget: (pageIndex: Int, rect: PDFRectangle)?
    @ObservationIgnored var fieldCache: (revision: Int, generation: Int, fields: [FormField])?
    /// Pages whose fields no longer carry PDFKit's own tint.
    @ObservationIgnored private var settledFieldPages: Set<Int> = []

    /// A drag in progress: making, moving or resizing an annotation.
    @ObservationIgnored var drag: DragSession?

    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }

    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    var selectedSearchResultID: Int? {
        didSet { if selectedSearchResultID != oldValue { showSelectedSearchResult() } }
    }

    /// Incremented to ask the window to put the cursor in the search field.
    private(set) var searchFocusRequests = 0

    /// The file's bytes, for Export as PDF.
    @ObservationIgnored private(set) var sourceData: Data?
    @ObservationIgnored private var worker: DocumentWorker?
    @ObservationIgnored private var thumbnailCache: [ObjectID: CGImage] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMatches: [SearchResult] = []
    @ObservationIgnored private var matchCount = 0

    override init() {
        layout = Preferences.value(Preferences.pageLayout, default: .continuous)
        switch Preferences.value(Preferences.openingSidebar, default: OpeningSidebar.thumbnails) {
        case .hidden:
            isSidebarVisible = false
            sidebarMode = .thumbnails
        case .thumbnails:
            isSidebarVisible = true
            sidebarMode = .thumbnails
        case .tableOfContents:
            isSidebarVisible = true
            sidebarMode = .tableOfContents
        }
        super.init()

        pdfView.viewer = self
        pdfView.displaysPageBreaks = true
        pdfView.displaysAsBook = true
        applyLayout()

        let center = NotificationCenter.default
        for name: Notification.Name in [.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewChangedHistory, .PDFViewDisplayModeChanged] {
            center.addObserver(self, selector: #selector(viewStateChanged), name: name, object: pdfView)
        }
        center.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: pdfView)
    }

    // MARK: Document

    /// Shows a document, or shows it again after its pages changed.
    func show(_ source: SheafDocument) {
        guard let newDocument = source.pdf else { return }
        // Already showing exactly this.
        if sheafDocument === source, document === newDocument { return }
        // The same document read again keeps its place; a different one starts at the top.
        let isReload = sheafDocument === source && document != nil
        let place = isReload ? (page: currentPageIndex, autoScales: pdfView.autoScales, scale: pdfView.scaleFactor) : nil

        cancelSearch()
        document?.delegate = nil
        pdfView.endTextEditing(commit: false)
        drag = nil
        selection = nil

        sheafDocument = source
        document = newDocument
        sourceData = source.displayData
        pageCount = newDocument.pageCount
        refreshPageIDs()
        if isReload {
            // Pages that only moved keep their thumbnails; those whose look changed do not.
            for index in source.lastChangedPages where pageIDs.indices.contains(index) {
                thumbnailCache[pageIDs[index]] = nil
                thumbnailEdits[pageIDs[index], default: 0] += 1
            }
            let present = Set(pageIDs)
            thumbnailCache = thumbnailCache.filter { present.contains($0.key) }
            thumbnailEdits = thumbnailEdits.filter { present.contains($0.key) }
            pageSelection.formIntersection(present)
        } else {
            thumbnailCache = [:]
            thumbnailEdits = [:]
            pageSelection = []
        }
        // The background copy made below has every edit.
        pagesAheadOfWorker = []

        pdfView.document = newDocument
        pdfView.observeScrolling()
        if let place {
            pdfView.autoScales = place.autoScales
            if !place.autoScales { pdfView.scaleFactor = place.scale }
            let target = min(place.page, max(pageCount - 1, 0))
            DispatchQueue.main.async { [weak self] in self?.goToPage(index: target) }
        } else {
            switch Preferences.value(Preferences.openingZoom, default: OpeningZoom.fitWidth) {
            case .fitWidth:
                pdfView.autoScales = true
            case .actualSize:
                pdfView.autoScales = false
                pdfView.scaleFactor = 1
            }
            // PDFView settles its scroll position only after layout, so start at the top then.
            DispatchQueue.main.async { [pdfView] in pdfView.goToFirstPage(nil) }
        }
        viewStateChanged()
        settledFieldPages = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.visiblePagesChanged() }

        worker = DocumentWorker(data: source.displayData, password: source.password)
        if !searchText.isEmpty { scheduleSearch() }
    }

    /// PDFKit tints form fields when it first draws a page and stops once the page's
    /// annotations are refreshed. Sheaf draws the tint itself, so each page with fields is
    /// refreshed once as it comes into view, which leaves one tint and not two.
    @objc private func visiblePagesChanged() {
        guard let document, hasForm else { return }
        let pagesWithFields = Set(formFields.flatMap { $0.widgets.compactMap(\.pageIndex) })
        for page in pdfView.visiblePages {
            let index = document.index(for: page)
            guard pagesWithFields.contains(index), settledFieldPages.insert(index).inserted else { continue }
            pdfView.annotationsChanged(on: page)
        }
        pdfView.overlay.needsDisplay = true
    }

    @objc private func viewStateChanged() {
        if let page = pdfView.currentPage, let index = document?.index(for: page), index != NSNotFound {
            currentPageIndex = index
        }
        isFitToWindow = pdfView.autoScales
        canZoomIn = pdfView.canZoomIn
        canZoomOut = pdfView.canZoomOut
        canGoBack = pdfView.canGoBack
        canGoForward = pdfView.canGoForward
        pdfView.overlay.needsDisplay = true
    }

    // MARK: Layout and zoom

    private func applyLayout() {
        switch layout {
        case .continuous: pdfView.displayMode = .singlePageContinuous
        case .singlePage: pdfView.displayMode = .singlePage
        case .twoPages: pdfView.displayMode = .twoUpContinuous
        }
    }

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }

    func zoomToActualSize() {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        viewStateChanged()
    }

    func zoomToFit() {
        pdfView.autoScales = true
        viewStateChanged()
    }

    // MARK: Navigation

    var pageSummary: String {
        pageCount > 0 ? String(localized: "Page \(currentPageIndex + 1) of \(pageCount)") : ""
    }

    func goToPage(index: Int) {
        guard let page = document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func goToNextPage() { pdfView.goToNextPage(nil) }
    func goToPreviousPage() { pdfView.goToPreviousPage(nil) }
    func goToFirstPage() { pdfView.goToFirstPage(nil) }
    func goToLastPage() { pdfView.goToLastPage(nil) }
    func goBack() { pdfView.goBack(nil) }
    func goForward() { pdfView.goForward(nil) }

    /// Jumps to where a table of contents entry points.
    func go(to item: OutlineItem) {
        guard let index = item.pageIndex, let page = document?.page(at: index) else { return }
        let top = item.top ?? page.bounds(for: .cropBox).maxY
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: top)))
    }

    /// Width divided by height of a page as displayed, for sizing its thumbnail.
    func aspectRatio(ofPage index: Int) -> CGFloat {
        guard let page = document?.page(at: index) else { return 0.77 }
        let size = page.bounds(for: .cropBox).size
        guard size.width > 0, size.height > 0 else { return 0.77 }
        return page.rotation % 180 == 0 ? size.width / size.height : size.height / size.width
    }

    /// Reads the page list from the document. A document the engine cannot read has no
    /// page objects to name, so its pages are named by position.
    func refreshPageIDs() {
        if let ids = try? sheafDocument?.editor?.pageIDs(), ids.count == pageCount {
            pageIDs = ids
        } else {
            pageIDs = (0..<pageCount).map { ObjectID(-1 - $0) }
        }
    }

    /// Marks pages whose thumbnails no longer match what they show.
    func invalidateThumbnails(_ pages: some Sequence<Int>) {
        for page in pages where pageIDs.indices.contains(page) {
            thumbnailCache[pageIDs[page]] = nil
            thumbnailEdits[pageIDs[page], default: 0] += 1
            pagesAheadOfWorker.insert(pageIDs[page])
        }
    }

    /// Changes when the thumbnail of the page at an index has to be drawn again: after an
    /// edit to the page, and when another page takes its place.
    func thumbnailVersion(forPage index: Int) -> ThumbnailVersion {
        guard pageIDs.indices.contains(index) else { return ThumbnailVersion(page: ObjectID(0), edits: 0) }
        return ThumbnailVersion(page: pageIDs[index], edits: thumbnailEdits[pageIDs[index]] ?? 0)
    }

    static let thumbnailPixelSize: CGFloat = 520

    func thumbnail(forPage index: Int) async -> CGImage? {
        guard pageIDs.indices.contains(index) else { return nil }
        let id = pageIDs[index]
        if let cached = thumbnailCache[id] { return cached }
        if pagesAheadOfWorker.contains(id), let page = document?.page(at: index) {
            // An edited page: the background copy of the document does not have the edits,
            // so draw this one from the live page.
            let ratio = aspectRatio(ofPage: index), side = Self.thumbnailPixelSize
            let size = ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
            let image = page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            thumbnailCache[id] = image
            return image
        }
        guard let worker else { return nil }
        let image = await worker.thumbnail(pageIndex: index, maxPixelSize: Self.thumbnailPixelSize)
        // The document may have been replaced, or its pages moved, while this was rendering.
        if worker === self.worker, let image { thumbnailCache[id] = image }
        return image
    }

    // MARK: Search

    var isShowingSearchResults: Bool { !searchText.isEmpty }

    func focusSearchField() { searchFocusRequests += 1 }
    func focusCommentField() { commentFocusRequests += 1 }

    func selectNextSearchResult() { stepSearchResult(by: 1) }
    func selectPreviousSearchResult() { stepSearchResult(by: -1) }

    private func stepSearchResult(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        let current = selectedSearchResultID ?? (offset > 0 ? -1 : 0)
        selectedSearchResultID = (current + offset + searchResults.count) % searchResults.count
    }

    private func showSelectedSearchResult() {
        guard let id = selectedSearchResultID, searchResults.indices.contains(id) else {
            pdfView.clearSelection()
            return
        }
        let selection = searchResults[id].selection
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    private func cancelSearch() {
        searchTask?.cancel()
        document?.cancelFindString()
        pendingMatches = []
        matchCount = 0
        searchResults = []
        selectedSearchResultID = nil
        isSearching = false
        pdfView.highlightedSelections = nil
    }

    private func scheduleSearch() {
        cancelSearch()
        let query = searchText
        guard !query.isEmpty, let document else { return }
        isSearching = true
        // Wait for a pause in typing before starting.
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            document.delegate = self
            document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        }
    }

    private func flushPendingMatches() {
        guard !pendingMatches.isEmpty else { return }
        searchResults.append(contentsOf: pendingMatches)
        pendingMatches = []
    }
}

extension ViewerModel: @preconcurrency PDFDocumentDelegate {
    func didMatchString(_ instance: PDFSelection) {
        guard let page = instance.pages.first, let index = document?.index(for: page) else { return }
        instance.color = .systemYellow
        pendingMatches.append(SearchResult(id: matchCount, selection: instance, pageIndex: index))
        matchCount += 1
    }

    func documentDidEndPageFind(_ notification: Notification) {
        flushPendingMatches()
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        flushPendingMatches()
        isSearching = false
        pdfView.highlightedSelections = searchResults.map(\.selection)
        if selectedSearchResultID == nil, !searchResults.isEmpty {
            // Start from the first hit at or after the page being read.
            selectedSearchResultID = searchResults.first { $0.pageIndex >= currentPageIndex }?.id ?? 0
        }
    }
}
