import Foundation

/// How the saved file should be protected.
public enum Protection: Sendable, Equatable {
    /// Leave it as it is: encrypted with the same passwords, or not encrypted.
    case keep
    /// Save without encryption.
    case none
    /// Encrypt with new passwords.
    case password(user: String, owner: String? = nil, permissions: Permissions = .all, algorithm: EncryptionAlgorithm = .aes256)
}

extension PDFEditor {
    /// The edited document as file bytes.
    ///
    /// By default the original bytes are kept exactly as they were and the changes are
    /// appended, which is fast, and safe for digitally signed files. That is not possible
    /// when protection changes or when the original needed repair; the file is then written
    /// out afresh.
    ///
    /// Appending never removes anything: a deleted page's content is still in the file.
    /// Use `rewritten` when removed material must really be gone.
    public func serialized(protection: Protection = .keep) throws -> Data {
        guard protection == .keep, !base.crossReference.wasRebuilt else {
            return try rewritten(protection: protection)
        }
        return try IncrementalWriter(editor: self).data()
    }

    /// Just the bytes that `serialized` adds after the original ones, or `nil` when the
    /// document cannot be saved by appending and has to be written afresh.
    ///
    /// Computing this costs time in proportion to the changes, not to the size of the file,
    /// so an app can keep it up to date after every edit.
    public func appendedBytes() throws -> Data? {
        guard !base.crossReference.wasRebuilt else { return nil }
        return try IncrementalWriter(editor: self).tail()
    }

    /// The document written out from scratch, containing only what is still in use.
    public func rewritten(protection: Protection = .keep, options: WriteOptions = WriteOptions()) throws -> Data {
        try FullWriter(editor: self, protection: protection, options: options).data()
    }
}

/// Choices about how a document is written out afresh.
public struct WriteOptions: Sendable, Equatable {
    /// Stores the document's many small objects together and compressed, which makes the
    /// file smaller.
    public var packsObjects = false
    /// Stores streams that are byte for byte the same, such as a logo embedded on every
    /// page, only once.
    public var mergesDuplicates = false

    public init(packsObjects: Bool = false, mergesDuplicates: Bool = false) {
        self.packsObjects = packsObjects
        self.mergesDuplicates = mergesDuplicates
    }
}

extension PDFObject {
    /// Whether the object refers to another one anywhere inside it.
    var containsReference: Bool {
        switch self {
        case .reference: true
        case .array(let elements): elements.contains(where: \.containsReference)
        case .dictionary(let dictionary): dictionary.values.contains(where: \.containsReference)
        case .stream(let stream): stream.dictionary.values.contains(where: \.containsReference)
        default: false
        }
    }
}

/// Encrypts with a document's key, for one object.
private struct Cipher: ObjectCipher {
    let handler: SecurityHandler
    let id: ObjectID
    /// Streams the format says are stored unencrypted.
    var leavesStreamAlone = false

    func encrypt(string: Data) -> Data { handler.encrypt(string: string, id: id) }
    func encrypt(streamData: Data) -> Data {
        leavesStreamAlone ? streamData : handler.encrypt(streamData: streamData, id: id)
    }

    static func make(_ handler: SecurityHandler?, id: ObjectID, object: PDFObject) -> Cipher? {
        guard let handler else { return nil }
        let isClearMetadata = object.streamValue?.dictionary["Type"]?.nameValue == "Metadata" && !handler.encryptMetadata
        return Cipher(handler: handler, id: id, leavesStreamAlone: isClearMetadata)
    }
}

private enum FileID {
    /// The two-part identifier for a saved file: the first part stays with the document for
    /// life, the second changes with every save.
    static func updated(_ existing: PDFObject?, changing content: Data) -> PDFObject {
        let fresh = Hash.md5(content)
        let first = existing?.arrayValue?.first?.stringValue ?? fresh
        return [.string(first), .string(fresh)]
    }
}

// MARK: - Appending changes

struct IncrementalWriter {
    let editor: PDFEditor

    func data() throws -> Data {
        editor.base.data + (try tail())
    }

    /// What gets added after the original bytes. Empty when nothing changed.
    func tail() throws -> Data {
        let base = editor.base
        guard editor.hasChanges else { return Data() }
        guard let previousSection = base.crossReference.newestSectionOffset else {
            throw SheafError.malformed("the file has no cross-reference section to extend")
        }

        // Offsets are counted as if the original bytes came first.
        var output = Data()
        if let last = base.data.last, last != 0x0A, last != 0x0D { output.append(0x0A) }
        let headerOffset = base.headerOffset - base.data.count

        var offsets: [(id: ObjectID, offset: Int)] = []
        for number in editor.changedNumbers {
            guard let object = editor.changes[number] else { continue }
            let id = editor.id(forNumber: number)
            offsets.append((id, output.count - headerOffset))
            Serializer.append(indirect: object, id: id, to: &output, cipher: Cipher.make(base.security, id: id, object: object))
        }

        var trailer = editor.trailer
        for key in ["Type", "W", "Index", "Filter", "DecodeParms", "Length", "XRefStm", "Prev"] as [PDFName] { trailer[key] = nil }
        trailer["Prev"] = .integer(previousSection)
        trailer["ID"] = FileID.updated(trailer["ID"], changing: output)

        let sectionOffset = output.count - headerOffset
        if base.crossReference.newestSectionIsStream {
            // A file indexed by a stream has to be extended with a stream.
            let streamID = ObjectID(editor.nextObjectNumber)
            offsets.append((streamID, sectionOffset))
            trailer["Size"] = .integer(streamID.number + 1)
            let stream = CrossReferenceWriter.stream(entries: offsets, trailer: trailer)
            Serializer.append(indirect: .stream(stream), id: streamID, to: &output)
        } else {
            trailer["Size"] = .integer(editor.nextObjectNumber)
            CrossReferenceWriter.appendTable(entries: offsets, includeFreeHead: false, to: &output)
            output.append(contentsOf: "trailer\n".utf8)
            Serializer.append(.dictionary(trailer), to: &output)
            output.append(0x0A)
        }
        output.append(contentsOf: "startxref\n\(sectionOffset)\n%%EOF\n".utf8)
        return output
    }
}

enum CrossReferenceWriter {
    /// A classic table. Entries must be sorted by object number.
    static func appendTable(entries: [(id: ObjectID, offset: Int)], includeFreeHead: Bool, to output: inout Data) {
        output.append(contentsOf: "xref\n".utf8)
        var lines: [(number: Int, text: String)] = includeFreeHead ? [(0, "0000000000 65535 f \n")] : []
        for entry in entries {
            lines.append((entry.id.number, String(format: "%010d %05d n \n", entry.offset, entry.id.generation)))
        }
        // One subsection per run of consecutive numbers.
        var start = 0
        while start < lines.count {
            var end = start + 1
            while end < lines.count, lines[end].number == lines[end - 1].number + 1 { end += 1 }
            output.append(contentsOf: "\(lines[start].number) \(end - start)\n".utf8)
            for line in lines[start..<end] { output.append(contentsOf: line.text.utf8) }
            start = end
        }
    }

    /// A cross-reference stream, which carries the trailer's entries in its dictionary.
    static func stream(entries: [(id: ObjectID, offset: Int)], trailer: PDFDictionary) -> PDFStream {
        let offsetWidth = (entries.map(\.offset).max() ?? 0) > 0xFFFF_FFFF ? 8 : 4
        var rows = Data()
        var index: [PDFObject] = []
        var start = 0
        let sorted = entries.sorted { $0.id.number < $1.id.number }
        while start < sorted.count {
            var end = start + 1
            while end < sorted.count, sorted[end].id.number == sorted[end - 1].id.number + 1 { end += 1 }
            index.append(.integer(sorted[start].id.number))
            index.append(.integer(end - start))
            for entry in sorted[start..<end] {
                rows.append(1)
                for shift in stride(from: (offsetWidth - 1) * 8, through: 0, by: -8) { rows.append(UInt8(entry.offset >> shift & 0xFF)) }
                rows.append(UInt8(entry.id.generation >> 8 & 0xFF))
                rows.append(UInt8(entry.id.generation & 0xFF))
            }
            start = end
        }
        var dictionary = trailer
        dictionary["Type"] = .name("XRef")
        dictionary["W"] = [1, .integer(offsetWidth), 2]
        dictionary["Index"] = .array(index)
        dictionary["Filter"] = .name("FlateDecode")
        return PDFStream(dictionary: dictionary, data: Flate.deflate(rows))
    }
}

extension CrossReferenceWriter {
    /// Where an object is, for a cross-reference stream that lists every object.
    enum Entry {
        case free
        case direct(offset: Int)
        /// Inside an object stream, at a position among its objects.
        case packed(stream: Int, index: Int)
    }

    /// A cross-reference stream covering objects zero through `entries.count - 1`.
    static func stream(listing entries: [Entry], trailer: PDFDictionary) -> PDFStream {
        let largest = entries.map { entry -> Int in
            switch entry {
            case .free: 0
            case .direct(let offset): offset
            case .packed(let stream, _): stream
            }
        }.max() ?? 0
        let width = largest > 0xFFFF_FFFF ? 8 : largest > 0xFF_FFFF ? 4 : 3
        var rows = Data(capacity: entries.count * (width + 3))
        func row(_ type: UInt8, _ middle: Int, _ last: Int) {
            rows.append(type)
            for shift in stride(from: (width - 1) * 8, through: 0, by: -8) { rows.append(UInt8(middle >> shift & 0xFF)) }
            rows.append(UInt8(last >> 8 & 0xFF))
            rows.append(UInt8(last & 0xFF))
        }
        for entry in entries {
            switch entry {
            case .free: row(0, 0, 65535)
            case .direct(let offset): row(1, offset, 0)
            case .packed(let stream, let index): row(2, stream, index)
            }
        }
        var dictionary = trailer
        dictionary["Type"] = .name("XRef")
        dictionary["W"] = [1, .integer(width), 2]
        dictionary["Size"] = .integer(entries.count)
        dictionary["Filter"] = .name("FlateDecode")
        return PDFStream(dictionary: dictionary, data: Flate.deflate(rows))
    }
}

// MARK: - Writing afresh

struct FullWriter {
    let editor: PDFEditor
    let protection: Protection
    var options = WriteOptions()

    /// How many objects go into one object stream.
    private static let packSize = 200

    func data() throws -> Data {
        let base = editor.base
        var trailer: PDFDictionary = [:]
        var output = Data()

        // The identifier's first half is kept, since an existing encryption key depends on it.
        let identifier = FileID.updated(editor.trailer["ID"], changing: Data("\(base.data.count)-\(editor.changedNumbers)".utf8))
        let documentID = identifier.arrayValue?.first?.stringValue ?? Data()

        let handler: SecurityHandler?
        var encryptDictionary: PDFDictionary?
        // The header version is kept as it is unless new encryption needs a later one.
        // Apple's renderer treats transparency differently in files that claim to be older
        // than PDF 1.4, so raising the version for no reason would change how pages look.
        var minimumVersion = (0, 0)
        var needsExtension = false
        switch protection {
        case .keep:
            handler = base.security
            encryptDictionary = base.encryptDictionary
        case .none:
            handler = nil
        case .password(let user, let owner, let permissions, let algorithm):
            let made = try SecurityHandler.make(
                userPassword: user, ownerPassword: owner, permissions: permissions, algorithm: algorithm, documentID: documentID
            )
            handler = made.handler
            encryptDictionary = made.dictionary
            switch algorithm {
            case .aes256:
                minimumVersion = (1, 7)
                needsExtension = true
            case .aes128: minimumVersion = (1, 6)
            case .rc4: minimumVersion = (1, 4)
            }
        }

        let current = (base.version.major, base.version.minor)
        var version = current < minimumVersion ? minimumVersion : current
        // Packing arrived with PDF 1.5. A file from before 1.4 keeps the version it claims
        // even so: raising it would change how Apple's renderer draws its pages, and every
        // reader goes by what it finds in the file, not by the number at the top.
        let packs = options.packsObjects
        if packs, version >= (1, 4), version < (1, 5) { version = (1, 5) }
        output.append(contentsOf: "%PDF-\(version.0).\(version.1)\n%".utf8)
        output.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        // Walk everything reachable from the trailer, numbering objects in the order found
        // and writing each one as soon as it is read.
        var numbering: [Int: Int] = [:]
        var queue: [Int] = []
        var nextIndex = 0
        var digests: [Data: Int] = [:]
        func number(for id: ObjectID) throws -> Int? {
            if let existing = numbering[id.number] { return existing }
            // References to objects that do not exist read as null and are written as null.
            if editor.changes[id.number] == nil, !base.defines(id.number) { return nil }
            if options.mergesDuplicates,
               case .stream(let stream)? = try? editor.changes[id.number] ?? base.uncachedObject(id.number),
               stream.data.count >= 32, !PDFObject.dictionary(stream.dictionary).containsReference {
                // A stream that refers to nothing else is the same wherever it is used.
                let digest = Hash.sha256(Serializer.data(.dictionary(stream.dictionary)) + stream.data)
                if let existing = digests[digest] {
                    numbering[id.number] = existing
                    return existing
                }
                digests[digest] = queue.count + 1
            }
            let new = queue.count + 1
            numbering[id.number] = new
            queue.append(id.number)
            return new
        }
        func renumbered(_ object: PDFObject) throws -> PDFObject {
            switch object {
            case .reference(let id):
                return try number(for: id).map { .reference(ObjectID($0)) } ?? .null
            case .array(let elements):
                return .array(try elements.map(renumbered))
            case .dictionary(let dictionary):
                // In key order, so the same document is always numbered the same way.
                var result: PDFDictionary = [:]
                for key in dictionary.keys.sorted() {
                    let mapped = try renumbered(dictionary[key] ?? .null)
                    if !mapped.isNull { result[key] = mapped }
                }
                return .dictionary(result)
            case .stream(var stream):
                stream.dictionary = try renumbered(.dictionary(stream.dictionary)).dictionaryValue ?? [:]
                return .stream(stream)
            default:
                return object
            }
        }

        let rootID = editor.trailer["Root"]?.referenceValue
        for key in ["Root", "Info"] as [PDFName] {
            if let entry = editor.trailer[key] { trailer[key] = try renumbered(entry) }
        }
        guard trailer["Root"] != nil else { throw SheafError.malformed("document has no catalog") }

        var offsets: [(id: ObjectID, offset: Int)] = []
        // When packing: the objects waiting to go into the next object stream, and the
        // streams already filled.
        var pack: [(number: Int, data: Data)] = []
        var filled: [[(number: Int, data: Data)]] = []
        while nextIndex < queue.count {
            let oldNumber = queue[nextIndex]
            nextIndex += 1
            var object = try renumbered(editor.changes[oldNumber] ?? base.uncachedObject(oldNumber))
            if needsExtension, oldNumber == rootID?.number, case .dictionary(var catalog) = object {
                // AES-256 came after PDF 1.7, and is declared as an extension to it.
                catalog["Extensions"] = ["ADBE": ["BaseVersion": .name("1.7"), "ExtensionLevel": 8]]
                object = .dictionary(catalog)
            }
            let id = ObjectID(nextIndex)
            // Apple's reader needs the catalog before a protected file is unlocked, so there
            // it stays outside the object streams, which are encrypted whole.
            let staysOutside = handler != nil && oldNumber == rootID?.number
            if packs, object.streamValue == nil, !staysOutside {
                // Objects in an object stream are not encrypted one by one; the stream is.
                pack.append((id.number, Serializer.data(object)))
                if pack.count == Self.packSize {
                    filled.append(pack)
                    pack = []
                }
                continue
            }
            offsets.append((id, output.count))
            Serializer.append(indirect: object, id: id, to: &output, cipher: Cipher.make(handler, id: id, object: object))
        }
        if !pack.isEmpty { filled.append(pack) }

        var nextNumber = queue.count + 1
        var entries = [CrossReferenceWriter.Entry](repeating: .free, count: nextNumber)
        for (id, offset) in offsets { entries[id.number] = .direct(offset: offset) }
        func appendDirect(_ object: PDFObject, cipher: Bool) -> ObjectID {
            let id = ObjectID(nextNumber)
            nextNumber += 1
            offsets.append((id, output.count))
            entries.append(.direct(offset: output.count))
            Serializer.append(indirect: object, id: id, to: &output, cipher: cipher ? Cipher.make(handler, id: id, object: object) : nil)
            return id
        }

        for members in filled {
            var header = "", body = Data()
            for member in members {
                header += "\(member.number) \(body.count) "
                body.append(member.data)
                body.append(0x0A)
            }
            let stream = PDFStream(
                dictionary: ["Type": .name("ObjStm"), "N": .integer(members.count), "First": .integer(header.utf8.count), "Filter": .name("FlateDecode")],
                data: Flate.deflate(Data(header.utf8) + body)
            )
            let id = appendDirect(.stream(stream), cipher: true)
            for (index, member) in members.enumerated() { entries[member.number] = .packed(stream: id.number, index: index) }
        }

        if let encryptDictionary {
            // The encryption dictionary is the one object that is never itself encrypted.
            trailer["Encrypt"] = .reference(appendDirect(.dictionary(encryptDictionary), cipher: false))
        }

        trailer["ID"] = identifier
        let sectionOffset = output.count
        if packs {
            // A file with packed objects is indexed by a stream, which lists itself too.
            entries.append(.direct(offset: sectionOffset))
            let stream = CrossReferenceWriter.stream(listing: entries, trailer: trailer)
            Serializer.append(indirect: .stream(stream), id: ObjectID(nextNumber), to: &output)
        } else {
            trailer["Size"] = .integer(offsets.count + 1)
            CrossReferenceWriter.appendTable(entries: offsets, includeFreeHead: true, to: &output)
            output.append(contentsOf: "trailer\n".utf8)
            Serializer.append(.dictionary(trailer), to: &output)
            output.append(0x0A)
        }
        output.append(contentsOf: "startxref\n\(sectionOffset)\n%%EOF\n".utf8)
        return output
    }
}
