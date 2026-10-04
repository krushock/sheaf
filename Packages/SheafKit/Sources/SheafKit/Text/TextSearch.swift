import Foundation

/// How text is looked for.
public struct TextSearchOptions: Sendable, Equatable {
    public var isCaseSensitive = false
    public var matchesWholeWords = false
    /// Reads the query as a regular expression.
    public var isRegularExpression = false

    public init(isCaseSensitive: Bool = false, matchesWholeWords: Bool = false, isRegularExpression: Bool = false) {
        self.isCaseSensitive = isCaseSensitive
        self.matchesWholeWords = matchesWholeWords
        self.isRegularExpression = isRegularExpression
    }
}

/// One place where text was found.
public struct TextMatch: Sendable, Equatable {
    public var pageIndex: Int
    public var blockID: Int
    /// Which part of the block's `flowingText` matched, counted in Unicode scalars.
    public var range: Range<Int>
    public var text: String
    /// The match's boxes on the page as displayed, one per line it is on.
    public var frames: [PDFRectangle]
    /// Whether the match is in text that can be changed.
    public var isReplaceable: Bool
}

extension PDFEditor {
    /// Finds text on a page. A match may run from the end of one line onto the next.
    public func findText(_ query: String, onPageAt index: Int, options: TextSearchOptions = TextSearchOptions()) throws -> [TextMatch] {
        guard !query.isEmpty else { return [] }
        return Self.matches(of: query, in: try pageContent(at: index), pageIndex: index, options: options)
    }

    static func matches(of query: String, in content: PageContent, pageIndex: Int, options: TextSearchOptions) -> [TextMatch] {
        var pattern = options.isRegularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        if options.matchesWholeWords { pattern = "(?<![\\p{L}\\p{N}])(?:" + pattern + ")(?![\\p{L}\\p{N}])" }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options.isCaseSensitive ? [] : [.caseInsensitive]) else { return [] }

        var result: [TextMatch] = []
        for block in content.blocks {
            let flow = block.flow
            let text = flow.map(\.text).joined()
            // Where each item starts, counted in scalars: a glyph may be only a part of a character.
            var starts: [Int] = []
            var offset = 0
            for item in flow {
                starts.append(offset)
                offset += item.text.unicodeScalars.count
            }
            let scalars = text.unicodeScalars
            for found in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let swiftRange = Range(found.range, in: text), !swiftRange.isEmpty else { continue }
                let lower = scalars.distance(from: scalars.startIndex, to: swiftRange.lowerBound)
                let upper = scalars.distance(from: scalars.startIndex, to: swiftRange.upperBound)
                // A box per line, around the items the match covers.
                var boxes: [Int: PDFRectangle] = [:]
                for (position, item) in flow.enumerated() where !item.isBreak {
                    let start = starts[position], end = start + item.text.unicodeScalars.count
                    guard start < upper, end > lower else { continue }
                    let frame = item.style.frame
                    guard frame.width > 0 else { continue }
                    if let existing = boxes[item.line] {
                        let left = min(existing.x, frame.x), right = max(existing.x + existing.width, frame.x + frame.width)
                        let bottom = min(existing.y, frame.y), top = max(existing.y + existing.height, frame.y + frame.height)
                        boxes[item.line] = PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom)
                    } else {
                        boxes[item.line] = frame
                    }
                }
                result.append(TextMatch(
                    pageIndex: pageIndex, blockID: block.id, range: lower..<upper, text: String(text[swiftRange]),
                    frames: boxes.sorted { $0.key < $1.key }.map(\.value), isReplaceable: block.isEditable
                ))
            }
        }
        return result
    }

    /// Replaces matches on one page. The matches must come from the page as it is now.
    ///
    /// - Returns: How many were replaced. Matches in text that cannot be changed are skipped.
    @discardableResult
    public mutating func replace(_ matches: [TextMatch], onPageAt index: Int, with replacement: String) throws -> Int {
        let content = try pageContent(at: index)
        // The new text of each block, worked out before anything changes.
        var plans: [(id: Int, new: String, count: Int)] = []
        for (blockID, group) in Dictionary(grouping: matches.filter { $0.pageIndex == index && $0.isReplaceable }, by: \.blockID) {
            guard let block = content.blocks.first(where: { $0.id == blockID }), block.isEditable else { continue }
            var scalars = Array(block.flowingText.unicodeScalars)
            var count = 0
            for match in group.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                guard match.range.upperBound <= scalars.count, scalars[match.range].elementsEqual(match.text.unicodeScalars) else { continue }
                scalars.replaceSubrange(match.range, with: Array(replacement.unicodeScalars))
                count += 1
            }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            if count > 0 { plans.append((block.id, String(view), count)) }
        }
        guard !plans.isEmpty else { return 0 }
        // All of the page's blocks in one pass, so the page is read and written once.
        try replaceText(inBlocks: plans.map { ($0.id, $0.new) }, onPageAt: index)
        return plans.reduce(0) { $0 + $1.count }
    }

    /// Replaces every match in the document, or on some of its pages.
    ///
    /// - Returns: How many were replaced, and which pages changed.
    @discardableResult
    public mutating func replaceAll(
        _ query: String, with replacement: String, options: TextSearchOptions = TextSearchOptions(), onPagesAt indexes: [Int]? = nil
    ) throws -> (count: Int, pages: [Int]) {
        var total = 0
        var pages: [Int] = []
        let count = try pageCount()
        for index in indexes ?? Array(0..<count) {
            let matches = try findText(query, onPageAt: index, options: options)
            guard !matches.isEmpty else { continue }
            let replaced = try replace(matches, onPageAt: index, with: replacement)
            if replaced > 0 {
                total += replaced
                pages.append(index)
            }
        }
        return (total, pages)
    }
}
