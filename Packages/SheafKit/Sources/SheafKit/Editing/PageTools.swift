import Foundation

// MARK: - Page ranges

/// Page selections as people type them: `1-3, 5, 8-`.
public enum PageRanges {
    /// Turns text into page indexes, counted from zero, in the order written.
    ///
    /// Accepts single pages, ranges with a hyphen or dash, open ranges such as `8-` and `-3`,
    /// and ranges that run backwards. Throws when the text names a page the document does
    /// not have or cannot be read.
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        var result: [Int] = []
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace || $0 == "\u{3001}" })
        for part in parts {
            let pieces = part.split(omittingEmptySubsequences: false, whereSeparator: { "-–—".contains($0) })
            func number(_ piece: Substring, default fallback: Int) throws -> Int {
                if piece.isEmpty { return fallback }
                guard let value = Int(piece), value >= 1, value <= pageCount else {
                    throw SheafError.unsupported("the page range “\(part)”")
                }
                return value
            }
            switch pieces.count {
            case 1:
                result.append(try number(pieces[0], default: 0) - 1)
            case 2 where !(pieces[0].isEmpty && pieces[1].isEmpty):
                let first = try number(pieces[0], default: 1), last = try number(pieces[1], default: pageCount)
                result.append(contentsOf: (first <= last ? Array(first...last) : Array((last...first).reversed())).map { $0 - 1 })
            default:
                throw SheafError.unsupported("the page range “\(part)”")
            }
        }
        guard !result.isEmpty, result.allSatisfy({ $0 >= 0 }) else { throw SheafError.unsupported("an empty page range") }
        return result
    }

    /// Writes page indexes the short way: `1–3, 5`.
    public static func description(of indexes: [Int]) -> String {
        var parts: [String] = []
        var start = 0
        while start < indexes.count {
            var end = start
            while end + 1 < indexes.count, indexes[end + 1] == indexes[end] + 1 { end += 1 }
            parts.append(end == start ? "\(indexes[start] + 1)" : "\(indexes[start] + 1)–\(indexes[end] + 1)")
            start = end + 1
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Splitting

/// One of the documents a split produces.
public struct SplitPart: Sendable, Equatable {
    /// A name for the part, when the split gives it one, such as a bookmark's title.
    public var title: String?
    public var pageIndexes: [Int]

    public init(title: String? = nil, pageIndexes: [Int]) {
        self.title = title
        self.pageIndexes = pageIndexes
    }
}

public enum SplitPlan {
    /// Parts of `size` pages each; the last one takes what is left.
    public static func every(_ size: Int, pageCount: Int) -> [SplitPart] {
        guard size > 0, pageCount > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: size).map { SplitPart(pageIndexes: Array($0..<min($0 + size, pageCount))) }
    }

    /// One part per top-level bookmark, each running up to the page before the next
    /// bookmark. Pages ahead of the first bookmark form a part of their own.
    public static func byBookmarks(_ outline: [OutlineItem], pageCount: Int) -> [SplitPart] {
        var starts: [(page: Int, title: String)] = []
        for item in outline {
            guard let page = item.pageIndex, page >= 0, page < pageCount else { continue }
            // Several bookmarks on one page make one part, named after the first.
            if let last = starts.last, page <= last.page { continue }
            starts.append((page, item.title))
        }
        guard !starts.isEmpty else { return [] }
        var parts: [SplitPart] = []
        if starts[0].page > 0 { parts.append(SplitPart(pageIndexes: Array(0..<starts[0].page))) }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].page : pageCount
            parts.append(SplitPart(title: start.title, pageIndexes: Array(start.page..<end)))
        }
        return parts
    }
}

extension PDFEditor {
    /// A new document made of some of this one's pages, in the order given.
    ///
    /// Each page brings what it needs: content, fonts, images, annotations. Bookmarks that
    /// lead to the chosen pages come along, as does the title and other document
    /// information. Links to pages left behind are dropped, and form fields keep their
    /// look but are no longer connected to a form.
    public func extractingPages(_ indexes: [Int], protection: Protection = .none) throws -> Data {
        guard !indexes.isEmpty else { throw SheafError.unsupported("a document with no pages") }
        var target = PDFEditor.empty(version: base.version)
        try target.insertPages(from: self, pageIndexes: indexes)

        var mapping: [Int: Int] = [:]
        for (new, old) in indexes.enumerated() where mapping[old] == nil { mapping[old] = new }
        if let outline = try? outline() {
            let kept = Self.remapped(outline, mapping)
            if !kept.isEmpty { try target.setOutline(kept) }
        }
        if let info = try? info(), info != DocumentInfo() { try target.setInfo(info) }
        return try target.rewritten(protection: protection)
    }

    /// Bookmarks carried to another document: those whose page went along, with their new
    /// page numbers. A bookmark that only groups others is kept while it still has any.
    static func remapped(_ items: [OutlineItem], _ mapping: [Int: Int]) -> [OutlineItem] {
        items.compactMap { item in
            var copy = item
            copy.children = remapped(item.children, mapping)
            // What was stored points at the old document's objects.
            copy.stored["Dest"] = nil
            copy.stored["A"] = nil
            copy.storedPageIndex = nil
            copy.pageIndex = item.pageIndex.flatMap { mapping[$0] }
            return copy.pageIndex == nil && copy.children.isEmpty ? nil : copy
        }
    }

    // MARK: Halves

    /// Cuts pages in two, such as scans of an open book. Each page becomes two pages, each
    /// showing one half.
    ///
    /// - Parameter direction: `.vertical` cuts top to bottom and gives a left and a right
    ///   page; `.horizontal` cuts side to side and gives a top and a bottom page. Both are
    ///   as the page is displayed, whichever way it is turned.
    /// - Parameter rightToLeft: Puts the right half first, for books read that way.
    public mutating func splitPagesInHalf(at indexes: some Sequence<Int>, direction: SplitDirection, rightToLeft: Bool = false) throws {
        let count = try pageCount()
        // From the back, so earlier page numbers stay valid as pages are added.
        for index in Set(indexes).sorted(by: >) {
            guard index >= 0, index < count else { throw SheafError.pageOutOfRange(index) }
            let geometry = try geometry(ofPageAt: index)
            let size = geometry.displaySize
            // The halves as displayed, in reading order.
            var halves: [(PDFPoint, PDFPoint)] = switch direction {
            case .vertical: [
                (PDFPoint(x: 0, y: 0), PDFPoint(x: size.width / 2, y: size.height)),
                (PDFPoint(x: size.width / 2, y: 0), PDFPoint(x: size.width, y: size.height)),
            ]
            case .horizontal: [
                (PDFPoint(x: 0, y: size.height / 2), PDFPoint(x: size.width, y: size.height)),
                (PDFPoint(x: 0, y: 0), PDFPoint(x: size.width, y: size.height / 2)),
            ]
            }
            if rightToLeft, direction == .vertical { halves.reverse() }
            try duplicatePage(at: index)
            for (offset, half) in halves.enumerated() {
                let corners = [geometry.fromDisplay.apply(half.0), geometry.fromDisplay.apply(half.1)]
                guard let box = PDFRectangle(enclosing: corners) else { continue }
                try setCropBox(box, forPageAt: index + offset)
            }
        }
    }

    // MARK: Removed pages

    /// Takes away what pointed at pages that are no longer in the document: links to them
    /// from other pages, and bookmarks. A bookmark that still groups others stays, without
    /// a page to jump to.
    mutating func removeReferences(toPages removed: Set<ObjectID>, indexes: Set<Int>, outlineBefore: [OutlineItem]?) throws {
        for page in try pageIDs() {
            guard let dictionary = try object(page).dictionaryValue,
                  let annotations = try value("Annots", in: dictionary).arrayValue
            else { continue }
            let kept = try annotations.filter { entry in
                guard let annotation = try resolve(entry).dictionaryValue, annotation["Subtype"]?.nameValue == "Link" else { return true }
                var destination = annotation["Dest"]
                if destination == nil, let action = try value("A", in: annotation).dictionaryValue, action["S"]?.nameValue == "GoTo" {
                    destination = action["D"]
                }
                guard let destination, let target = try resolveDestination(destination)?.first?.referenceValue else { return true }
                return !removed.contains(target)
            }
            if kept.count != annotations.count {
                try update(page) { $0["Annots"] = kept.isEmpty ? nil : .array(kept) }
            }
        }

        guard let outlineBefore else { return }
        var changed = false
        func pruned(_ items: [OutlineItem]) -> [OutlineItem] {
            items.compactMap { item in
                var copy = item
                copy.children = pruned(item.children)
                guard let page = item.pageIndex, indexes.contains(page) else { return copy }
                changed = true
                if copy.children.isEmpty { return nil }
                copy.pageIndex = nil
                copy.storedPageIndex = nil
                copy.stored["Dest"] = nil
                copy.stored["A"] = nil
                return copy
            }
        }
        let outline = pruned(outlineBefore)
        if changed { try setOutline(outline) }
    }
}

public enum SplitDirection: String, Sendable, CaseIterable {
    case vertical, horizontal
}

// MARK: - Merging

/// One document going into a merge.
public struct MergeSource {
    public var document: PDFEditor
    /// What to call this document's section in the result's table of contents.
    public var title: String
    /// Which pages to take, in order. All of them when `nil`.
    public var pageIndexes: [Int]?

    public init(document: PDFEditor, title: String, pageIndexes: [Int]? = nil) {
        self.document = document
        self.title = title
        self.pageIndexes = pageIndexes
    }
}

extension PDFGenerator {
    /// Joins documents end to end into a new one.
    ///
    /// Fonts and images that several of them share are stored once.
    ///
    /// - Parameter bookmarksPerDocument: Gives each document an entry in the table of
    ///   contents, named by its title, with the document's own bookmarks under it. When
    ///   off, the documents' bookmarks follow one another at the top level.
    public static func merged(_ sources: [MergeSource], bookmarksPerDocument: Bool = true) throws -> Data {
        guard !sources.isEmpty else { throw SheafError.unsupported("a merge of nothing") }
        // The newest version among the sources, so nothing any of them uses is out of place.
        let version = sources.map { ($0.document.base.version.major, $0.document.base.version.minor) }.max { $0 < $1 } ?? (1, 7)
        var target = PDFEditor.empty(version: version)
        var outline: [OutlineItem] = []
        for source in sources {
            let count = try source.document.pageCount()
            let indexes = source.pageIndexes ?? Array(0..<count)
            guard !indexes.isEmpty else { continue }
            let offset = try target.pageCount()
            try target.insertPages(from: source.document, pageIndexes: indexes)

            var mapping: [Int: Int] = [:]
            for (new, old) in indexes.enumerated() where mapping[old] == nil { mapping[old] = offset + new }
            let own = PDFEditor.remapped((try? source.document.outline()) ?? [], mapping)
            if bookmarksPerDocument {
                var entry = OutlineItem(title: source.title, pageIndex: offset, children: own)
                entry.isExpanded = false
                outline.append(entry)
            } else {
                outline.append(contentsOf: own)
            }
        }
        guard try target.pageCount() > 0 else { throw SheafError.unsupported("a document with no pages") }
        if !outline.isEmpty { try target.setOutline(outline) }
        return try target.rewritten()
    }
}
