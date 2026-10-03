import Foundation

/// A PDF as read from bytes: its objects, located through the cross-reference table and
/// decrypted when the file is protected. A `PDFFile` never changes; edits go in a `PDFEditor`.
///
/// Objects are parsed on first use and remembered. The type is not safe to use from several
/// threads at once.
public final class PDFFile: ObjectSource {
    public let data: Data
    /// Where the `%PDF` header starts. Zero except in files with junk at the front.
    public let headerOffset: Int
    /// The version from the header, such as 1.7.
    public let version: (major: Int, minor: Int)
    public private(set) var trailer: PDFDictionary

    private(set) var crossReference: CrossReference
    private(set) var security: SecurityHandler?
    private var encryptObjectID: ObjectID?
    private var cache: [Int: PDFObject] = [:]
    private var objectStreams: [Int: ObjectStream] = [:]
    /// Objects in the middle of being read, to stop a file that refers to itself.
    private var loading: Set<Int> = []

    /// - Parameter password: The user or owner password. Leave `nil` for unprotected files
    ///   and for protected files with an empty user password.
    /// - Throws: `SheafError.notAPDF`, `.passwordRequired` or `.incorrectPassword`.
    public init(data: Data, password: String? = nil) throws {
        // Slices index from their parent's offsets; rebasing keeps the arithmetic simple.
        let data = data.startIndex == 0 ? data : Data(data)
        guard let header = data.parse({ $0.find("%PDF-", from: 0) }), header < 1024 else { throw SheafError.notAPDF }
        self.data = data
        headerOffset = header
        version = data.parse(at: header + 5) { parser in
            let major = parser.readUnsignedInteger() ?? 1
            parser.position += 1
            return (major, parser.readUnsignedInteger() ?? 0)
        }

        if let table = try? CrossReference.read(from: data, headerOffset: header) {
            crossReference = table
        } else {
            crossReference = try CrossReference.rebuild(from: data)
        }
        trailer = crossReference.trailer

        do {
            try unlock(password: password)
            guard try catalog()["Pages"] != nil else { throw SheafError.malformed("catalog has no pages") }
        } catch let error as SheafError where error == .passwordRequired || error == .incorrectPassword {
            throw error
        } catch {
            // The table pointed at the wrong places. Find the objects directly and try once more.
            guard !crossReference.wasRebuilt else { throw SheafError.notAPDF }
            try rebuildCrossReference()
            try unlock(password: password)
            guard (try? catalog()["Pages"]) != nil else { throw SheafError.notAPDF }
        }
    }

    private func rebuildCrossReference() throws {
        crossReference = try CrossReference.rebuild(from: data)
        trailer = crossReference.trailer
        cache = [:]
        objectStreams = [:]
    }

    // MARK: Protection

    public var isEncrypted: Bool { trailer["Encrypt"] != nil }

    /// The cipher protecting the file, or `nil` when it is not encrypted.
    public var encryptionAlgorithm: EncryptionAlgorithm? { security?.algorithm }

    /// What the file allows. Everything, when opened with the owner password or not protected.
    public var permissions: Permissions {
        guard let security, !security.isOwner else { return .all }
        return security.permissions
    }

    /// Whether the password given was the owner password.
    public var isOpenedAsOwner: Bool { security?.isOwner ?? true }

    /// The first half of the file identifier, which encryption keys depend on.
    var documentID: Data {
        trailer["ID"]?.arrayValue?.first?.stringValue ?? Data()
    }

    /// The `/Encrypt` dictionary as stored, with its direct contents resolved.
    private(set) var encryptDictionary: PDFDictionary?

    private func unlock(password: String?) throws {
        guard let entry = trailer["Encrypt"] else { return }
        // The encryption dictionary itself is never encrypted, so read it with no handler set.
        security = nil
        encryptObjectID = entry.referenceValue
        cache = [:]
        objectStreams = [:]
        guard var dictionary = try resolve(entry).dictionaryValue else {
            throw SheafError.malformed("encryption dictionary is missing")
        }
        for (key, value) in dictionary { dictionary[key] = try resolve(value) }
        if var filters = dictionary["CF"]?.dictionaryValue {
            for (name, filter) in filters { filters[name] = try resolve(filter) }
            dictionary["CF"] = .dictionary(filters)
        }
        encryptDictionary = dictionary
        // Anything read so far was read without decryption.
        cache = [:]
        do {
            security = try SecurityHandler(dictionary: dictionary, documentID: documentID, password: password ?? "")
        } catch SheafError.incorrectPassword {
            throw password == nil ? SheafError.passwordRequired : SheafError.incorrectPassword
        }
    }

    // MARK: Objects

    /// The numbers of all objects the file defines.
    public var objectNumbers: [Int] {
        crossReference.entries.compactMap { $0.value == .free ? nil : $0.key }.sorted()
    }

    func defines(_ number: Int) -> Bool {
        switch crossReference.entries[number] {
        case nil, .free: false
        default: true
        }
    }

    func generation(of number: Int) -> Int {
        if case .inUse(_, let generation) = crossReference.entries[number] { return generation }
        return 0
    }

    public func object(_ id: ObjectID) throws -> PDFObject {
        if let cached = cache[id.number] { return cached }
        let object: PDFObject
        do {
            object = try load(id.number)
        } catch where !crossReference.wasRebuilt {
            // The table is wrong about this object. Locate the objects directly and retry.
            let handler = security, dictionary = encryptDictionary, encryptID = encryptObjectID
            try rebuildCrossReference()
            (security, encryptDictionary, encryptObjectID) = (handler, dictionary, encryptID)
            object = try load(id.number)
        }
        cache[id.number] = object
        return object
    }

    /// Reads an object without remembering it. For passes over a whole file.
    func uncachedObject(_ number: Int) throws -> PDFObject {
        try cache[number] ?? load(number)
    }

    /// Whether the file's own index was unusable and its objects had to be located by scanning.
    public var wasRepaired: Bool { crossReference.wasRebuilt }

    private func load(_ number: Int) throws -> PDFObject {
        guard loading.insert(number).inserted else {
            throw SheafError.malformed("object \(number) depends on itself")
        }
        defer { loading.remove(number) }
        switch crossReference.entries[number] {
        case nil, .free:
            return .null
        case .inUse(let offset, _):
            let parsed = try data.parse(at: offset + (crossReference.wasRebuilt ? 0 : headerOffset)) { parser in
                try parser.parseIndirectObject(resolveLength: { [unowned self] in try? self.object($0).intValue })
            }
            guard parsed.id.number == number else {
                throw SheafError.malformed("object \(number) is not where the file says it is")
            }
            return decrypt(parsed.object, id: parsed.id)
        case .compressed(let streamNumber, let index):
            let container: ObjectStream
            if let existing = objectStreams[streamNumber] {
                container = existing
            } else {
                if case .compressed = crossReference.entries[streamNumber] {
                    throw SheafError.malformed("object stream \(streamNumber) is itself packed in a stream")
                }
                guard let stream = try object(ObjectID(streamNumber)).streamValue else {
                    throw SheafError.malformed("object stream \(streamNumber) is missing")
                }
                container = try ObjectStream(stream, resolve: resolve)
                objectStreams[streamNumber] = container
            }
            // Objects packed in a stream were encrypted as part of it, not one by one.
            return try container.object(at: index)
        }
    }

    private func decrypt(_ object: PDFObject, id: ObjectID) -> PDFObject {
        guard let security, id != encryptObjectID else { return object }
        if case .stream(var stream) = object {
            let type = stream.dictionary["Type"]?.nameValue
            if type == "XRef" { return object }
            stream.dictionary = decryptStrings(in: .dictionary(stream.dictionary), id: id, security).dictionaryValue ?? [:]
            let isExempt = type == "Metadata" && !security.encryptMetadata || usesIdentityCryptFilter(stream.dictionary)
            if !isExempt { stream.data = security.decrypt(streamData: stream.data, id: id) }
            return .stream(stream)
        }
        return decryptStrings(in: object, id: id, security)
    }

    private func decryptStrings(in object: PDFObject, id: ObjectID, _ security: SecurityHandler) -> PDFObject {
        switch object {
        case .string(let value):
            return .string(security.decrypt(string: value, id: id))
        case .array(let elements):
            return .array(elements.map { decryptStrings(in: $0, id: id, security) })
        case .dictionary(var dictionary):
            // A signature's value is stored in the clear so that it can be verified.
            let isSignature = dictionary["ByteRange"] != nil
            for (key, value) in dictionary where !(isSignature && key == "Contents") {
                dictionary[key] = decryptStrings(in: value, id: id, security)
            }
            return .dictionary(dictionary)
        default:
            return object
        }
    }

    private func usesIdentityCryptFilter(_ dictionary: PDFDictionary) -> Bool {
        return StreamFilters.filters(of: dictionary, resolve: { $0 }).contains { $0.name == "Crypt" && ($0.parameters["Name"]?.nameValue ?? "Identity") == "Identity" }
    }
}
