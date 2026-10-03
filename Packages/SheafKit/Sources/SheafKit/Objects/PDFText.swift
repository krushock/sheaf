import Foundation

/// Text strings: the encoding PDF uses for titles, bookmarks, field values and the like.
public enum PDFText {
    /// Reads a text string: UTF-16 or UTF-8 when marked with a byte order mark, otherwise
    /// PDFDocEncoding.
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(decoding: utf16(bytes.dropFirst(2), bigEndian: true), as: UTF16.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(decoding: utf16(bytes.dropFirst(2), bigEndian: false), as: UTF16.self)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            scalars.append(docEncoding[byte] ?? Unicode.Scalar(byte))
        }
        return String(scalars)
    }

    /// Makes a text string: plain ASCII when possible, otherwise UTF-16 with a byte order mark.
    public static func encode(_ text: String) -> Data {
        if text.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return Data(text.utf8)
        }
        var data = Data([0xFE, 0xFF])
        for unit in text.utf16 {
            data.append(UInt8(unit >> 8))
            data.append(UInt8(unit & 0xFF))
        }
        return data
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        return units
    }

    /// Where PDFDocEncoding differs from Latin-1.
    private static let docEncoding: [UInt8: Unicode.Scalar] = {
        var table: [UInt8: Unicode.Scalar] = [:]
        let low: [UInt32] = [0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC]
        for (offset, value) in low.enumerated() { table[UInt8(0x18 + offset)] = Unicode.Scalar(value) }
        let high: [UInt32] = [
            0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044, 0x2039, 0x203A, 0x2212, 0x2030,
            0x201E, 0x201C, 0x201D, 0x2018, 0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141, 0x0152, 0x0160,
            0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E,
        ]
        for (offset, value) in high.enumerated() { table[UInt8(0x80 + offset)] = Unicode.Scalar(value) }
        table[0xA0] = Unicode.Scalar(0x20AC as UInt32)
        return table
    }()
}

/// Dates as PDF writes them: `D:20261003142500+02'00'`.
public enum PDFDate {
    public static func decode(_ text: String) -> Date? {
        var digits = Substring(text)
        if digits.hasPrefix("D:") { digits = digits.dropFirst(2) }
        func take(_ count: Int, default fallback: Int) -> Int {
            guard digits.count >= count, let value = Int(digits.prefix(count)) else { return fallback }
            digits = digits.dropFirst(count)
            return value
        }
        guard digits.count >= 4, digits.prefix(4).allSatisfy(\.isNumber) else { return nil }
        var parts = DateComponents()
        parts.year = take(4, default: 0)
        parts.month = take(2, default: 1)
        parts.day = take(2, default: 1)
        parts.hour = take(2, default: 0)
        parts.minute = take(2, default: 0)
        parts.second = take(2, default: 0)
        var offsetSeconds = 0
        if let sign = digits.first, sign == "+" || sign == "-" {
            digits = digits.dropFirst()
            let hours = take(2, default: 0)
            if digits.first == "'" { digits = digits.dropFirst() }
            let minutes = take(2, default: 0)
            offsetSeconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? .gmt
        return calendar.date(from: parts)
    }

    public static func encode(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "D:%04d%02d%02d%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}
