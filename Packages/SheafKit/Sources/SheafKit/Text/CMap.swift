import Foundation

/// A character map of the kind fonts carry to say which text each code stands for.
struct UnicodeMap {
    /// Code to text.
    private(set) var text: [Int: String] = [:]
    /// How many bytes make a code, by the ranges the map declares. Empty when it declares none.
    private(set) var codeLengths: Set<Int> = []

    var isEmpty: Bool { text.isEmpty }

    /// Reads a `ToUnicode` map. Unknown parts are skipped.
    init(data: Data) {
        var pending: [PDFObject] = []
        var mode = ""
        // The body of a map is PostScript, close enough to content stream syntax to read as one.
        for operation in ContentStream(data: data).operations {
            switch operation.name {
            case "begincodespacerange", "beginbfchar", "beginbfrange":
                mode = operation.name
                pending = []
            case "endcodespacerange":
                var index = 0
                while index + 1 < operation.operands.count {
                    if let low = operation.operands[index].stringValue { codeLengths.insert(low.count) }
                    index += 2
                }
            case "endbfchar":
                var index = 0
                while index + 1 < operation.operands.count {
                    if let code = operation.operands[index].stringValue, let target = operation.operands[index + 1].stringValue {
                        text[Self.number(code)] = Self.utf16(target)
                    }
                    index += 2
                }
            case "endbfrange":
                var index = 0
                let operands = operation.operands
                while index + 2 < operands.count {
                    defer { index += 3 }
                    guard let low = operands[index].stringValue, let high = operands[index + 1].stringValue else { continue }
                    let first = Self.number(low), last = Self.number(high)
                    guard last >= first, last - first < 65_536 else { continue }
                    if let targets = operands[index + 2].arrayValue {
                        // One target per code.
                        for (offset, target) in targets.enumerated() where first + offset <= last {
                            if let bytes = target.stringValue { text[first + offset] = Self.utf16(bytes) }
                        }
                    } else if let start = operands[index + 2].stringValue {
                        // Consecutive targets: the last unit counts up.
                        var units = Self.units(start)
                        guard !units.isEmpty else { continue }
                        for code in first...last {
                            text[code] = String(decoding: units, as: UTF16.self)
                            units[units.count - 1] &+= 1
                        }
                    }
                }
            default:
                break
            }
            _ = (pending, mode)
        }
    }

    private static func number(_ bytes: Data) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }

    private static func units(_ bytes: Data) -> [UInt16] {
        var units: [UInt16] = []
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        if index < bytes.endIndex { units.append(UInt16(bytes[index])) }
        return units
    }

    private static func utf16(_ bytes: Data) -> String {
        String(decoding: units(bytes), as: UTF16.self)
    }
}
