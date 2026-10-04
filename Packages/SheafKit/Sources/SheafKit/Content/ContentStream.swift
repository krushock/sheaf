import Foundation

/// A page's drawing instructions as a list of operations.
///
/// Reading and writing back an untouched content stream gives the same bytes. Operations
/// that are not changed keep their original bytes, spacing and comments included, so an
/// edit only alters the part of the page it is about.
public struct ContentStream: Sendable, Equatable {
    public struct Operation: Sendable, Equatable {
        /// The operator, such as `Tj`, `cm` or `re`.
        public var name: String {
            didSet { source = nil }
        }

        public var operands: [PDFObject] {
            didSet { source = nil }
        }

        /// The pixels of an inline image, for the `BI` operation. Its dictionary is `operands[0]`.
        public var inlineImageData: Data? {
            didSet { source = nil }
        }

        /// Where the operation's bytes are in the stream it was read from.
        fileprivate var source: Range<Int>?

        public init(_ name: String, _ operands: [PDFObject] = [], inlineImageData: Data? = nil) {
            self.name = name
            self.operands = operands
            self.inlineImageData = inlineImageData
        }

        public static func == (a: Operation, b: Operation) -> Bool {
            a.name == b.name && a.operands == b.operands && a.inlineImageData == b.inlineImageData
        }
    }

    public var operations: [Operation] = []
    private var original = Data()
    /// Bytes after the last complete operation: trailing space, or something unreadable.
    private var remainder: Range<Int> = 0..<0

    /// Two content streams are equal when they hold the same operations, whatever their spacing.
    public static func == (a: ContentStream, b: ContentStream) -> Bool {
        a.operations == b.operations && a.original[a.remainder] == b.original[b.remainder]
    }

    public init(operations: [Operation] = []) {
        self.operations = operations
    }

    /// Reads a decoded content stream. Never fails: whatever cannot be understood is kept
    /// as it is and written back unchanged.
    public init(data: Data) {
        let data = data.startIndex == 0 ? data : Data(data)
        original = data
        var operations: [Operation] = []
        let consumed = data.parse { parser -> Int in
            parser.allowsReferences = false
            var operands: [PDFObject] = []
            var operationStart = 0
            while true {
                parser.skipWhitespace()
                guard let next = parser.current else { break }
                switch next {
                case 0x2F, 0x28, 0x3C, 0x5B, 0x30...0x39, 0x2B, 0x2D, 0x2E: // name, strings, array, number
                    guard let operand = try? parser.parseObject() else { return operationStart }
                    operands.append(operand)
                case 0x5D, 0x3E, 0x29, 0x7B, 0x7D: // a closing bracket with nothing open
                    parser.position += 1
                default:
                    let word = parser.readWord()
                    switch word {
                    case "": parser.position += 1
                    case "true": operands.append(true)
                    case "false": operands.append(false)
                    case "null": operands.append(nil)
                    case "BI":
                        guard var image = Self.readInlineImage(&parser) else { return operationStart }
                        image.source = operationStart..<parser.position
                        operations.append(image)
                        operands = []
                        operationStart = parser.position
                    default:
                        var operation = Operation(word, operands)
                        operation.source = operationStart..<parser.position
                        operations.append(operation)
                        operands = []
                        operationStart = parser.position
                    }
                }
            }
            return operationStart
        }
        self.operations = operations
        remainder = consumed..<data.count
    }

    /// Reads from just after `BI` to just after `EI`.
    private static func readInlineImage(_ parser: inout Parser) -> Operation? {
        var dictionary: PDFDictionary = [:]
        while true {
            parser.skipWhitespace()
            if parser.consume("ID") { break }
            guard parser.current == 0x2F else { return nil }
            let key = parser.parseName()
            guard let value = try? parser.parseObject() else { return nil }
            dictionary[key] = value
        }
        // One whitespace character separates the keyword from the data.
        if parser.current == 0x0D, parser.byte(at: parser.position + 1) == 0x0A { parser.position += 1 }
        if let separator = parser.current, isPDFWhitespace(separator) { parser.position += 1 }
        let start = parser.position

        // The data has no length, so look for an "EI" that stands alone and is followed by
        // something that reads like more instructions rather than more pixels.
        var search = start
        while let found = parser.find("EI", from: search) {
            search = found + 1
            let before = found > start ? parser.byte(at: found - 1) : 0x20
            let after = parser.byte(at: found + 2)
            guard let before, isPDFWhitespace(before), after.map(isPDFWhitespace) ?? true else { continue }
            let lookahead = (found + 2..<min(found + 22, parser.bytes.count)).allSatisfy {
                let value = parser.bytes[$0]
                return value < 0x80 && (value >= 0x20 || isPDFWhitespace(value))
            }
            guard lookahead else { continue }
            let end = found > start ? found - 1 : found
            parser.position = found + 2
            return Operation("BI", [.dictionary(dictionary)], inlineImageData: parser.slice(start..<max(end, start)))
        }
        return nil
    }

    /// Operations read from text, free of the text they were read from, so they can be
    /// put into another stream.
    static func operations(parsing text: String) -> [Operation] {
        ContentStream(data: Data(text.utf8)).operations.map { Operation($0.name, $0.operands, inlineImageData: $0.inlineImageData) }
    }

    /// Whether the end of the stream could not be read as operations. Such a tail is still
    /// written back unchanged.
    public var hasUnreadableTail: Bool {
        original[remainder].contains { !isPDFWhitespace($0) }
    }

    /// The stream's bytes: original bytes for untouched operations, fresh ones for the rest.
    public func data() -> Data {
        var output = Data()
        for operation in operations {
            if let source = operation.source {
                // Original bytes normally start with the space that separated them from what
                // came before. After a reorder or an insertion they may not.
                if let last = output.last, let first = original[source].first, isPDFRegular(last), isPDFRegular(first) {
                    output.append(0x0A)
                }
                output.append(original[source])
                continue
            }
            if !output.isEmpty { output.append(0x0A) }
            if operation.name == "BI" {
                output.append(contentsOf: "BI".utf8)
                let dictionary = operation.operands.first?.dictionaryValue ?? [:]
                for key in dictionary.keys.sorted() {
                    output.append(0x20)
                    Serializer.append(.name(key), to: &output)
                    output.append(0x20)
                    Serializer.append(dictionary[key] ?? .null, to: &output)
                }
                output.append(contentsOf: " ID\n".utf8)
                output.append(operation.inlineImageData ?? Data())
                output.append(contentsOf: "\nEI".utf8)
                continue
            }
            for operand in operation.operands {
                Serializer.append(operand, to: &output)
                output.append(0x20)
            }
            output.append(contentsOf: operation.name.utf8)
        }
        if !remainder.isEmpty {
            if operations.last?.source == nil, !output.isEmpty { output.append(0x0A) }
            output.append(original[remainder])
        }
        return output
    }
}

extension ObjectSource {
    /// A page's content, with all its streams decoded and joined.
    public func contentStream(forPage id: ObjectID) throws -> ContentStream {
        guard let page = try object(id).dictionaryValue else { throw SheafError.malformed("page is not a dictionary") }
        let contents = try value("Contents", in: page)
        let parts: [PDFObject] = contents.arrayValue ?? [contents]
        var joined = Data()
        for part in parts {
            guard let stream = try resolve(part).streamValue else { continue }
            // Instructions may not straddle streams, so a line break between them is safe.
            if !joined.isEmpty { joined.append(0x0A) }
            joined.append(try decodedData(of: stream))
        }
        return ContentStream(data: joined)
    }
}

extension PDFEditor {
    public func contentStream(forPageAt index: Int) throws -> ContentStream {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        return try contentStream(forPage: pages[index])
    }

    /// Replaces a page's content. The page gets one new stream of its own, so other pages
    /// that shared the old content are not affected.
    public mutating func setContentStream(_ content: ContentStream, forPageAt index: Int) throws {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        let stream = PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(content.data()))
        let id = add(.stream(stream))
        try update(pages[index]) { $0["Contents"] = .reference(id) }
    }
}
