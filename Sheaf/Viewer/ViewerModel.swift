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
    @ObservationIgnored weak var window: NSWindow? {
        didSet { if window != nil { prepareSaveOptions() } }
    }
    /// The document being shown, which every edit goes through.
    @ObservationIgnored private(set) weak var sheafDocument: SheafDocument?

    private(set) var document: PDFDocument?
    private(set) var pageCount = 0
    private(set) var currentPageIndex = 0
    private(set) var isFitToWindow = true
    /// Whether the zoom follows the window so that a whole page is always in view.
    private(set) var isFitPage = false
    /// The zoom as a whole percentage, for showing in the toolbar.
    private(set) var zoomPercent = 100
    /// The zoom that fitting a whole page last came to.
    @ObservationIgnored private var fittedScale: CGFloat = 0
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
            if isMarkupVisible {
                isFormEditing = false
                isContentEditing = false
            }
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
    /// Where the blank page being sized in its sheet will go.
    @ObservationIgnored var blankPagePosition: Int?

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

    // MARK: Content editing state

    /// Whether the row of editing tools is showing. While it is, clicking text or a
    /// picture selects it, and double-clicking text puts the cursor in it.
    var isContentEditing = false {
        didSet { if isContentEditing != oldValue { contentEditingDidToggle() } }
    }

    var editTool = EditTool.select {
        didSet {
            if editTool != oldValue { pdfView.window?.invalidateCursorRects(for: pdfView) }
            if editTool != .select { contentSelection = nil }
        }
    }

    /// The block of text or the picture picked on a page.
    var contentSelection: ContentTarget? {
        didSet {
            guard contentSelection != oldValue else { return }
            pdfView.overlay.needsDisplay = true
            // A mask is changed on the picture that is selected, and no other.
            if let edit = maskEdit, contentSelection != .image(pageIndex: edit.pageIndex, id: edit.imageID) { maskEdit = nil }
            // The page is a picture as far as VoiceOver is concerned, so say what was picked.
            if let description = contentSelectionDescription, let window {
                NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                    .announcement: description, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            }
        }
    }

    /// Whether redaction marks are shown as the black boxes they will become.
    var previewsRedactions = false {
        didSet { pdfView.overlay.needsDisplay = true }
    }

    var isApplyRedactionsConfirmationPresented = false
    /// Something to tell the person about the last editing command.
    var editMessage: String?

    /// How text made with the text tool looks.
    var newTextStyle = NewTextStyle()

    /// A drag in progress on a block of text or a picture.
    @ObservationIgnored var contentDrag: ContentDrag? {
        didSet { pdfView.overlay.needsDisplay = true }
    }

    /// The mask of a picture being changed.
    var maskEdit: MaskEdit? {
        didSet {
            pdfView.overlay.needsDisplay = true
            pdfView.window?.invalidateCursorRects(for: pdfView)
        }
    }

    /// Whether the background is being taken out of a picture.
    var isRemovingBackground = false

    @ObservationIgnored var stackingCache: (key: String, moves: Set<StackingMove>)?
    @ObservationIgnored var contentCache: [Int: (revision: Int, generation: Int, content: PageContent)] = [:]
    @ObservationIgnored var markCache: (revision: Int, generation: Int, marks: [Int: [Annotation]])?

    /// Whether a row of tools sits between the toolbar and the pages.
    var hasToolRow: Bool { isMarkupVisible || isFormEditing || isContentEditing || isReplaceVisible }

    // MARK: Find and replace state

    var isReplaceVisible = false {
        didSet { if isReplaceVisible != oldValue { replaceVisibilityChanged() } }
    }

    var replaceQuery = "" {
        didSet { if replaceQuery != oldValue { scheduleTextSearch() } }
    }

    var replacement = ""
    var replaceOptions = TextSearchOptions() {
        didSet { if replaceOptions != oldValue { scheduleTextSearch() } }
    }

    var textMatches: [TextMatch] = [] {
        didSet { pdfView.overlay.needsDisplay = true }
    }

    var currentMatchIndex: Int? {
        didSet { pdfView.overlay.needsDisplay = true }
    }

    var isFindingText = false
    /// Incremented to ask the find and replace bar to put the cursor in its first field.
    var replaceFocusRequests = 0
    @ObservationIgnored var textSearchTask: Task<Void, Never>?

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
        pdfView.backgroundColor = Self.canvasColor
        pdfView.displaysPageBreaks = true
        pdfView.displaysAsBook = true
        applyLayout()

        let center = NotificationCenter.default
        for name: Notification.Name in [.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewChangedHistory, .PDFViewDisplayModeChanged] {
            center.addObserver(self, selector: #selector(viewStateChanged), name: name, object: pdfView)
        }
        center.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: pdfView)
        pdfView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(viewFrameChanged), name: NSView.frameDidChangeNotification, object: pdfView)
        // Room for every level in the zoom menu, and a little beyond for pinching.
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8
    }

    /// The gray behind the pages. The system's own choice is almost the sidebar's color,
    /// so the strip beside a page read as more sidebar and the toolbar seemed to cut
    /// into it. This is a step darker, which makes the page area one clear block.
    static let canvasColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.84, alpha: 1)
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
        // When the pages are the same size as before, as after a change to what a page
        // draws, the view stays exactly where it was.
        let sameShape = isReload && document?.pageCount == newDocument.pageCount
        let scrollOrigin = sameShape ? pdfView.scrollOrigin : nil

        cancelSearch()
        document?.delegate = nil
        pdfView.endTextEditing(commit: false)
        pdfView.endContentEditing(commit: false)
        drag = nil
        contentDrag = nil
        maskEdit = nil
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
        prepareSaveOptions()
        // PDFKit's own drawing of the annotations Sheaf draws is switched off for the
        // pages about to show before they do, so it is never seen.
        let near = place?.page ?? 0
        for index in max(near - 2, 0)..<min(near + 3, newDocument.pageCount) { _ = sharpAnnotations(onPage: index) }
        if let place {
            pdfView.autoScales = place.autoScales
            if !place.autoScales { pdfView.scaleFactor = place.scale }
            if let scrollOrigin {
                pdfView.layoutDocumentView()
                pdfView.scrollOrigin = scrollOrigin
                DispatchQueue.main.async { [pdfView] in pdfView.scrollOrigin = scrollOrigin }
            } else {
                let target = min(place.page, max(pageCount - 1, 0))
                DispatchQueue.main.async { [weak self] in self?.goToPage(index: target) }
            }
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
        hideNativeMarks()
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
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
        // Zooming by hand, as with a pinch, ends keeping the page fitted.
        if isFitPage, abs(pdfView.scaleFactor - fittedScale) > 0.001 { isFitPage = false }
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
        applyFitPage()
    }

    /// The zoom levels offered in the toolbar's menu, in percent.
    static let zoomSteps = [25, 50, 75, 100, 125, 150, 200, 300, 400]

    func zoomIn() {
        isFitPage = false
        pdfView.zoomIn(nil)
    }

    func zoomOut() {
        isFitPage = false
        pdfView.zoomOut(nil)
    }

    func zoomToActualSize() {
        setZoom(percent: 100)
    }

    /// Shows the pages at a fixed zoom.
    func setZoom(percent: Int) {
        isFitPage = false
        pdfView.autoScales = false
        pdfView.scaleFactor = CGFloat(percent) / 100
        viewStateChanged()
    }

    /// Whether the pages are at exactly this zoom, by choice and not because fitting the
    /// window happened to land on it.
    func isZoomed(to percent: Int) -> Bool {
        !isFitToWindow && !isFitPage && zoomPercent == percent
    }

    /// Fits the width of the page to the window, and keeps it fitted as the window changes.
    func zoomToFit() {
        isFitPage = false
        pdfView.autoScales = true
        viewStateChanged()
    }

    /// Fits a whole page in the window, and keeps it fitted as the window changes.
    func zoomToFitPage() {
        isFitPage = true
        fittedScale = pdfView.scaleFactor
        let index = currentPageIndex
        applyFitPage()
        // The page being read, squarely in the window: the point of fitting it.
        goToPage(index: index)
    }

    private func applyFitPage() {
        guard isFitPage, let page = pdfView.currentPage ?? document?.page(at: 0) else { return }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return }
        // Two pages side by side need twice the width.
        let across: CGFloat = layout == .twoPages ? 2 : 1
        // What is left of the view under the toolbar, less the gaps PDFKit leaves around pages.
        let margins = pdfView.pageBreakMargins
        let available = CGSize(
            width: pdfView.bounds.width - (margins.left + margins.right) * across - 8,
            height: pdfView.bounds.height - pdfView.safeAreaInsets.top - margins.top - margins.bottom - 8
        )
        guard available.width > 20, available.height > 20 else { return }
        let scale = min(available.width / (size.width * across), available.height / size.height)
        pdfView.autoScales = false
        fittedScale = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        pdfView.scaleFactor = fittedScale
        viewStateChanged()
    }

    /// The view changed size: a page that is being kept whole in the window is fitted again.
    @objc private func viewFrameChanged() {
        applyFitPage()
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
            let image = sheafDocument?.withAllAnnotationsDrawnByPDFKit(onPage: index) {
                page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            } ?? nil
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
