import Foundation

/// Anything that can look up indirect objects: a file as read, or a file with pending edits.
public protocol ObjectSource {
    /// The object with this number, or `.null` when there is none.
    func object(_ id: ObjectID) throws -> PDFObject
    var trailer: PDFDictionary { get }
}

extension ObjectSource {
    /// Follows references until reaching an actual object.
    public func resolve(_ object: PDFObject) throws -> PDFObject {
        var current = object
        for _ in 0..<64 {
            guard case .reference(let id) = current else { return current }
            current = try self.object(id)
        }
        throw SheafError.malformed("references form a loop")
    }

    /// The value for a key in a dictionary, with a reference followed.
    public func value(_ key: PDFName, in dictionary: PDFDictionary) throws -> PDFObject {
        try resolve(dictionary[key] ?? .null)
    }

    public var catalogID: ObjectID? { trailer["Root"]?.referenceValue }

    public func catalog() throws -> PDFDictionary {
        guard let catalog = try resolve(trailer["Root"] ?? .null).dictionaryValue else {
            throw SheafError.malformed("document has no catalog")
        }
        return catalog
    }

    /// The document's pages in reading order.
    public func pageIDs() throws -> [ObjectID] {
        guard let root = try catalog()["Pages"]?.referenceValue else { return [] }
        var pages: [ObjectID] = []
        var visited: Set<ObjectID> = []
        // An explicit stack, so a deep or malicious tree cannot overflow the call stack.
        var pending: [ObjectID] = [root]
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let node = try object(id).dictionaryValue else { continue }
            if let kids = try value("Kids", in: node).arrayValue {
                pending.append(contentsOf: kids.reversed().compactMap(\.referenceValue))
            } else if node["Type"]?.nameValue != "Pages" {
                pages.append(id)
            }
        }
        return pages
    }

    /// A page attribute that may be set on the page or inherited from the nodes above it.
    public func inherited(_ key: PDFName, forPage id: ObjectID) throws -> PDFObject? {
        var current: ObjectID? = id
        var steps = 0
        while let node = current, steps < 64 {
            guard let dictionary = try object(node).dictionaryValue else { return nil }
            if let value = dictionary[key], !value.isNull { return value }
            current = dictionary["Parent"]?.referenceValue
            steps += 1
        }
        return nil
    }

    /// A stream's bytes with all its filters undone.
    public func decodedData(of stream: PDFStream) throws -> Data {
        try StreamFilters.decode(stream, resolve: resolve)
    }
}
