import Foundation

extension PDFEditor {
    /// Copies pages from another document into this one.
    ///
    /// Everything a page needs comes with it: content, fonts, images and annotations. Links
    /// to pages that are not copied are dropped. Form fields keep their appearance but are
    /// not connected to this document's form, and the other document's bookmarks are not copied.
    ///
    /// - Parameters:
    ///   - pageIndexes: Which pages to copy, in the order they should appear. All of them when `nil`.
    ///   - index: Where the first copied page goes. At the end when `nil`.
    @discardableResult
    public mutating func insertPages(from source: some ObjectSource, pageIndexes: [Int]? = nil, at index: Int? = nil) throws -> [ObjectID] {
        let sourcePages = try source.pageIDs()
        let selection = pageIndexes ?? Array(sourcePages.indices)
        for index in selection where !sourcePages.indices.contains(index) { throw SheafError.pageOutOfRange(index) }

        // Number the pages first, so that links between copied pages keep working.
        var copier = ObjectCopier(source: source, sourcePages: Set(sourcePages))
        var newPages: [ObjectID] = []
        var repeats: [(page: ObjectID, new: ObjectID)] = []
        for index in selection {
            let page = sourcePages[index], id = reserve()
            if copier.mapping[page] == nil {
                copier.mapping[page] = id
            } else {
                repeats.append((page, id))
            }
            newPages.append(id)
        }
        for index in Set(selection) {
            let page = sourcePages[index]
            if let id = copier.mapping[page] { try copyPage(page, as: id, with: &copier) }
        }
        try copier.finish(into: &self)
        // A page chosen more than once gets its own annotations each extra time, so those
        // copies are made separately. Fonts and images are still stored once.
        for (page, id) in repeats {
            var separate = ObjectCopier(source: source, sourcePages: Set(sourcePages))
            separate.mapping[page] = id
            try copyPage(page, as: id, with: &separate)
            try separate.finish(into: &self)
        }
        try insert(newPages, at: index ?? (try pageCount()))
        return newPages
    }

    private mutating func copyPage<Source: ObjectSource>(_ page: ObjectID, as newID: ObjectID, with copier: inout ObjectCopier<Source>) throws {
        let source = copier.source
        guard var dictionary = try source.object(page).dictionaryValue else {
            throw SheafError.malformed("page is not a dictionary")
        }
        for key in PageTree.inheritableKeys where dictionary[key] == nil {
            dictionary[key] = try source.inherited(key, forPage: page)
        }
        dictionary["Parent"] = nil
        dictionary["B"] = nil
        var copied = try copier.copy(.dictionary(dictionary), into: &self).dictionaryValue ?? [:]
        copied["Type"] = .name("Page")
        set(.dictionary(copied), for: newID)
    }
}

/// Copies objects from one document into another, giving them new numbers.
struct ObjectCopier<Source: ObjectSource> {
    let source: Source
    let sourcePages: Set<ObjectID>
    /// Source object to its copy.
    var mapping: [ObjectID: ObjectID] = [:]
    /// Objects that have a number in the target but have not been copied yet.
    private var pending: [(source: ObjectID, target: ObjectID)] = []

    init(source: Source, sourcePages: Set<ObjectID>) {
        self.source = source
        self.sourcePages = sourcePages
    }

    /// Copies a value, queueing whatever it refers to.
    mutating func copy(_ object: PDFObject, into editor: inout PDFEditor) throws -> PDFObject {
        switch object {
        case .reference(let id):
            return try reference(to: id, in: &editor)
        case .array(let elements):
            return .array(try elements.map { try copy($0, into: &editor) })
        case .dictionary(let dictionary):
            return .dictionary(try copy(dictionary, into: &editor))
        case .stream(var stream):
            stream.dictionary = try copy(stream.dictionary, into: &editor)
            return .stream(stream)
        default:
            return object
        }
    }

    private mutating func copy(_ dictionary: PDFDictionary, into editor: inout PDFEditor) throws -> PDFDictionary {
        var result: PDFDictionary = [:]
        // A form widget's parent is its field, which belongs to the other document's form.
        let isWidget = dictionary["Subtype"]?.nameValue == "Widget"
        for (key, value) in dictionary {
            if key == "StructParent" || key == "StructParents" || (isWidget && key == "Parent") { continue }
            let copied = try copy(value, into: &editor)
            // A destination whose page stayed behind leads nowhere, so the link loses it.
            if key == "Dest" || key == "D", value.arrayValue?.first?.referenceValue != nil,
               copied.arrayValue?.first?.isNull == true { continue }
            if !copied.isNull { result[key] = copied }
        }
        return result
    }

    private mutating func reference(to id: ObjectID, in editor: inout PDFEditor) throws -> PDFObject {
        if let existing = mapping[id] { return .reference(existing) }
        let object = try source.object(id)
        if object.isNull { return .null }
        // Other pages, and the page tree, stay behind.
        if sourcePages.contains(id) { return .null }
        if let type = object.dictionaryValue?["Type"]?.nameValue, type == "Page" || type == "Pages" { return .null }

        if case .stream(let stream) = object, !PDFObject.dictionary(stream.dictionary).containsReference {
            // A stream that refers to nothing else, such as a font program or a plain image.
            // Identical ones from earlier imports are reused.
            let digest = Hash.sha256(Serializer.data(.dictionary(stream.dictionary)) + stream.data)
            if let existing = editor.importedStreams[digest] {
                mapping[id] = existing
                return .reference(existing)
            }
            let target = editor.add(object)
            editor.importedStreams[digest] = target
            mapping[id] = target
            return .reference(target)
        }

        let target = editor.reserve()
        mapping[id] = target
        pending.append((id, target))
        return .reference(target)
    }

    /// Copies everything that was queued. A queue rather than recursion, so long chains of
    /// objects cannot exhaust the stack.
    mutating func finish(into editor: inout PDFEditor) throws {
        while let (sourceID, targetID) = pending.popLast() {
            editor.set(try copy(try source.object(sourceID), into: &editor), for: targetID)
        }
    }
}
