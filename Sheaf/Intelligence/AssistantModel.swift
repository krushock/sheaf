import AppKit
import PDFKit
import SheafKit
import SwiftUI

/// What the Summary panel shows.
enum AssistantTab: String, CaseIterable, Identifiable {
    case summary, keyPoints, ask

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .keyPoints: "Key Points"
        case .ask: "Ask"
        }
    }

    var kind: SummaryKind? {
        switch self {
        case .summary: .summary
        case .keyPoints: .keyPoints
        case .ask: nil
        }
    }
}

extension ReadingEngine {
    var title: LocalizedStringKey {
        switch self {
        case .device: "On This Mac"
        case .cloud: "Private Cloud Compute"
        }
    }
}

/// How much of a document is summed up.
enum ReadingScope: String, CaseIterable, Identifiable {
    case document, page, selection

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .document: "Whole Document"
        case .page: "This Page"
        case .selection: "Selected Text"
        }
    }
}

/// The Summary panel of one document: what Apple Intelligence has made of it so far.
///
/// Nothing here changes the document. A summary can be copied or put on a page as a
/// note, which is an ordinary change the person makes.
@Observable
final class AssistantModel {
    struct Summary: Equatable {
        var text = ""
        /// What it sums up: "Whole document", "Page 3", "Selected text".
        var subject = ""
        /// What is going on while nothing is written yet: "Reading part 2 of 7…".
        var progress: String?
        var isRunning = false
        var failure: String?
        /// The model that made it, once it is made.
        var engine: ReadingEngine?
        /// Why it was made on this Mac although Private Cloud Compute was chosen, if so.
        var note: String?
    }

    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer = ""
        /// The pages the answer comes from, counted from zero.
        var pageIndexes: [Int] = []
        var isRunning = true
        var failure: String?
        /// Why it was answered on this Mac although Private Cloud Compute was chosen, if so.
        var note: String?
    }

    var tab = AssistantTab.summary
    var scope = ReadingScope.document
    var question = ""
    private(set) var summaries: [SummaryKind: Summary] = [:]
    private(set) var exchanges: [Exchange] = []

    @ObservationIgnored private var summaryTasks: [SummaryKind: Task<Void, Never>] = [:]
    /// Counts the summaries started of each kind, so that one that was replaced or
    /// stopped cannot write over the one that came after it.
    @ObservationIgnored private var summaryRuns: [SummaryKind: Int] = [:]
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    /// The document's text and the index made of it, for as long as the document stays as it is.
    @ObservationIgnored private var read: (revision: Int, pages: [PageText], index: DocumentReader.Index?)?

    var isAnswering: Bool { exchanges.last?.isRunning == true }

    // MARK: Summaries

    /// Sums up the document, the page being read, or the selected text.
    func summarize(_ kind: SummaryKind, in viewer: ViewerModel) {
        summaryTasks[kind]?.cancel()
        let scope = scope == .selection && !viewer.hasTextSelection ? .page : scope
        let subject: String
        let selected: PageText?
        switch scope {
        case .document:
            subject = String(localized: "Whole document")
            selected = nil
        case .page:
            subject = String(localized: "Page \(viewer.currentPageIndex + 1)")
            selected = PageText(pageIndex: viewer.currentPageIndex, text: viewer.document?.page(at: viewer.currentPageIndex)?.string ?? "")
        case .selection:
            subject = String(localized: "Selected text")
            let selection = viewer.pdfView.currentSelection
            let pageIndex = selection?.pages.first.flatMap { viewer.document?.index(for: $0) } ?? viewer.currentPageIndex
            selected = PageText(pageIndex: pageIndex, text: selection?.string ?? "")
        }
        summaries[kind] = Summary(subject: subject, progress: String(localized: "Reading…"), isRunning: true)
        let engine = Preferences.readingEngineValue
        let run = (summaryRuns[kind] ?? 0) + 1
        summaryRuns[kind] = run
        summaryTasks[kind] = Task { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            let pages: [PageText]
            if let selected {
                pages = [selected]
            } else {
                pages = await self.pages(of: viewer)
            }
            do {
                let reading = try await DocumentReader.summarize(pages, as: kind, using: engine) { [weak self] step in
                    Task { @MainActor in self?.show(step, for: kind, run: run) }
                }
                try Task.checkCancellation()
                guard self.summaryRuns[kind] == run else { return }
                self.summaries[kind]?.text = reading.text
                self.summaries[kind]?.engine = reading.engine
                self.summaries[kind]?.note = reading.note
                self.summaries[kind]?.progress = nil
                self.summaries[kind]?.isRunning = false
            } catch {
                guard self.summaryRuns[kind] == run, self.summaries[kind]?.isRunning == true else { return }
                self.summaries[kind]?.isRunning = false
                self.summaries[kind]?.progress = nil
                if !(error is CancellationError), !Task.isCancelled {
                    self.summaries[kind]?.failure = error.localizedDescription
                }
            }
        }
    }

    private func show(_ step: ReadingStep, for kind: SummaryKind, run: Int) {
        guard summaryRuns[kind] == run, summaries[kind]?.isRunning == true else { return }
        switch step {
        case .reading(let part, let count):
            summaries[kind]?.progress = String(localized: "Reading part \(part) of \(count)…")
        case .writing(let text):
            summaries[kind]?.progress = text.isEmpty ? String(localized: "Writing…") : nil
            // What is being written is shown the way the finished text will be.
            if !text.isEmpty { summaries[kind]?.text = DocumentReader.tidied(text, as: kind) }
        }
    }

    /// Stops a summary that is being made. What is written so far stays.
    func stop(_ kind: SummaryKind) {
        summaryTasks[kind]?.cancel()
        summaryTasks[kind] = nil
        summaryRuns[kind, default: 0] += 1
        summaries[kind]?.isRunning = false
        summaries[kind]?.progress = nil
        if summaries[kind]?.text.isEmpty == true { summaries[kind] = nil }
    }

    // MARK: Questions

    /// Answers the question in the field from the document.
    func ask(in viewer: ViewerModel) {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isAnswering else { return }
        question = ""
        let earlier = exchanges.filter { $0.failure == nil && !$0.answer.isEmpty }.suffix(2).map { (question: $0.question, answer: $0.answer) }
        let exchange = Exchange(question: asked)
        exchanges.append(exchange)
        let engine = Preferences.readingEngineValue
        answerTask = Task { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            let index = await self.index(of: viewer)
            do {
                let answer = try await DocumentReader.answer(asked, from: index, earlier: earlier, using: engine) { [weak self] text in
                    Task { @MainActor in self?.update(exchange.id) { if $0.isRunning { $0.answer = text } } }
                }
                try Task.checkCancellation()
                self.update(exchange.id) {
                    $0.answer = answer.text
                    $0.pageIndexes = answer.pageIndexes
                    $0.note = answer.note
                    $0.isRunning = false
                }
            } catch {
                self.update(exchange.id) {
                    $0.isRunning = false
                    if !(error is CancellationError), !Task.isCancelled { $0.failure = error.localizedDescription }
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    /// Stops the answer being written.
    func stopAnswering() {
        answerTask?.cancel()
        answerTask = nil
        if let last = exchanges.indices.last, exchanges[last].isRunning {
            exchanges[last].isRunning = false
            if exchanges[last].answer.isEmpty { exchanges.removeLast() }
        }
    }

    func clearConversation() {
        stopAnswering()
        exchanges = []
    }

    // MARK: The document's text

    /// The text of every page. It is read a few pages at a time, so that a long document
    /// does not hold up the window, and kept until the document changes.
    func pages(of viewer: ViewerModel) async -> [PageText] {
        let revision = viewer.sheafDocument?.revision ?? 0
        if let read, read.revision == revision { return read.pages }
        guard let document = viewer.document else { return [] }
        var pages: [PageText] = []
        for index in 0..<document.pageCount {
            if index % 6 == 5 { await Task.yield() }
            pages.append(PageText(pageIndex: index, text: document.page(at: index)?.string ?? ""))
        }
        read = (revision, pages, nil)
        return pages
    }

    private func index(of viewer: ViewerModel) async -> DocumentReader.Index {
        let pages = await pages(of: viewer)
        if let index = read?.index { return index }
        let index = await DocumentReader.index(of: pages)
        if read?.pages == pages { read?.index = index }
        return index
    }
}

extension ViewerModel {
    /// Opens the Summary panel and sums the document up, unless that is done already.
    func summarizeDocument() {
        isAssistantVisible = true
        if assistant.tab == .ask { assistant.tab = .summary }
        guard let kind = assistant.tab.kind, assistant.summaries[kind] == nil, DocumentReader.isAvailable else { return }
        assistant.summarize(kind, in: self)
    }

    /// What Apple Intelligence wrote, as a note on the page being read. The note says
    /// where its text came from, and is signed "Apple Intelligence" rather than with the
    /// person's name, so nobody who opens the PDF takes it for theirs.
    func addNote(with text: String, heading: String) {
        guard sheafDocument?.isEditable == true, let page = pdfView.currentPage, let document else { return }
        let bounds = page.bounds(for: .cropBox)
        let size = Annotation.noteSize
        var note = Annotation(kind: .note, rect: PDFRectangle(x: bounds.minX + 18, y: bounds.maxY - 18 - size, width: size, height: size))
        note.color = style(for: .note).color
        note.contents = heading + "\n\n" + text
        let pageIndex = document.index(for: page)
        guard let id = add(note, pageIndex: pageIndex, name: String(localized: "Add Note"), author: "Apple Intelligence") else { return }
        selection = AnnotationSelection(pageIndex: pageIndex, id: id)
    }
}
