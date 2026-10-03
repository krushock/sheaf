import Foundation

@inline(__always) func isPDFWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
}

@inline(__always) func isPDFDelimiter(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: true // ( ) < > [ ] { } / %
    default: false
    }
}

@inline(__always) func isPDFRegular(_ byte: UInt8) -> Bool {
    !isPDFWhitespace(byte) && !isPDFDelimiter(byte)
}

/// Reads PDF syntax from a byte buffer.
///
/// The buffer pointer is only valid inside the `withUnsafeBytes` call that created the
/// parser, so parsers are made, used and dropped within one such call. See `Data.parse`.
struct Parser {
    /// The same bytes as `bytes`, held so that stream data can be returned as slices
    /// that share storage instead of copies.
    let source: Data
    let bytes: UnsafeRawBufferPointer
    var position: Int
    /// Off inside content streams, where `1 0 R` is three tokens and never a reference.
    var allowsReferences = true

    static let maximumDepth = 200

    var isAtEnd: Bool { position >= bytes.count }

    @inline(__always) func byte(at index: Int) -> UInt8? {
        index >= 0 && index < bytes.count ? bytes[index] : nil
    }

    @inline(__always) var current: UInt8? { byte(at: position) }

    /// Skips whitespace and comments.
    mutating func skipWhitespace() {
        while position < bytes.count {
            let value = bytes[position]
            if isPDFWhitespace(value) {
                position += 1
            } else if value == 0x25 { // %
                while position < bytes.count, bytes[position] != 0x0A, bytes[position] != 0x0D { position += 1 }
            } else {
                return
            }
        }
    }

    /// Whether `keyword` is at `index` and is not just the start of a longer word.
    func hasKeyword(_ keyword: StaticString, at index: Int) -> Bool {
        let count = keyword.utf8CodeUnitCount
        guard index >= 0, index + count <= bytes.count else { return false }
        guard memcmp(bytes.baseAddress! + index, keyword.utf8Start, count) == 0 else { return false }
        if let next = byte(at: index + count) { return !isPDFRegular(next) }
        return true
    }

    mutating func consume(_ keyword: StaticString) -> Bool {
        guard hasKeyword(keyword, at: position) else { return false }
        position += keyword.utf8CodeUnitCount
        return true
    }

    /// The offset of the next occurrence of `pattern` at or after `start`.
    func find(_ pattern: StaticString, from start: Int) -> Int? {
        guard start >= 0, start < bytes.count else { return nil }
        guard let found = memmem(bytes.baseAddress! + start, bytes.count - start, pattern.utf8Start, pattern.utf8CodeUnitCount)
        else { return nil }
        return bytes.baseAddress!.distance(to: UnsafeRawPointer(found))
    }

    /// The offset of the last occurrence of `pattern` that starts at or after `lowerBound`.
    func findLast(_ pattern: StaticString, after lowerBound: Int = 0) -> Int? {
        let count = pattern.utf8CodeUnitCount
        var index = bytes.count - count
        while index >= max(lowerBound, 0) {
            if memcmp(bytes.baseAddress! + index, pattern.utf8Start, count) == 0 { return index }
            index -= 1
        }
        return nil
    }

    mutating func readUnsignedInteger() -> Int? {
        let start = position
        var value = 0
        while position < bytes.count, bytes[position] >= 0x30, bytes[position] <= 0x39 {
            let (product, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = product.addingReportingOverflow(Int(bytes[position] - 0x30))
            guard !overflow1, !overflow2 else { position = start; return nil }
            value = sum
            position += 1
        }
        return position > start ? value : nil
    }

    /// A run of regular characters, such as a keyword or a content stream operator.
    mutating func readWord() -> String {
        let start = position
        while position < bytes.count, isPDFRegular(bytes[position]) { position += 1 }
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
    }

    func slice(_ range: Range<Int>) -> Data {
        source[(source.startIndex + range.lowerBound)..<(source.startIndex + range.upperBound)]
    }

    func failure(_ reason: String) -> SheafError {
        .malformed("\(reason) at byte \(position)")
    }

    // MARK: Objects

    mutating func parseObject(depth: Int = 0) throws -> PDFObject {
        guard depth < Self.maximumDepth else { throw failure("objects nested too deeply") }
        skipWhitespace()
        guard let first = current else { throw failure("unexpected end of data") }
        switch first {
        case 0x2F: // /
            return .name(parseName())
        case 0x28: // (
            return .string(parseLiteralString())
        case 0x3C: // <
            if byte(at: position + 1) == 0x3C { return .dictionary(try parseDictionary(depth: depth)) }
            return .string(parseHexString())
        case 0x5B: // [
            position += 1
            var elements: [PDFObject] = []
            while true {
                skipWhitespace()
                guard let next = current else { throw failure("array is not closed") }
                if next == 0x5D { position += 1; break }
                elements.append(try parseObject(depth: depth + 1))
            }
            return .array(elements)
        case 0x30...0x39, 0x2B, 0x2D, 0x2E: // digit + - .
            return parseNumberOrReference()
        default:
            let start = position
            let word = readWord()
            switch word {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "null": return .null
            default:
                position = start
                throw failure(word.isEmpty ? "unexpected character" : "unexpected keyword '\(word)'")
            }
        }
    }

    mutating func parseName() -> PDFName {
        position += 1 // the slash
        var name: [UInt8] = []
        while position < bytes.count, isPDFRegular(bytes[position]) {
            let value = bytes[position]
            if value == 0x23, let high = hexValue(byte(at: position + 1)), let low = hexValue(byte(at: position + 2)) {
                name.append(high << 4 | low)
                position += 3
            } else {
                name.append(value)
                position += 1
            }
        }
        return PDFName(bytes: name)
    }

    private func hexValue(_ byte: UInt8?) -> UInt8? {
        guard let byte else { return nil }
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    mutating func parseLiteralString() -> Data {
        position += 1 // the opening parenthesis
        var result = Data()
        var depth = 1
        while position < bytes.count {
            let value = bytes[position]
            position += 1
            switch value {
            case 0x5C: // backslash
                guard let escaped = current else { return result }
                position += 1
                switch escaped {
                case 0x6E: result.append(0x0A) // n
                case 0x72: result.append(0x0D) // r
                case 0x74: result.append(0x09) // t
                case 0x62: result.append(0x08) // b
                case 0x66: result.append(0x0C) // f
                case 0x0D: if current == 0x0A { position += 1 } // line continuation
                case 0x0A: break
                case 0x30...0x37:
                    var code = Int(escaped - 0x30)
                    var digits = 1
                    while digits < 3, let next = current, next >= 0x30, next <= 0x37 {
                        code = code * 8 + Int(next - 0x30)
                        position += 1
                        digits += 1
                    }
                    result.append(UInt8(truncatingIfNeeded: code))
                default: result.append(escaped)
                }
            case 0x28:
                depth += 1
                result.append(value)
            case 0x29:
                depth -= 1
                if depth == 0 { return result }
                result.append(value)
            case 0x0D: // an end of line inside a string reads as a single line feed
                if current == 0x0A { position += 1 }
                result.append(0x0A)
            default:
                result.append(value)
            }
        }
        return result
    }

    mutating func parseHexString() -> Data {
        position += 1 // <
        var result = Data()
        var pending: UInt8?
        while position < bytes.count {
            let value = bytes[position]
            position += 1
            if value == 0x3E { break }
            guard let digit = hexValue(value) else { continue }
            if let high = pending {
                result.append(high << 4 | digit)
                pending = nil
            } else {
                pending = digit
            }
        }
        if let high = pending { result.append(high << 4) }
        return result
    }

    mutating func parseDictionary(depth: Int) throws -> PDFDictionary {
        position += 2 // <<
        var dictionary: PDFDictionary = [:]
        while true {
            skipWhitespace()
            guard let next = current else { throw failure("dictionary is not closed") }
            if next == 0x3E, byte(at: position + 1) == 0x3E {
                position += 2
                return dictionary
            }
            guard next == 0x2F else {
                // Something that is not a key. Step over one stray token and carry on.
                let stray = position
                if (try? parseObject(depth: depth + 1)) == nil {
                    position = stray
                    if readWord().isEmpty { throw failure("dictionary key is not a name") }
                }
                continue
            }
            let key = parseName()
            skipWhitespace()
            // A key with no value before the closing brackets reads as null.
            if current == 0x3E, byte(at: position + 1) == 0x3E { continue }
            let value = try parseObject(depth: depth + 1)
            if value != .null { dictionary[key] = value }
        }
    }

    private mutating func parseNumberOrReference() -> PDFObject {
        let start = position
        var isPlainInteger = true
        while position < bytes.count {
            let value = bytes[position]
            if value >= 0x30, value <= 0x39 {
                position += 1
            } else if value == 0x2B || value == 0x2D || value == 0x2E {
                isPlainInteger = false
                position += 1
            } else {
                break
            }
        }
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)

        if isPlainInteger, let number = Int(text) {
            if allowsReferences {
                let afterNumber = position
                skipWhitespace()
                if let generation = readUnsignedInteger() {
                    skipWhitespace()
                    if current == 0x52, byte(at: position + 1).map({ !isPDFRegular($0) }) ?? true { // R
                        position += 1
                        return .reference(ObjectID(number, generation))
                    }
                }
                position = afterNumber
            }
            return .integer(number)
        }
        if let number = Int(text) { return .integer(number) }
        if isPlainInteger, allowsReferences {
            // Too large for an integer. As an object number it can only point at nothing.
            let afterNumber = position
            skipWhitespace()
            if readUnsignedInteger() != nil {
                skipWhitespace()
                if current == 0x52, byte(at: position + 1).map({ !isPDFRegular($0) }) ?? true {
                    position += 1
                    return .null
                }
            }
            position = afterNumber
        }
        if let number = Double(text), number.isFinite { return .real(number) }
        // Tolerate junk such as "1.2.3" or "--5" by reading the longest sensible prefix.
        var prefix = text
        while !prefix.isEmpty {
            prefix.removeLast()
            if let number = Double(prefix), number.isFinite { return .real(number) }
        }
        return .integer(0)
    }

    // MARK: Indirect objects

    /// Parses `12 0 obj … endobj`, including a stream's bytes.
    ///
    /// - Parameter resolveLength: Looks up a stream length that is given as a reference.
    mutating func parseIndirectObject(resolveLength: (ObjectID) -> Int?) throws -> (id: ObjectID, object: PDFObject) {
        skipWhitespace()
        guard let number = readUnsignedInteger() else { throw failure("expected an object number") }
        skipWhitespace()
        guard let generation = readUnsignedInteger() else { throw failure("expected a generation number") }
        skipWhitespace()
        guard consume("obj") else { throw failure("expected 'obj'") }
        let id = ObjectID(number, generation)
        skipWhitespace()
        if hasKeyword("endobj", at: position) { return (id, .null) }

        let object = try parseObject()
        guard case .dictionary(let dictionary) = object else { return (id, object) }

        let afterDictionary = position
        skipWhitespace()
        guard consume("stream") else {
            position = afterDictionary
            return (id, object)
        }
        if current == 0x0D { position += 1 }
        if current == 0x0A { position += 1 }
        let start = position

        var end: Int?
        let declared: Int? = switch dictionary["Length"] {
        case .integer(let value): value
        case .reference(let reference): resolveLength(reference)
        default: nil
        }
        if let declared, declared >= 0, declared <= bytes.count - start {
            var probe = start + declared
            while let value = byte(at: probe), isPDFWhitespace(value) { probe += 1 }
            if hasKeyword("endstream", at: probe) {
                end = start + declared
                position = probe + 9
            }
        }
        if end == nil {
            // The length is missing or wrong: take everything up to the keyword.
            if let keyword = find("endstream", from: start) {
                var last = keyword
                if last > start, bytes[last - 1] == 0x0A { last -= 1 }
                if last > start, bytes[last - 1] == 0x0D { last -= 1 }
                end = last
                position = keyword + 9
            } else {
                end = bytes.count
                position = bytes.count
            }
        }
        return (id, .stream(PDFStream(dictionary: dictionary, data: slice(start..<end!))))
    }
}

extension Data {
    /// Runs `body` with a parser positioned at `offset`, counted from the start of the data.
    func parse<Result>(at offset: Int = 0, _ body: (inout Parser) throws -> Result) rethrows -> Result {
        try withUnsafeBytes { bytes in
            // An offset from a damaged file can be anything; keep it inside the buffer.
            var parser = Parser(source: self, bytes: bytes, position: Swift.min(Swift.max(offset, 0), bytes.count))
            return try body(&parser)
        }
    }
}
