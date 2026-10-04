import Foundation

/// Writes a zip archive, the container Word and Excel files are kept in.
struct ZipArchive {
    private struct Entry {
        var name: Data
        var checksum: UInt32
        var storedSize: Int
        var size: Int
        var method: UInt16
        var offset: Int
    }

    private var body = Data()
    private var entries: [Entry] = []

    private static func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func bytes(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * UInt32($0)) & 0xFF) } }

    /// Adds a file.
    ///
    /// - Parameter compresses: Off for files that are compressed already, such as pictures.
    mutating func add(_ name: String, _ data: Data, compresses: Bool = true) {
        let packed = compresses ? Flate.rawDeflate(data) : nil
        // Stored as it is when compressing does not make it smaller.
        let stored = packed.flatMap { $0.count < data.count ? $0 : nil }
        let entry = Entry(
            name: Data(name.utf8), checksum: Flate.checksum(data), storedSize: (stored ?? data).count, size: data.count,
            method: stored == nil ? 0 : 8, offset: body.count
        )
        body.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        body.append(contentsOf: Self.header(of: entry))
        body.append(entry.name)
        body.append(stored ?? data)
        entries.append(entry)
    }

    mutating func add(_ name: String, _ text: String) {
        add(name, Data(text.utf8))
    }

    /// The fields the entry's own header and the directory at the end have in common.
    private static func header(of entry: Entry) -> [UInt8] {
        // Version 2.0, names in UTF-8, a fixed date: the same input always gives the same archive.
        bytes(UInt16(20)) + bytes(UInt16(0x0800)) + bytes(entry.method) + bytes(UInt16(0)) + bytes(UInt16(0x21))
            + bytes(entry.checksum) + bytes(UInt32(entry.storedSize)) + bytes(UInt32(entry.size))
            + bytes(UInt16(entry.name.count)) + bytes(UInt16(0))
    }

    func data() -> Data {
        var output = body
        let start = output.count
        for entry in entries {
            output.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            output.append(contentsOf: Self.bytes(UInt16(20)))
            output.append(contentsOf: Self.header(of: entry))
            // No comment, first disk, no attributes.
            output.append(contentsOf: Self.bytes(UInt16(0)) + Self.bytes(UInt16(0)) + Self.bytes(UInt16(0)) + Self.bytes(UInt32(0)))
            output.append(contentsOf: Self.bytes(UInt32(entry.offset)))
            output.append(entry.name)
        }
        let size = output.count - start
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0])
        output.append(contentsOf: Self.bytes(UInt16(entries.count)) + Self.bytes(UInt16(entries.count)))
        output.append(contentsOf: Self.bytes(UInt32(size)) + Self.bytes(UInt32(start)) + Self.bytes(UInt16(0)))
        return output
    }
}

/// Text made safe to put inside XML.
func xmlEscaped(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        // Control characters are not allowed in XML at all.
        case _ where scalar.value < 0x20 && scalar != "\t" && scalar != "\n": continue
        case _ where scalar.value == 0xFFFE || scalar.value == 0xFFFF: continue
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result
}

/// A number rounded to a whole one, for writing into a file. Numbers from damaged
/// documents can be anything; those that are no number at all, or absurdly large, become zero.
func wholeNumber(_ value: Double) -> Int {
    guard value.isFinite, abs(value) < 1e12 else { return 0 }
    return Int(value.rounded())
}
