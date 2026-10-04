import AppKit
import PDFKit
import SheafKit
import SwiftUI

/// One of the two documents being compared.
struct CompareSource: Sendable {
    var data: Data
    var name: String
    var password: String?
}

/// The state of the Compare window: two documents, their differences, and which is in view.
@Observable
final class CompareModel {
    enum Side { case original, revised }

    private(set) var original: CompareSource?
    private(set) var revised: CompareSource?
    private(set) var comparison: DocumentComparison?
    /// The fraction done while comparing, or `nil` when not.
    private(set) var progress: Double?
    var errorMessage: String?
    var selection: DocumentChange.ID? {
        didSet { if selection != oldValue { showSelection() } }
    }

    var syncsScrolling = true

    @ObservationIgnored let originalView = PDFView()
    @ObservationIgnored let revisedView = PDFView()
    @ObservationIgnored private var geometries: (original: [PageGeometry], revised: [PageGeometry]) = ([], [])
    @ObservationIgnored private var focusMarks: [PDFAnnotation] = []
    @ObservationIgnored private var isFollowing = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var stop = StopFlag()

    #if DEBUG
    /// The model of the Compare window, for automated runs to look at.
    nonisolated(unsafe) static weak var current: CompareModel?
    #endif

    init() {
        #if DEBUG
        Self.current = self
        #endif
        for view in [originalView, revisedView] {
            view.displayMode = .singlePageContinuous
            view.autoScales = true
            view.displaysPageBreaks = true
        }
    }

    var changes: [DocumentChange] { comparison?.changes ?? [] }
    var isReady: Bool { original != nil && revised != nil }

    func name(_ side: Side) -> String {
        (side == .original ? original : revised)?.name ?? ""
    }

    // MARK: Choosing documents

    func set(_ source: CompareSource?, as side: Side) {
        if side == .original { original = source } else { revised = source }
        comparison = nil
        selection = nil
        if isReady { compare() }
    }

    /// Reads a file to compare, asking for its password if it has one.
    ///
    /// - Returns: `nil` when the file cannot be used; `message` then says why, unless the
    ///   person chose to skip a protected file.
    static func read(_ url: URL) -> (source: CompareSource?, message: String?) {
        guard var source = try? Toolbox.Source(url: url) else {
            return (nil, String(localized: "“\(url.lastPathComponent)” could not be read."))
        }
        guard source.isPDF, let document = PDFDocument(data: source.data) else {
            return (nil, String(localized: "“\(url.lastPathComponent)” is not a PDF."))
        }
        if document.isLocked {
            var wasWrong = false
            while true {
                guard let password = PasswordRequest.ask(named: url.lastPathComponent, wasWrong: wasWrong) else { return (nil, nil) }
                if document.unlock(withPassword: password) {
                    source.password = password
                    break
                }
                wasWrong = true
            }
        }
        return (CompareSource(data: source.data, name: url.lastPathComponent, password: source.password), nil)
    }

    func load(_ url: URL, as side: Side) {
        let result = Self.read(url)
        if let message = result.message { errorMessage = message }
        if let source = result.source { set(source, as: side) }
    }

    func choose(_ side: Side) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = side == .original ? String(localized: "Choose the original document.") : String(localized: "Choose the revised document.")
        if panel.runModal() == .OK, let url = panel.url { load(url, as: side) }
    }

    func swapSides() {
        (original, revised) = (revised, original)
        comparison = nil
        selection = nil
        if isReady { compare() }
    }

    // MARK: Comparing

    func cancel() {
        stop.set()
    }

    private func compare() {
        guard let original, let revised else { return }
        work?.cancel()
        let stop = StopFlag()
        self.stop = stop
        progress = 0
        errorMessage = nil
        work = Task {
            let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
            let job = Task.detached(priority: .userInitiated) { () -> Result<Outcome, any Error> in
                defer { continuation.finish() }
                return Result { try Self.run(original, revised) { value in
                    continuation.yield(value)
                    return !stop.isSet
                } }
            }
            for await value in updates { progress = value }
            progress = nil
            switch await job.value {
            case .success(let outcome): show(outcome, original: original, revised: revised)
            case .failure(let error):
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    private struct Outcome: Sendable {
        var comparison: DocumentComparison
        var originalGeometry: [PageGeometry]
        var revisedGeometry: [PageGeometry]
    }

    /// The whole comparison, off the main thread: words first, then how pages look.
    private nonisolated static func run(_ original: CompareSource, _ revised: CompareSource, progress: @escaping @Sendable (Double) -> Bool) throws -> Outcome {
        let first = try Toolbox.Source(data: original.data, name: original.name, password: original.password).editor()
        let second = try Toolbox.Source(data: revised.data, name: revised.name, password: revised.password).editor()
        var comparison = try DocumentComparer.compare(first, second) { progress($0 * 0.7) }

        // Pages whose words are the same may still look different: a picture swapped, a
        // line moved. Those are found by drawing both and comparing the drawings.
        let withTextChanges = Set(comparison.changes.compactMap { change in change.pageA.flatMap { a in change.pageB.map { "\(a)/\($0)" } } })
        if let documentA = PDFDocument(data: original.data), let documentB = PDFDocument(data: revised.data) {
            if let password = original.password { documentA.unlock(withPassword: password) }
            if let password = revised.password { documentB.unlock(withPassword: password) }
            let pairs = comparison.pagePairs
            for (number, pair) in pairs.enumerated() {
                guard progress(0.7 + 0.3 * Double(number) / Double(max(pairs.count, 1))) else { throw CancellationError() }
                guard let a = pair.a, let b = pair.b, !withTextChanges.contains("\(a)/\(b)"),
                      let pageA = documentA.page(at: a), let pageB = documentB.page(at: b)
                else { continue }
                let frames = PageDifference.frames(pageA, pageB)
                if !frames.isEmpty {
                    comparison.changes.append(DocumentChange(id: 0, kind: .appearance, pageA: a, pageB: b, framesA: frames, framesB: frames))
                }
            }
        }
        // In reading order of the revised document, with numbers that say so.
        func place(_ change: DocumentChange) -> (page: Int, down: Double) {
            let frame = change.framesB.first ?? change.framesA.first
            return (change.pageB ?? change.pageA ?? 0, -(frame?.y ?? 0))
        }
        comparison.changes.sort { place($0) < place($1) }
        for index in comparison.changes.indices { comparison.changes[index].id = index }

        func geometries(_ editor: PDFEditor) -> [PageGeometry] {
            ((try? editor.pageCount()).map { Array(0..<$0) } ?? []).compactMap { try? editor.geometry(ofPageAt: $0) }
        }
        return Outcome(comparison: comparison, originalGeometry: geometries(first), revisedGeometry: geometries(second))
    }

    private func show(_ outcome: Outcome, original: CompareSource, revised: CompareSource) {
        guard let documentA = PDFDocument(data: original.data), let documentB = PDFDocument(data: revised.data) else { return }
        if let password = original.password { documentA.unlock(withPassword: password) }
        if let password = revised.password { documentB.unlock(withPassword: password) }
        geometries = (outcome.originalGeometry, outcome.revisedGeometry)
        // Marks are added to the copies on screen only; neither file is touched.
        for change in outcome.comparison.changes {
            mark(change.framesA, onPage: change.pageA, of: documentA, geometry: geometries.original, color: change.kind == .appearance ? .systemOrange : .systemRed, outlined: change.kind == .appearance)
            mark(change.framesB, onPage: change.pageB, of: documentB, geometry: geometries.revised, color: change.kind == .appearance ? .systemOrange : .systemGreen, outlined: change.kind == .appearance)
        }
        originalView.document = documentA
        revisedView.document = documentB
        comparison = outcome.comparison
        focusMarks = []
        observeScrolling()
        selection = outcome.comparison.changes.first?.id
    }

    private func pageRect(_ frame: PDFRectangle, page: Int, geometry: [PageGeometry]) -> CGRect? {
        geometry.indices.contains(page) ? geometry[page].pageRect(frame).cgRect : nil
    }

    private func mark(_ frames: [PDFRectangle], onPage index: Int?, of document: PDFDocument, geometry: [PageGeometry], color: NSColor, outlined: Bool) {
        guard let index, let page = document.page(at: index) else { return }
        for frame in frames {
            guard let rect = pageRect(frame, page: index, geometry: geometry) else { continue }
            let annotation = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: outlined ? .square : .highlight, withProperties: nil)
            if outlined {
                let border = PDFBorder()
                border.lineWidth = 1.5
                annotation.border = border
                annotation.color = color
            } else {
                annotation.color = color.withAlphaComponent(0.4)
            }
            page.addAnnotation(annotation)
        }
    }

    // MARK: Moving between changes

    func step(_ offset: Int) {
        guard !changes.isEmpty else { return }
        let current = selection.flatMap { id in changes.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : 0)
        selection = changes[(current + offset + changes.count) % changes.count].id
    }

    /// Frames the selected change on both sides and brings it into view.
    private func showSelection() {
        for mark in focusMarks { mark.page?.removeAnnotation(mark) }
        focusMarks = []
        guard let change = changes.first(where: { $0.id == selection }) else { return }
        isFollowing = true
        defer { DispatchQueue.main.async { [weak self] in self?.isFollowing = false } }
        // A page that only one document has is shown beside where it would be in the other.
        let pair = comparison?.pagePairs
        let pageA = change.pageA ?? partner(of: change.pageB, in: pair, from: \.b, to: \.a)
        let pageB = change.pageB ?? partner(of: change.pageA, in: pair, from: \.a, to: \.b)
        focus(change.framesA, page: pageA, in: originalView, geometry: geometries.original)
        focus(change.framesB.isEmpty && change.pageB != nil ? [] : change.framesB, page: pageB, in: revisedView, geometry: geometries.revised)
    }

    /// The page on the other side that sits nearest a page that has no partner.
    private func partner(of page: Int?, in pairs: [DocumentComparison.PagePair]?, from: KeyPath<DocumentComparison.PagePair, Int?>, to: KeyPath<DocumentComparison.PagePair, Int?>) -> Int? {
        guard let page, let pairs, let position = pairs.firstIndex(where: { $0[keyPath: from] == page }) else { return nil }
        return pairs[..<position].last { $0[keyPath: to] != nil }?[keyPath: to] ?? pairs[position...].first { $0[keyPath: to] != nil }?[keyPath: to]
    }

    private func focus(_ frames: [PDFRectangle], page index: Int?, in view: PDFView, geometry: [PageGeometry]) {
        guard let index, let page = view.document?.page(at: index) else { return }
        let rects = frames.compactMap { pageRect($0, page: index, geometry: geometry) }
        guard let first = rects.first else {
            view.go(to: page)
            return
        }
        let all = rects.dropFirst().reduce(first) { $0.union($1) }
        let ring = PDFAnnotation(bounds: all.insetBy(dx: -4, dy: -4), forType: .square, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = 1.5
        ring.border = border
        ring.color = .controlAccentColor
        page.addAnnotation(ring)
        focusMarks.append(ring)
        view.go(to: all.insetBy(dx: -60, dy: -160), on: page)
    }

    // MARK: Scrolling together

    private func observeScrolling() {
        guard observers.isEmpty else { return }
        for (view, other) in [(originalView, revisedView), (revisedView, originalView)] {
            guard let clipView = view.subviews.compactMap({ $0 as? NSScrollView }).first?.contentView else { continue }
            clipView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self, weak view, weak other] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let other else { return }
                    self.follow(view, with: other)
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view, weak other] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let other, self.syncsScrolling, !self.isFollowing, abs(other.scaleFactor - view.scaleFactor) > 0.001 else { return }
                    self.isFollowing = true
                    other.autoScales = view.autoScales
                    if !view.autoScales { other.scaleFactor = view.scaleFactor }
                    DispatchQueue.main.async { self.isFollowing = false }
                }
            })
        }
    }

    /// Scrolls one view to the place that goes with where the other was just scrolled to.
    private func follow(_ view: PDFView, with other: PDFView) {
        guard syncsScrolling, !isFollowing, let comparison, let destination = view.currentDestination, let page = destination.page,
              let index = view.document?.index(for: page)
        else { return }
        let fromOriginal = view === originalView
        let target = fromOriginal
            ? comparison.pagePairs.first { $0.a == index }?.b ?? partner(of: index, in: comparison.pagePairs, from: \.a, to: \.b)
            : comparison.pagePairs.first { $0.b == index }?.a ?? partner(of: index, in: comparison.pagePairs, from: \.b, to: \.a)
        guard let target, let otherPage = other.document?.page(at: target) else { return }
        isFollowing = true
        other.go(to: PDFDestination(page: otherPage, at: destination.point))
        DispatchQueue.main.async { [weak self] in self?.isFollowing = false }
    }

    // MARK: Report

    /// Saves the list of changes as a PDF.
    func exportReport(from window: NSWindow?) {
        guard let comparison, let original, let revised else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = String(localized: "Comparison Report")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var labels = ReportLabels()
        labels.title = String(localized: "Comparison Report")
        labels.first = String(localized: "Original")
        labels.second = String(localized: "Revised")
        labels.page = String(localized: "page")
        labels.replaced = String(localized: "Changed")
        labels.inserted = String(localized: "Added")
        labels.deleted = String(localized: "Removed")
        labels.pageAdded = String(localized: "Page added")
        labels.pageRemoved = String(localized: "Page removed")
        labels.appearance = String(localized: "Looks different")
        labels.noDifferences = String(localized: "No differences were found.")
        do {
            let paper = Preferences.value(Preferences.newDocumentPaper, default: NewDocumentPaper.system)
            let report = try comparison.report(
                nameA: original.name, nameB: revised.name, pageSize: paper.pageSize,
                date: Date.now.formatted(date: .long, time: .shortened), labels: labels
            )
            try report.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Finds where two pages look different by drawing both small and comparing the drawings.
nonisolated enum PageDifference {
    /// Boxes around the parts that differ, on the page as displayed. Empty when the pages look the same.
    static func frames(_ first: PDFPage, _ second: PDFPage) -> [PDFRectangle] {
        func size(_ page: PDFPage) -> CGSize {
            let bounds = page.bounds(for: .cropBox).size
            return page.rotation % 180 == 0 ? bounds : CGSize(width: bounds.height, height: bounds.width)
        }
        let sizeA = size(first), sizeB = size(second)
        guard sizeA.width > 1, sizeA.height > 1 else { return [] }
        // Pages of different sizes differ everywhere.
        if abs(sizeA.width - sizeB.width) > 2 || abs(sizeA.height - sizeB.height) > 2 {
            return [PDFRectangle(x: 0, y: 0, width: sizeA.width, height: sizeA.height)]
        }
        // Half a pixel per point is enough to see that something moved, and quick.
        let scale = 0.5
        let width = max(Int(sizeA.width * scale), 1), height = max(Int(sizeA.height * scale), 1)
        func draw(_ page: PDFPage) -> [UInt8]? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
        }
        guard let a = draw(first), let b = draw(second) else { return [] }

        // Cells of a coarse grid that hold a pixel that differs clearly.
        let cell = 8
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var differs = [Bool](repeating: false, count: columns * rows)
        var count = 0
        for y in 0..<height {
            for x in 0..<width where abs(Int(a[y * width + x]) - Int(b[y * width + x])) > 48 {
                let index = (y / cell) * columns + x / cell
                if !differs[index] {
                    differs[index] = true
                    count += 1
                }
            }
        }
        guard count > 0 else { return [] }

        // Cells that touch are one difference.
        var frames: [PDFRectangle] = []
        var seen = [Bool](repeating: false, count: differs.count)
        for start in differs.indices where differs[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minColumn = start % columns, maxColumn = minColumn, minRow = start / columns, maxRow = minRow
            while let index = stack.popLast() {
                let column = index % columns, row = index / columns
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nextColumn = column + dx, nextRow = row + dy
                        guard nextColumn >= 0, nextColumn < columns, nextRow >= 0, nextRow < rows else { continue }
                        let next = nextRow * columns + nextColumn
                        if differs[next], !seen[next] {
                            seen[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            // The bitmap's first row is the top of the page; frames count from the bottom.
            let left = Double(minColumn * cell) / scale, right = min(Double((maxColumn + 1) * cell) / scale, sizeA.width)
            let top = sizeA.height - Double(minRow * cell) / scale, bottom = max(sizeA.height - Double((maxRow + 1) * cell) / scale, 0)
            frames.append(PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom))
        }
        // Many small pieces say less than one box around them.
        if frames.count > 12 {
            let left = frames.map(\.x).min() ?? 0, bottom = frames.map(\.y).min() ?? 0
            let right = frames.map { $0.x + $0.width }.max() ?? 0, top = frames.map { $0.y + $0.height }.max() ?? 0
            return [PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom)]
        }
        return frames
    }
}
