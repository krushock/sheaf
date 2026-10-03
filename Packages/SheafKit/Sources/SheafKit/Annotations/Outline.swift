import Foundation

/// One entry of a document's table of contents, also known as a bookmark.
public struct OutlineItem: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    /// The page the entry jumps to, counted from zero. `nil` when it leads elsewhere or nowhere.
    public var pageIndex: Int?
    /// How far up the page the entry lands, in page coordinates. `nil` for the top.
    public var top: Double?
    public var children: [OutlineItem]
    /// Whether the entry's children are shown when the document is first opened.
    public var isExpanded = false

    /// What the entry was stored with, kept so that entries nobody touched keep their exact
    /// destination, including the scroll position and zoom it asks for.
    var stored: PDFDictionary = [:]
    var storedPageIndex: Int?

    public init(title: String, pageIndex: Int?, children: [OutlineItem] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

extension ObjectSource {
    /// The document's table of contents.
    public func outline() throws -> [OutlineItem] {
        guard let root = try value("Outlines", in: try catalog()).dictionaryValue else { return [] }
        let pageIndexes = Dictionary(try pageIDs().enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<ObjectID> = []
        var budget = 100_000

        func items(startingAt first: PDFObject?, depth: Int) throws -> [OutlineItem] {
            var result: [OutlineItem] = []
            var next = first
            while let reference = next?.referenceValue, depth < 64, budget > 0, visited.insert(reference).inserted {
                budget -= 1
                guard let dictionary = try object(reference).dictionaryValue else { break }
                var item = OutlineItem(title: try value("Title", in: dictionary).textValue ?? "", pageIndex: nil)
                let action = try value("A", in: dictionary).dictionaryValue
                let isJump = action == nil || action?["S"]?.nameValue == "GoTo"
                if isJump, let destination = try resolveDestination(dictionary["Dest"] ?? action?["D"] ?? .null),
                   let target = destination.first?.referenceValue {
                    item.pageIndex = pageIndexes[target]
                    switch destination.dropFirst().first?.nameValue {
                    case "XYZ": item.top = destination.count > 3 ? destination[3].doubleValue : nil
                    case "FitH", "FitBH": item.top = destination.count > 2 ? destination[2].doubleValue : nil
                    default: break
                    }
                }
                item.storedPageIndex = item.pageIndex
                for key in ["Dest", "A", "C", "F", "SE"] as [PDFName] { item.stored[key] = dictionary[key] }
                item.isExpanded = (try value("Count", in: dictionary).intValue ?? 0) > 0
                item.children = try items(startingAt: dictionary["First"], depth: depth + 1)
                result.append(item)
                next = dictionary["Next"]
            }
            return result
        }
        return try items(startingAt: root["First"], depth: 0)
    }
}

extension PDFEditor {
    /// Replaces the document's table of contents.
    public mutating func setOutline(_ items: [OutlineItem]) throws {
        guard let catalogID else { throw SheafError.malformed("document has no catalog") }
        guard !items.isEmpty else {
            try update(catalogID) { $0["Outlines"] = nil }
            return
        }
        let pages = try pageIDs()
        let root = reserve()

        // Returns the first and last entries of a level, and how many rows it shows when open.
        func write(_ items: [OutlineItem], parent: ObjectID, depth: Int) throws -> (first: ObjectID, last: ObjectID, visible: Int) {
            let ids = items.map { _ in reserve() }
            var visible = items.count
            for (index, item) in items.enumerated() {
                var dictionary: PDFDictionary = ["Title": .string(PDFText.encode(item.title)), "Parent": .reference(parent)]
                if index > 0 { dictionary["Prev"] = .reference(ids[index - 1]) }
                if index + 1 < items.count { dictionary["Next"] = .reference(ids[index + 1]) }
                for key in ["C", "F", "SE"] as [PDFName] { dictionary[key] = item.stored[key] }

                if item.pageIndex == item.storedPageIndex, item.stored["Dest"] != nil || item.stored["A"] != nil {
                    dictionary["Dest"] = item.stored["Dest"]
                    dictionary["A"] = item.stored["A"]
                } else if let pageIndex = item.pageIndex, pages.indices.contains(pageIndex) {
                    // The top of the page, keeping whatever zoom the reader is using.
                    let top = item.top ?? (try? pageBox(at: pageIndex)).map { $0.y + $0.height } ?? 0
                    dictionary["Dest"] = [.reference(pages[pageIndex]), .name("XYZ"), 0, .real(top), 0]
                }
                if !item.children.isEmpty, depth < 64 {
                    let level = try write(item.children, parent: ids[index], depth: depth + 1)
                    dictionary["First"] = .reference(level.first)
                    dictionary["Last"] = .reference(level.last)
                    // A negative count means the entry is closed.
                    dictionary["Count"] = .integer(item.isExpanded ? level.visible : -level.visible)
                    if item.isExpanded { visible += level.visible }
                }
                set(.dictionary(dictionary), for: ids[index])
            }
            return (ids[0], ids[ids.count - 1], visible)
        }

        let level = try write(items, parent: root, depth: 0)
        set(["Type": .name("Outlines"), "First": .reference(level.first), "Last": .reference(level.last), "Count": .integer(level.visible)], for: root)
        try update(catalogID) { $0["Outlines"] = .reference(root) }
    }
}
