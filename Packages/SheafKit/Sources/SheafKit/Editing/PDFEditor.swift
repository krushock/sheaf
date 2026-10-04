import Foundation

/// Fonts read from a document, kept so each is read once.
final class FontCache {
    private var fonts: [ObjectID: (dictionary: PDFDictionary, font: PageFont)] = [:]

    /// The font read from an object earlier, if the object still says the same.
    func font(for id: ObjectID, _ dictionary: PDFDictionary) -> PageFont? {
        guard let known = fonts[id], known.dictionary == dictionary else { return nil }
        return known.font
    }

    func keep(_ font: PageFont, for id: ObjectID, _ dictionary: PDFDictionary) {
        if fonts.count > 512 { fonts.removeAll() }
        fonts[id] = (dictionary, font)
    }
}

/// A document being edited: a file plus the objects that have been changed or added.
///
/// The file itself is never touched. Copying an editor copies only the list of changes, so
/// keeping earlier copies around for undo is cheap.
public struct PDFEditor: ObjectSource {
    public let base: PDFFile
    /// Changed and new objects, by object number.
    private(set) var changes: [Int: PDFObject] = [:]
    private(set) var nextObjectNumber: Int
    public private(set) var trailer: PDFDictionary
    /// Leaf streams brought in by imports, by content hash, so identical ones are stored once.
    var importedStreams: [Data: ObjectID] = [:]
    /// Installed fonts put into the document for typed text, by name, with the objects
    /// each is written to. A font gains glyphs as more is typed in it.
    var typedFonts: [String: (font: EmbeddedFont, objects: EmbeddedFont.Objects)] = [:]
    /// Fonts already read. Shared by copies of the editor, since reading a font is slow
    /// and the same fonts are met on page after page.
    let fontCache = FontCache()

    public init(_ file: PDFFile) {
        base = file
        trailer = file.trailer
        nextObjectNumber = file.crossReference.nextObjectNumber
    }

    public var hasChanges: Bool { !changes.isEmpty || trailer != base.trailer }

    // MARK: Objects

    public func object(_ id: ObjectID) throws -> PDFObject {
        if let changed = changes[id.number] { return changed }
        return try base.object(id)
    }

    /// The identifier an object number has in the file being edited.
    func id(forNumber number: Int) -> ObjectID {
        ObjectID(number, number < base.crossReference.nextObjectNumber ? base.generation(of: number) : 0)
    }

    var changedNumbers: [Int] { changes.keys.sorted() }

    /// Whether an object is still exactly what the file holds.
    func isAsInFile(_ id: ObjectID) -> Bool {
        changes[id.number] == nil && id.number < base.crossReference.nextObjectNumber
    }

    /// Replaces an existing object.
    public mutating func set(_ object: PDFObject, for id: ObjectID) {
        changes[id.number] = object
    }

    /// Adds a new indirect object and returns its identifier.
    @discardableResult
    public mutating func add(_ object: PDFObject) -> ObjectID {
        let id = reserve()
        changes[id.number] = object
        return id
    }

    /// Sets aside an object number to be filled in later.
    mutating func reserve() -> ObjectID {
        defer { nextObjectNumber += 1 }
        return ObjectID(nextObjectNumber)
    }

    /// Changes the dictionary of a dictionary or stream object in place.
    public mutating func update(_ id: ObjectID, _ change: (inout PDFDictionary) throws -> Void) throws {
        switch try object(id) {
        case .dictionary(var dictionary):
            try change(&dictionary)
            set(.dictionary(dictionary), for: id)
        case .stream(var stream):
            try change(&stream.dictionary)
            set(.stream(stream), for: id)
        default:
            throw SheafError.malformed("object \(id.number) is not a dictionary")
        }
    }

    mutating func setTrailer(_ key: PDFName, _ value: PDFObject?) {
        trailer[key] = value
    }

    // MARK: Pages

    public func pageCount() throws -> Int {
        try pageIDs().count
    }

    private func pageID(at index: Int) throws -> ObjectID {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        return pages[index]
    }

    /// The page's size as drawn, before rotation: its crop box, or its media box without one.
    public func pageBox(at index: Int, cropped: Bool = true) throws -> PDFRectangle {
        let id = try pageID(at: index)
        if cropped, let box = try inherited("CropBox", forPage: id).map(resolve).flatMap(PDFRectangle.init) { return box }
        guard let box = try inherited("MediaBox", forPage: id).map(resolve).flatMap(PDFRectangle.init) else {
            throw SheafError.malformed("page \(index + 1) has no media box")
        }
        return box
    }

    /// Clockwise rotation in degrees: 0, 90, 180 or 270.
    public func pageRotation(at index: Int) throws -> Int {
        let raw = try inherited("Rotate", forPage: try pageID(at: index)).map(resolve)?.intValue ?? 0
        return ((raw % 360) + 360) % 360
    }

    /// Turns a page clockwise by a multiple of 90 degrees. Negative values turn it the other way.
    public mutating func rotatePage(at index: Int, by degrees: Int) throws {
        guard degrees % 90 == 0 else { throw SheafError.unsupported("rotation by \(degrees) degrees") }
        let id = try pageID(at: index)
        let rotation = (((try pageRotation(at: index) + degrees) % 360) + 360) % 360
        try update(id) { $0["Rotate"] = .integer(rotation) }
    }

    /// Sets or clears the part of a page that is shown. The box is clipped to the media box.
    public mutating func setCropBox(_ box: PDFRectangle?, forPageAt index: Int) throws {
        let id = try pageID(at: index)
        guard let box else {
            // An inherited crop box cannot be removed by deleting the key, so set the full page.
            let media = try pageBox(at: index, cropped: false)
            let isInherited = try object(id).dictionaryValue?["CropBox"] == nil && (try inherited("CropBox", forPage: id)) != nil
            try update(id) { $0["CropBox"] = isInherited ? media.object : nil }
            return
        }
        let media = try pageBox(at: index, cropped: false)
        let left = max(box.x, media.x), bottom = max(box.y, media.y)
        let right = min(box.x + box.width, media.x + media.width), top = min(box.y + box.height, media.y + media.height)
        guard right > left, top > bottom else { throw SheafError.unsupported("a crop box outside the page") }
        let clipped = PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom)
        try update(id) { $0["CropBox"] = clipped.object }
    }

    /// Puts the pages in a new order. `order[i]` is the current index of the page that
    /// will be at position `i`. Leaving an index out removes that page; repeating one is an error.
    ///
    /// Links and bookmarks that led to a removed page are removed with it.
    public mutating func arrangePages(_ order: [Int]) throws {
        let pages = try pageIDs()
        guard !order.isEmpty else { throw SheafError.unsupported("a document with no pages") }
        guard Set(order).count == order.count else { throw SheafError.unsupported("the same page listed twice") }
        for index in order where !pages.indices.contains(index) { throw SheafError.pageOutOfRange(index) }
        let removed = Set(pages.indices).subtracting(order)
        // Read before the pages go, while bookmarks can still say which page they lead to.
        let outlineBefore = removed.isEmpty ? nil : try? outline()
        try setPages(order.map { pages[$0] })
        if !removed.isEmpty {
            try removeReferences(toPages: Set(removed.map { pages[$0] }), indexes: removed, outlineBefore: outlineBefore)
        }
    }

    public mutating func movePage(from source: Int, to destination: Int) throws {
        var order = Array(0..<(try pageCount()))
        guard order.indices.contains(source) else { throw SheafError.pageOutOfRange(source) }
        guard order.indices.contains(destination) else { throw SheafError.pageOutOfRange(destination) }
        order.insert(order.remove(at: source), at: destination)
        try arrangePages(order)
    }

    public mutating func removePages(at indexes: some Sequence<Int>) throws {
        let removed = Set(indexes)
        let count = try pageCount()
        for index in removed where index < 0 || index >= count { throw SheafError.pageOutOfRange(index) }
        try arrangePages((0..<count).filter { !removed.contains($0) })
    }

    /// Adds an empty page so that it becomes the page at `index`.
    @discardableResult
    public mutating func insertBlankPage(size: PageSize, at index: Int) throws -> ObjectID {
        let page = add(["Type": .name("Page"), "MediaBox": PDFRectangle(x: 0, y: 0, width: size.width, height: size.height).object, "Resources": [:]])
        try insert([page], at: index)
        return page
    }

    /// Adds a second copy of a page right after it. The copy shares the original's content
    /// and resources, so it costs almost nothing until one of them is edited. Annotations
    /// are copied, except form fields, which can only sit on one page.
    @discardableResult
    public mutating func duplicatePage(at index: Int) throws -> ObjectID {
        let id = try pageID(at: index)
        guard var dictionary = try object(id).dictionaryValue else { throw SheafError.malformed("page is not a dictionary") }
        for key in PageTree.inheritableKeys where dictionary[key] == nil {
            dictionary[key] = try inherited(key, forPage: id)
        }
        dictionary["StructParents"] = nil
        dictionary["B"] = nil
        let copy = reserve()

        // Each annotation becomes a new object on the new page. What it points at, such as
        // its appearance, stays shared; links between the page's annotations are kept.
        var annotations: [(new: ObjectID, dictionary: PDFDictionary)] = []
        var mapping: [ObjectID: ObjectID] = [id: copy]
        for entry in try value("Annots", in: dictionary).arrayValue ?? [] {
            guard var annotation = try resolve(entry).dictionaryValue, annotation["Subtype"]?.nameValue != "Widget" else { continue }
            annotation["StructParent"] = nil
            let new = reserve()
            if let old = entry.referenceValue { mapping[old] = new }
            annotations.append((new, annotation))
        }
        for (new, var annotation) in annotations {
            for (key, value) in annotation {
                if let target = value.referenceValue, let mapped = mapping[target] { annotation[key] = .reference(mapped) }
            }
            annotation["P"] = .reference(copy)
            set(.dictionary(annotation), for: new)
        }
        dictionary["Annots"] = annotations.isEmpty ? nil : .array(annotations.map { .reference($0.new) })

        set(.dictionary(dictionary), for: copy)
        try insert([copy], at: index + 1)
        return copy
    }

    mutating func insert(_ newPages: [ObjectID], at index: Int) throws {
        var pages = try pageIDs()
        guard index >= 0, index <= pages.count else { throw SheafError.pageOutOfRange(index) }
        pages.insert(contentsOf: newPages, at: index)
        try setPages(pages)
    }

    /// Rewrites the page tree as one flat list.
    ///
    /// Pages that sat under intermediate nodes get the attributes they used to inherit, then
    /// all pages hang directly off the root. Only pages whose parent changes are rewritten.
    private mutating func setPages(_ pages: [ObjectID]) throws {
        guard let root = try catalog()["Pages"]?.referenceValue else { throw SheafError.malformed("catalog has no pages") }
        var updates: [(ObjectID, PDFDictionary)] = []
        for id in pages {
            guard var dictionary = try object(id).dictionaryValue else { throw SheafError.malformed("page is not a dictionary") }
            guard dictionary["Parent"]?.referenceValue != root else { continue }
            if dictionary["Parent"] != nil {
                for key in PageTree.inheritableKeys where dictionary[key] == nil {
                    dictionary[key] = try inherited(key, forPage: id)
                }
            }
            dictionary["Parent"] = .reference(root)
            updates.append((id, dictionary))
        }
        for (id, dictionary) in updates { set(.dictionary(dictionary), for: id) }
        try update(root) { node in
            node["Type"] = .name("Pages")
            node["Kids"] = .array(pages.map(PDFObject.reference))
            node["Count"] = .integer(pages.count)
        }
    }
}

enum PageTree {
    /// Attributes a page takes from the nodes above it when it does not set them itself.
    static let inheritableKeys: [PDFName] = ["Resources", "MediaBox", "CropBox", "Rotate"]
}
