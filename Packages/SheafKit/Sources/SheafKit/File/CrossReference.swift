import Foundation

/// Where one object lives.
enum CrossReferenceEntry: Equatable, Sendable {
    case free
    /// At a byte offset, counted from the `%PDF` header.
    case inUse(offset: Int, generation: Int)
    /// Inside an object stream, at a position in its list.
    case compressed(stream: Int, index: Int)
}

/// The table that maps object numbers to locations, gathered from every section of a file.
struct CrossReference: Sendable {
    var entries: [Int: CrossReferenceEntry] = [:]
    var trailer: PDFDictionary = [:]
    /// Offset of the newest section, which an incremental update must point back to.
    var newestSectionOffset: Int?
    /// Whether the newest section is a cross-reference stream rather than a classic table.
    var newestSectionIsStream = false
    /// True when the table in the file was unusable and this one came from scanning for objects.
    var wasRebuilt = false

    /// One past the highest object number in use.
    var nextObjectNumber: Int {
        max(trailer["Size"]?.intValue ?? 0, (entries.keys.max() ?? 0) + 1)
    }

    // MARK: Reading the table in the file

    /// - Parameter headerOffset: Where `%PDF` is, for files with junk before the header.
    static func read(from data: Data, headerOffset: Int) throws -> CrossReference {
        var table = CrossReference()
        guard let start = data.parse({ parser -> Int? in
            guard let keyword = parser.findLast("startxref", after: max(parser.bytes.count - 4096, 0)) else { return nil }
            parser.position = keyword + 9
            parser.skipWhitespace()
            return parser.readUnsignedInteger()
        }) else { throw SheafError.malformed("no startxref") }

        table.newestSectionOffset = start
        var next: Int? = start
        var visited: Set<Int> = []
        var isNewest = true
        while let offset = next, visited.insert(offset).inserted {
            next = try data.parse(at: offset + headerOffset) { parser -> Int? in
                parser.skipWhitespace()
                if parser.hasKeyword("xref", at: parser.position) {
                    let trailer = try table.readClassicSection(&parser)
                    if isNewest { table.trailer = trailer }
                    // A hybrid file keeps extra entries in a stream alongside the classic table.
                    if let streamOffset = trailer["XRefStm"]?.intValue {
                        parser.position = streamOffset + headerOffset
                        _ = try? table.readStreamSection(&parser)
                    }
                    return trailer["Prev"]?.intValue
                }
                let dictionary = try table.readStreamSection(&parser)
                if isNewest {
                    table.trailer = dictionary
                    table.newestSectionIsStream = true
                }
                return dictionary["Prev"]?.intValue
            }
            isNewest = false
        }
        guard table.trailer["Root"] != nil else { throw SheafError.malformed("trailer has no Root") }
        return table
    }

    /// Far above what any real file uses, and low enough that arithmetic on it cannot overflow.
    static let maximumObjectNumber = 100_000_000

    private mutating func record(_ entry: CrossReferenceEntry, for number: Int) {
        guard number >= 0, number <= Self.maximumObjectNumber else { return }
        // Sections are read newest first, so the first entry seen for a number wins.
        if entries[number] == nil { entries[number] = entry }
    }

    private mutating func readClassicSection(_ parser: inout Parser) throws -> PDFDictionary {
        guard parser.consume("xref") else { throw parser.failure("expected 'xref'") }
        while true {
            parser.skipWhitespace()
            if parser.consume("trailer") { break }
            guard var first = parser.readUnsignedInteger() else { throw parser.failure("bad cross-reference subsection") }
            parser.skipWhitespace()
            guard let count = parser.readUnsignedInteger(), first <= Self.maximumObjectNumber, count <= Self.maximumObjectNumber
            else { throw parser.failure("bad cross-reference subsection") }
            for index in 0..<count {
                parser.skipWhitespace()
                guard let offset = parser.readUnsignedInteger() else { throw parser.failure("bad cross-reference entry") }
                parser.skipWhitespace()
                guard let generation = parser.readUnsignedInteger() else { throw parser.failure("bad cross-reference entry") }
                parser.skipWhitespace()
                guard let kind = parser.current, kind == 0x6E || kind == 0x66 else { // n or f
                    throw parser.failure("bad cross-reference entry")
                }
                parser.position += 1
                // Some writers number the free-list head as 1 instead of 0.
                if index == 0, first == 1, kind == 0x66, generation == 65535 { first = 0 }
                let isUsable = kind == 0x6E && offset > 0
                record(isUsable ? .inUse(offset: offset, generation: generation) : .free, for: first + index)
            }
        }
        guard let trailer = try parser.parseObject().dictionaryValue else { throw parser.failure("trailer is not a dictionary") }
        return trailer
    }

    private mutating func readStreamSection(_ parser: inout Parser) throws -> PDFDictionary {
        let (_, object) = try parser.parseIndirectObject(resolveLength: { _ in nil })
        guard let stream = object.streamValue, stream.dictionary["Type"]?.nameValue == "XRef" else {
            throw parser.failure("expected a cross-reference stream")
        }
        let dictionary = stream.dictionary
        guard let widths = dictionary["W"]?.arrayValue?.compactMap(\.intValue), widths.count >= 3,
              widths.allSatisfy({ $0 >= 0 && $0 <= 8 })
        else { throw parser.failure("cross-reference stream has no field widths") }
        let bytes = [UInt8](try StreamFilters.decode(stream))
        let size = dictionary["Size"]?.intValue ?? 0
        let ranges = dictionary["Index"]?.arrayValue?.compactMap(\.intValue) ?? [0, size]
        let rowLength = widths[0] + widths[1] + widths[2]
        guard rowLength > 0 else { return dictionary }

        var position = 0
        func field(_ width: Int) -> Int {
            var value = 0
            for _ in 0..<width {
                value = value << 8 | Int(bytes[position])
                position += 1
            }
            return value
        }
        var rangeIndex = 0
        while rangeIndex + 1 < ranges.count {
            let first = ranges[rangeIndex], count = ranges[rangeIndex + 1]
            rangeIndex += 2
            guard first >= 0, first <= Self.maximumObjectNumber, count <= Self.maximumObjectNumber else { return dictionary }
            for index in 0..<max(count, 0) {
                guard position + rowLength <= bytes.count else { return dictionary }
                let kind = widths[0] == 0 ? 1 : field(widths[0])
                let second = field(widths[1])
                let third = field(widths[2])
                switch kind {
                case 0: record(.free, for: first + index)
                case 1: record(second > 0 ? .inUse(offset: second, generation: third) : .free, for: first + index)
                case 2: record(.compressed(stream: second, index: third), for: first + index)
                default: break // unknown types are to be ignored
                }
            }
        }
        return dictionary
    }

    // MARK: Rebuilding from the objects themselves

    /// Finds every `12 0 obj` in the file. Used when the table is missing or wrong.
    static func rebuild(from data: Data) throws -> CrossReference {
        var table = CrossReference()
        table.wasRebuilt = true

        data.parse { parser in
            let bytes = parser.bytes
            var searchFrom = 0
            while let found = parser.find("obj", from: searchFrom) {
                searchFrom = found + 3
                guard parser.hasKeyword("obj", at: found), found > 0, isPDFWhitespace(bytes[found - 1]) else { continue }
                // Walk backwards over "<number> <generation> ".
                var index = found - 1
                while index >= 0, isPDFWhitespace(bytes[index]) { index -= 1 }
                let generationEnd = index
                while index >= 0, bytes[index] >= 0x30, bytes[index] <= 0x39 { index -= 1 }
                guard index < generationEnd, index >= 0, isPDFWhitespace(bytes[index]) else { continue }
                let generationStart = index + 1
                while index >= 0, isPDFWhitespace(bytes[index]) { index -= 1 }
                let numberEnd = index
                while index >= 0, bytes[index] >= 0x30, bytes[index] <= 0x39 { index -= 1 }
                guard index < numberEnd, index < 0 || !isPDFRegular(bytes[index]) else { continue }
                func value(_ range: ClosedRange<Int>) -> Int? {
                    Int(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self))
                }
                guard let number = value(index + 1...numberEnd), let generation = value(generationStart...generationEnd),
                      number <= maximumObjectNumber
                else { continue }
                // Later copies of an object replace earlier ones, as in an updated file.
                table.entries[number] = .inUse(offset: index + 1, generation: generation)
            }

            var trailerSearch = 0
            while let found = parser.find("trailer", from: trailerSearch) {
                trailerSearch = found + 7
                parser.position = found + 7
                if let dictionary = (try? parser.parseObject())?.dictionaryValue {
                    table.trailer.merge(dictionary) { _, newer in newer }
                }
            }
        }

        // Look inside the objects for what a trailer would have said, and for objects
        // that only exist inside object streams.
        var catalog: ObjectID?
        for (number, entry) in table.entries.sorted(by: { $0.key < $1.key }) {
            guard case .inUse(let offset, let generation) = entry else { continue }
            guard let object = try? data.parse(at: offset, { try $0.parseIndirectObject(resolveLength: { _ in nil }).object }),
                  let dictionary = object.dictionaryValue
            else { continue }
            switch dictionary["Type"]?.nameValue {
            case "Catalog":
                catalog = ObjectID(number, generation)
            case "XRef":
                for key in ["Root", "Info", "Encrypt", "ID"] as [PDFName] where table.trailer[key] == nil {
                    table.trailer[key] = dictionary[key]
                }
            case "ObjStm":
                guard let stream = object.streamValue, let contents = try? ObjectStream(stream) else { continue }
                for (index, member) in contents.members.enumerated() where table.entries[member.number] == nil {
                    table.entries[member.number] = .compressed(stream: number, index: index)
                }
            default:
                break
            }
        }
        if table.trailer["Root"] == nil, let catalog { table.trailer["Root"] = .reference(catalog) }
        guard table.trailer["Root"] != nil, !table.entries.isEmpty else { throw SheafError.notAPDF }
        table.trailer["Prev"] = nil
        table.trailer["XRefStm"] = nil
        return table
    }
}

/// The decoded contents of an object stream: many small objects packed into one stream.
struct ObjectStream {
    let data: Data
    let members: [(number: Int, offset: Int)]

    init(_ stream: PDFStream, resolve: (PDFObject) throws -> PDFObject = { $0 }) throws {
        let dictionary = stream.dictionary
        guard let count = try resolve(dictionary["N"] ?? .null).intValue,
              let first = try resolve(dictionary["First"] ?? .null).intValue, count >= 0, first >= 0
        else { throw SheafError.malformed("object stream has no index") }
        let decoded = try StreamFilters.decode(stream, resolve: resolve)
        data = decoded
        members = decoded.parse { parser in
            var members: [(Int, Int)] = []
            for _ in 0..<count {
                parser.skipWhitespace()
                guard let number = parser.readUnsignedInteger() else { break }
                parser.skipWhitespace()
                guard let offset = parser.readUnsignedInteger(), offset <= decoded.count else { break }
                members.append((number, first + offset))
            }
            return members
        }
    }

    func object(at index: Int) throws -> PDFObject {
        guard members.indices.contains(index) else { return .null }
        return try data.parse(at: members[index].offset) { try $0.parseObject() }
    }
}
