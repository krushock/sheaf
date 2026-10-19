import Foundation

/// Reads what a PDF needs from an embedded Type 1 font program (the "FontFile" kind).
enum Type1Program {
    /// The names of the glyphs the program draws, from its CharStrings, or `nil` when the
    /// program cannot be read. The CharStrings are in the part encrypted with the "eexec"
    /// cipher, in binary or as hexadecimal digits.
    static func glyphNames(in program: Data) -> [String]? {
        let bytes = [UInt8](program)
        guard let marker = find(Array("eexec".utf8), in: bytes) else { return nil }
        var start = marker + 5
        while start < bytes.count, [0x0D, 0x0A, 0x20, 0x09].contains(bytes[start]) { start += 1 }
        guard start + 4 <= bytes.count else { return nil }

        var cipher: [UInt8]
        if bytes[start..<start + 4].allSatisfy(isHexDigit) {
            cipher = []
            var high: UInt8?
            for byte in bytes[start...] {
                if [0x0D, 0x0A, 0x20, 0x09].contains(byte) { continue }
                guard let value = hexValue(byte) else { break }
                if let first = high {
                    cipher.append(first << 4 | value)
                    high = nil
                } else {
                    high = value
                }
            }
        } else {
            cipher = Array(bytes[start...])
        }

        var plain = [UInt8]()
        plain.reserveCapacity(cipher.count)
        var key: UInt16 = 55665
        for byte in cipher {
            plain.append(byte ^ UInt8(key >> 8))
            key = (UInt16(byte) &+ key) &* 52845 &+ 22719
        }
        guard plain.count > 4 else { return nil }
        // One character for each byte, so that lengths in bytes can be skipped by characters.
        guard let text = String(data: Data(plain.dropFirst(4)), encoding: .isoLatin1) else { return nil }
        guard let charStrings = text.range(of: "/CharStrings") else { return nil }

        // Each glyph reads "/name length RD <length bytes> ND"; "-|" and "|-" are the other spellings.
        var names: [String] = []
        let body = text[charStrings.upperBound...]
        let pattern = /\/([^\s\/\[\]{}()<>%]+)\s+(\d+)\s+(?:RD|-\|)\s/
        var rest = body[...]
        while let match = rest.firstMatch(of: pattern) {
            names.append(String(match.output.1))
            // Skip the glyph's own bytes, which can look like anything.
            let length = Int(match.output.2) ?? 0
            let after = match.range.upperBound
            rest = rest[(rest.unicodeScalars.index(after, offsetBy: length, limitedBy: rest.endIndex) ?? rest.endIndex)...]
        }
        return names.isEmpty ? nil : names
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for index in 0...(haystack.count - needle.count) where haystack[index] == needle[0] && Array(haystack[index..<index + needle.count]) == needle {
            return index
        }
        return nil
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool { hexValue(byte) != nil }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
