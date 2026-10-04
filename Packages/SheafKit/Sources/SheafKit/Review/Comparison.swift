import Foundation

/// One difference between two documents.
public struct DocumentChange: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// Words the second document has and the first does not.
        case inserted
        /// Words the first document has and the second does not.
        case deleted
        /// Words that were changed into others.
        case replaced
        /// A page only the second document has.
        case pageAdded
        /// A page only the first document has.
        case pageRemoved
        /// The page looks different though its words are the same: a picture, a drawing, a layout.
        case appearance
    }

    public var id: Int
    public var kind: Kind
    /// The page in the first document, and in the second.
    public var pageA: Int?
    public var pageB: Int?
    /// Where the change is on each page as displayed, a box for each line it touches.
    public var framesA: [PDFRectangle]
    public var framesB: [PDFRectangle]
    public var textA: String
    public var textB: String

    public init(id: Int, kind: Kind, pageA: Int?, pageB: Int?, framesA: [PDFRectangle] = [], framesB: [PDFRectangle] = [], textA: String = "", textB: String = "") {
        self.id = id
        self.kind = kind
        self.pageA = pageA
        self.pageB = pageB
        self.framesA = framesA
        self.framesB = framesB
        self.textA = textA
        self.textB = textB
    }
}

/// How two documents differ.
public struct DocumentComparison: Sendable, Equatable {
    /// Which page of the first document goes with which page of the second. A page that
    /// has no partner stands alone, with `nil` on the other side.
    public var pagePairs: [PagePair]
    public var changes: [DocumentChange]

    public struct PagePair: Sendable, Equatable {
        public var a: Int?
        public var b: Int?
    }

    public init(pagePairs: [PagePair], changes: [DocumentChange]) {
        self.pagePairs = pagePairs
        self.changes = changes
    }
}

/// Finds the differences between two documents by their words.
public enum DocumentComparer {
    struct Word {
        var text: String
        var frame: PDFRectangle
    }

    /// The words of a page in reading order, with where they are.
    static func words(of content: PageContent) -> [Word] {
        var result: [Word] = []
        for block in content.blocks {
            for line in block.lines {
                var text = ""
                var left = 0.0, right = 0.0
                func flush() {
                    if !text.isEmpty { result.append(Word(text: text, frame: PDFRectangle(x: left, y: line.frame.y, width: max(right - left, 0.1), height: line.frame.height))) }
                    text = ""
                }
                for glyph in line.glyphs {
                    if glyph.text == " " {
                        flush()
                    } else {
                        if text.isEmpty { left = glyph.origin.x }
                        right = glyph.origin.x + glyph.advance
                        text += glyph.text
                    }
                }
                flush()
            }
        }
        return result
    }

    enum Step { case same(Int, Int), removed(Int), added(Int) }

    /// The shortest list of removals and additions that turns one list into another.
    ///
    /// - Returns: `nil` when the lists differ so much that listing how is no use.
    static func difference<Element: Equatable>(_ a: [Element], _ b: [Element], limit: Int = 3000) -> [Step]? {
        // What the two share at the start and the end needs no work.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        var middle: [Step] = []
        if n == 0 {
            middle = (0..<m).map { .added(prefix + $0) }
        } else if m == 0 {
            middle = (0..<n).map { .removed(prefix + $0) }
        } else {
            // Myers' algorithm: the furthest reach along each diagonal for a growing number of edits.
            let offset = n + m
            var reach = [Int](repeating: 0, count: 2 * offset + 2)
            var history: [[Int]] = []
            var found = false
            outer: for edits in 0...min(n + m, limit) {
                history.append(reach)
                for diagonal in stride(from: -edits, through: edits, by: 2) {
                    var x: Int
                    if diagonal == -edits || (diagonal != edits && reach[offset + diagonal - 1] < reach[offset + diagonal + 1]) {
                        x = reach[offset + diagonal + 1]
                    } else {
                        x = reach[offset + diagonal - 1] + 1
                    }
                    var y = x - diagonal
                    while x < n, y < m, a[prefix + x] == b[prefix + y] {
                        x += 1
                        y += 1
                    }
                    reach[offset + diagonal] = x
                    if x >= n, y >= m {
                        found = true
                        break outer
                    }
                }
            }
            guard found else { return nil }
            // Walk back from the end to the start.
            var x = n, y = m
            var reversed: [Step] = []
            for edits in stride(from: history.count - 1, through: 0, by: -1) {
                let reach = history[edits]
                let diagonal = x - y
                let previousDiagonal: Int
                if diagonal == -edits || (diagonal != edits && reach[offset + diagonal - 1] < reach[offset + diagonal + 1]) {
                    previousDiagonal = diagonal + 1
                } else {
                    previousDiagonal = diagonal - 1
                }
                let previousX = reach[offset + previousDiagonal]
                let previousY = previousX - previousDiagonal
                while x > previousX, y > previousY, x > 0, y > 0 {
                    x -= 1
                    y -= 1
                    reversed.append(.same(prefix + x, prefix + y))
                }
                if edits > 0 {
                    if x == previousX {
                        y -= 1
                        reversed.append(.added(prefix + y))
                    } else {
                        x -= 1
                        reversed.append(.removed(prefix + x))
                    }
                }
            }
            middle = reversed.reversed()
        }
        return (0..<prefix).map { .same($0, $0) } + middle + (0..<suffix).map { .same(a.count - suffix + $0, b.count - suffix + $0) }
    }

    /// A box for each line a run of words is on.
    static func lineFrames(_ words: [Word]) -> [PDFRectangle] {
        var result: [PDFRectangle] = []
        for word in words {
            if let last = result.last, abs(last.y - word.frame.y) < 1, word.frame.x >= last.x - 1 {
                let right = max(last.x + last.width, word.frame.x + word.frame.width)
                result[result.count - 1] = PDFRectangle(x: last.x, y: last.y, width: right - last.x, height: max(last.height, word.frame.height))
            } else {
                result.append(word.frame)
            }
        }
        return result
    }

    /// Compares two documents page by page and word by word.
    ///
    /// Pages are first matched up, so that a page added or removed in the middle does
    /// not make every page after it look different.
    ///
    /// - Parameter progress: Called with the fraction done. Return `false` to stop.
    public static func compare(_ first: PDFEditor, _ second: PDFEditor, progress: ((Double) -> Bool)? = nil) throws -> DocumentComparison {
        let countA = try first.pageCount(), countB = try second.pageCount()
        let total = Double(max(countA + countB, 1))
        var pagesA: [[Word]] = [], pagesB: [[Word]] = []
        for index in 0..<countA {
            if let progress, !progress(Double(index) / total * 0.8) { throw CancellationError() }
            pagesA.append((try? words(of: first.pageContent(at: index))) ?? [])
        }
        for index in 0..<countB {
            if let progress, !progress(Double(countA + index) / total * 0.8) { throw CancellationError() }
            pagesB.append((try? words(of: second.pageContent(at: index))) ?? [])
        }

        // Pages that say exactly the same are the fixed points.
        let textsA = pagesA.map { $0.map(\.text).joined(separator: " ") }, textsB = pagesB.map { $0.map(\.text).joined(separator: " ") }
        var pairs: [DocumentComparison.PagePair] = []
        let setsA = pagesA.map { Set($0.map(\.text)) }, setsB = pagesB.map { Set($0.map(\.text)) }
        func likeness(_ a: Int, _ b: Int) -> Double {
            if setsA[a].isEmpty, setsB[b].isEmpty { return 1 }
            let shared = setsA[a].intersection(setsB[b]).count
            return Double(shared) / Double(max(setsA[a].union(setsB[b]).count, 1))
        }
        /// Pairs up the pages between two fixed points: in order, each with the page most like it.
        func pairGap(_ rangeA: Range<Int>, _ rangeB: Range<Int>) {
            var a = rangeA.lowerBound, b = rangeB.lowerBound
            while a < rangeA.upperBound, b < rangeB.upperBound {
                let window = 12
                if likeness(a, b) >= 0.3 {
                    pairs.append(.init(a: a, b: b))
                    a += 1
                    b += 1
                    continue
                }
                // Not alike: see whether skipping pages on one side finds a partner soon.
                let aheadB = (b + 1..<min(b + window, rangeB.upperBound)).first { likeness(a, $0) >= 0.5 }
                let aheadA = (a + 1..<min(a + window, rangeA.upperBound)).first { likeness($0, b) >= 0.5 }
                if let aheadB, aheadA == nil || aheadB - b <= (aheadA ?? .max) - a {
                    while b < aheadB {
                        pairs.append(.init(a: nil, b: b))
                        b += 1
                    }
                } else if let aheadA {
                    while a < aheadA {
                        pairs.append(.init(a: a, b: nil))
                        a += 1
                    }
                } else {
                    // Nothing alike nearby: the page was rewritten in place.
                    pairs.append(.init(a: a, b: b))
                    a += 1
                    b += 1
                }
            }
            while a < rangeA.upperBound {
                pairs.append(.init(a: a, b: nil))
                a += 1
            }
            while b < rangeB.upperBound {
                pairs.append(.init(a: nil, b: b))
                b += 1
            }
        }
        var lastA = 0, lastB = 0
        // Empty pages are not landmarks: there may be many, all the same.
        let steps = difference(textsA.enumerated().map { $1.isEmpty ? "\u{0}a\($0)" : $1 }, textsB.enumerated().map { $1.isEmpty ? "\u{0}b\($0)" : $1 }) ?? []
        for step in steps {
            if case .same(let a, let b) = step {
                pairGap(lastA..<a, lastB..<b)
                pairs.append(.init(a: a, b: b))
                lastA = a + 1
                lastB = b + 1
            }
        }
        pairGap(lastA..<countA, lastB..<countB)

        var changes: [DocumentChange] = []
        for (number, pair) in pairs.enumerated() {
            if let progress, !progress(0.8 + Double(number) / Double(max(pairs.count, 1)) * 0.2) { throw CancellationError() }
            guard let a = pair.a, let b = pair.b else {
                let words = pair.a.map { pagesA[$0] } ?? pair.b.map { pagesB[$0] } ?? []
                let text = words.prefix(40).map(\.text).joined(separator: " ")
                changes.append(DocumentChange(
                    id: changes.count, kind: pair.a == nil ? .pageAdded : .pageRemoved, pageA: pair.a, pageB: pair.b,
                    textA: pair.a == nil ? "" : text, textB: pair.b == nil ? "" : text
                ))
                continue
            }
            guard textsA[a] != textsB[b] else { continue }
            let wordsA = pagesA[a], wordsB = pagesB[b]
            guard let steps = difference(wordsA.map(\.text), wordsB.map(\.text)) else {
                // Too different to list word by word.
                changes.append(DocumentChange(
                    id: changes.count, kind: .replaced, pageA: a, pageB: b, framesA: lineFrames(wordsA), framesB: lineFrames(wordsB),
                    textA: wordsA.prefix(40).map(\.text).joined(separator: " "), textB: wordsB.prefix(40).map(\.text).joined(separator: " ")
                ))
                continue
            }
            var removed: [Word] = [], added: [Word] = []
            func flush() {
                guard !removed.isEmpty || !added.isEmpty else { return }
                changes.append(DocumentChange(
                    id: changes.count, kind: removed.isEmpty ? .inserted : added.isEmpty ? .deleted : .replaced, pageA: a, pageB: b,
                    framesA: lineFrames(removed), framesB: lineFrames(added),
                    textA: removed.map(\.text).joined(separator: " "), textB: added.map(\.text).joined(separator: " ")
                ))
                removed = []
                added = []
            }
            for step in steps {
                switch step {
                case .same: flush()
                case .removed(let index): removed.append(wordsA[index])
                case .added(let index): added.append(wordsB[index])
                }
            }
            flush()
        }
        if let progress, !progress(1) { throw CancellationError() }
        return DocumentComparison(pagePairs: pairs, changes: changes)
    }
}

extension DocumentComparison {
    /// The comparison written up as a PDF: what was compared, how much changed, and
    /// every change with its page.
    ///
    /// - Parameters:
    ///   - labels: The words the report uses, so the caller can supply them in the reader's language.
    public func report(nameA: String, nameB: String, pageSize: PageSize, date: String, labels: ReportLabels = ReportLabels()) throws -> Data {
        var writer = try ReportWriter(pageSize: pageSize)
        try writer.add(labels.title, fontName: "Helvetica-Bold", size: 20)
        try writer.add(date, size: 10, color: PDFColor(red: 0.45, green: 0.45, blue: 0.45), spaceBefore: 4)
        try writer.add("\(labels.first): \(nameA)", size: 11, spaceBefore: 14)
        try writer.add("\(labels.second): \(nameB)", size: 11, spaceBefore: 2)

        let counts = Dictionary(grouping: changes, by: \.kind).mapValues(\.count)
        var summary: [String] = []
        for (kind, label) in [(DocumentChange.Kind.replaced, labels.replaced), (.inserted, labels.inserted), (.deleted, labels.deleted), (.pageAdded, labels.pageAdded), (.pageRemoved, labels.pageRemoved), (.appearance, labels.appearance)] {
            if let count = counts[kind] { summary.append("\(label): \(count)") }
        }
        try writer.add(summary.isEmpty ? labels.noDifferences : summary.joined(separator: "   "), fontName: "Helvetica-Bold", size: 11, spaceBefore: 14)

        func clipped(_ text: String) -> String { text.count > 320 ? String(text.prefix(320)) + "…" : text }
        for change in changes {
            let page = [change.pageA.map { "\(labels.first) \(labels.page) \($0 + 1)" }, change.pageB.map { "\(labels.second) \(labels.page) \($0 + 1)" }].compactMap(\.self).joined(separator: " · ")
            let label = switch change.kind {
            case .replaced: labels.replaced
            case .inserted: labels.inserted
            case .deleted: labels.deleted
            case .pageAdded: labels.pageAdded
            case .pageRemoved: labels.pageRemoved
            case .appearance: labels.appearance
            }
            try writer.add("\(label) — \(page)", fontName: "Helvetica-Bold", size: 10, spaceBefore: 12)
            if !change.textA.isEmpty { try writer.add("− " + clipped(change.textA), size: 10, color: PDFColor(red: 0.72, green: 0.11, blue: 0.11), spaceBefore: 2) }
            if !change.textB.isEmpty { try writer.add("+ " + clipped(change.textB), size: 10, color: PDFColor(red: 0.05, green: 0.47, blue: 0.2), spaceBefore: 2) }
        }
        return try writer.data()
    }
}

/// The words a comparison report is written with.
public struct ReportLabels: Sendable {
    public var title = "Comparison Report"
    public var first = "Original"
    public var second = "Revised"
    public var page = "page"
    public var replaced = "Changed"
    public var inserted = "Added"
    public var deleted = "Removed"
    public var pageAdded = "Page added"
    public var pageRemoved = "Page removed"
    public var appearance = "Looks different"
    public var noDifferences = "No differences were found."

    public init() {}
}

/// Writes paragraphs down pages, starting a new page when one is full.
struct ReportWriter {
    private var editor: PDFEditor
    private let pageSize: PageSize
    private let margin = 54.0
    private var pageIndex = 0
    private var y: Double

    init(pageSize: PageSize) throws {
        self.pageSize = pageSize
        editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: pageSize.width, height: pageSize.height)])))
        y = pageSize.height - margin
    }

    mutating func add(_ text: String, fontName: String = "Helvetica", size: Double = 11, color: PDFColor = .black, spaceBefore: Double = 0) throws {
        guard !text.isEmpty else { return }
        let width = pageSize.width - 2 * margin
        let metrics = FontMatcher.verticalMetrics(fontName: fontName)
        let leading = max((metrics.ascent + metrics.descent) / 1000 * size * 1.15, size)
        let lineCount = text.components(separatedBy: .newlines).reduce(0) {
            $0 + max(TextOutliner.shape($1, fontName: fontName, fontSize: size, width: width, alignment: .left).count, 1)
        }
        let height = Double(lineCount) * leading
        if y - spaceBefore - height < margin, y < pageSize.height - margin {
            _ = try editor.insertBlankPage(size: pageSize, at: pageIndex + 1)
            pageIndex += 1
            y = pageSize.height - margin
        } else {
            y -= spaceBefore
        }
        try editor.addText(text, toPageAt: pageIndex, at: PDFPoint(x: margin, y: y), width: width, fontName: fontName, fontSize: size, color: color)
        y -= height
    }

    func data() throws -> Data { try editor.rewritten() }
}
