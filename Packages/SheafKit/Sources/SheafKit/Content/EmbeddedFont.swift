import Foundation

/// Reads and rewrites the tables of a TrueType font.
struct TrueTypeTables {
    var tables: [String: Data]

    private static func u16(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let start = data.startIndex + offset
        return Int(data[start]) << 8 | Int(data[start + 1])
    }

    private static func i16(_ data: Data, _ offset: Int) -> Int {
        let value = u16(data, offset)
        return value >= 0x8000 ? value - 0x10000 : value
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        u16(data, offset) << 16 | u16(data, offset + 2)
    }

    private func table(_ name: String) -> Data { tables[name] ?? Data() }

    var unitsPerEm: Int { max(Self.u16(table("head"), 18), 1) }
    var glyphCount: Int { Self.u16(table("maxp"), 4) }
    var ascent: Int { Self.i16(table("hhea"), 4) }
    var descent: Int { Self.i16(table("hhea"), 6) }
    /// The height of capital letters, where the font says.
    var capHeight: Int? {
        let os2 = table("OS/2")
        return os2.count >= 90 && Self.u16(os2, 0) >= 2 ? Self.i16(os2, 88) : nil
    }

    /// Degrees the font leans, counterclockwise, so negative for italics.
    var italicAngle: Double {
        let post = table("post")
        guard post.count >= 8 else { return 0 }
        return Double(Self.i16(post, 4)) + Double(Self.u16(post, 6)) / 65536
    }

    var isFixedPitch: Bool { table("post").count >= 16 && Self.u32(table("post"), 12) != 0 }

    /// The box all glyphs fit in, in font units.
    var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let head = table("head")
        return (Self.i16(head, 36), Self.i16(head, 38), Self.i16(head, 40), Self.i16(head, 42))
    }

    /// How far a glyph moves the pen, in font units.
    func advance(of glyph: Int) -> Int {
        let count = Self.u16(table("hhea"), 34)
        guard count > 0 else { return 0 }
        return Self.u16(table("hmtx"), 4 * min(glyph, count - 1))
    }

    /// Where each glyph's outline is in the glyph table.
    private var glyphRanges: [Range<Int>] {
        let loca = table("loca"), glyf = table("glyf")
        let isLong = Self.i16(table("head"), 50) != 0
        let count = glyphCount
        guard loca.count >= (count + 1) * (isLong ? 4 : 2) else { return [] }
        func offset(_ index: Int) -> Int { isLong ? Self.u32(loca, index * 4) : Self.u16(loca, index * 2) * 2 }
        return (0..<count).map { index in
            let start = offset(index), end = offset(index + 1)
            return start < end && end <= glyf.count ? start..<end : 0..<0
        }
    }

    /// The glyphs a glyph is built from, when it is put together from others.
    private func components(of range: Range<Int>) -> [Int] {
        let glyf = table("glyf")
        guard range.count >= 10, Self.i16(glyf, range.lowerBound) < 0 else { return [] }
        var result: [Int] = []
        var offset = range.lowerBound + 10
        while offset + 4 <= range.upperBound {
            let flags = Self.u16(glyf, offset)
            result.append(Self.u16(glyf, offset + 2))
            offset += 4 + (flags & 0x1 != 0 ? 4 : 2)
            if flags & 0x8 != 0 { offset += 2 } else if flags & 0x40 != 0 { offset += 4 } else if flags & 0x80 != 0 { offset += 8 }
            guard flags & 0x20 != 0 else { break }
        }
        return result
    }

    /// A font file with the outlines of only some glyphs. Every glyph keeps its number;
    /// the ones left out become empty.
    ///
    /// - Parameter extraTables: Tables to carry over as they are, such as the map from
    ///   characters to glyphs, which fonts used by character code need.
    func subset(keeping wanted: Set<Int>, extraTables: [String] = []) -> Data? {
        let ranges = glyphRanges
        guard !ranges.isEmpty else { return nil }
        // Glyphs built from other glyphs need those too.
        var kept: Set<Int> = [0]
        var queue = Array(wanted)
        while let glyph = queue.popLast() {
            guard ranges.indices.contains(glyph), kept.insert(glyph).inserted || glyph == 0 else { continue }
            queue.append(contentsOf: components(of: ranges[glyph]).filter { !kept.contains($0) })
        }

        let glyf = table("glyf")
        var outlines = Data()
        var offsets = Data()
        func append32(_ value: Int, to data: inout Data) {
            data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        for (glyph, range) in ranges.enumerated() {
            append32(outlines.count, to: &offsets)
            guard kept.contains(glyph), !range.isEmpty else { continue }
            outlines.append(glyf[(glyf.startIndex + range.lowerBound)..<(glyf.startIndex + range.upperBound)])
            while outlines.count % 4 != 0 { outlines.append(0) }
        }
        append32(outlines.count, to: &offsets)

        var head = Data(table("head"))
        guard head.count >= 54 else { return nil }
        // Offsets are now written long, and the whole-file checksum is worked out again below.
        head[head.startIndex + 50] = 0
        head[head.startIndex + 51] = 1
        for index in 8..<12 { head[head.startIndex + index] = 0 }

        // Widths of the glyphs left out are zeroed, which packs to almost nothing.
        var hmtx = Data(table("hmtx"))
        let metricCount = Self.u16(table("hhea"), 34)
        for glyph in 0..<min(metricCount, ranges.count) where !kept.contains(glyph) && glyph != metricCount - 1 && glyph * 4 + 4 <= hmtx.count {
            for index in 0..<4 { hmtx[hmtx.startIndex + glyph * 4 + index] = 0 }
        }

        var output: [String: Data] = ["head": head, "hhea": table("hhea"), "maxp": table("maxp"), "hmtx": hmtx, "loca": offsets, "glyf": outlines]
        for name in ["cvt ", "fpgm", "prep"] + extraTables { if let data = tables[name] { output[name] = data } }
        return Self.file(output)
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var word: UInt32 = 0
        for (index, byte) in data.enumerated() {
            word = word << 8 | UInt32(byte)
            if index % 4 == 3 {
                sum &+= word
                word = 0
            }
        }
        let rest = data.count % 4
        if rest != 0 { sum &+= word << UInt32(8 * (4 - rest)) }
        return sum
    }

    /// Puts tables together into a font file.
    private static func file(_ tables: [String: Data]) -> Data {
        func bytes16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func bytes32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        let names = tables.keys.sorted()
        var entrySelector = 0
        while 1 << (entrySelector + 1) <= names.count { entrySelector += 1 }
        let searchRange = 16 << entrySelector
        var header = Data([0, 1, 0, 0])
        header.append(contentsOf: bytes16(names.count) + bytes16(searchRange) + bytes16(entrySelector) + bytes16(names.count * 16 - searchRange))

        var directory = Data()
        var body = Data()
        var offset = 12 + names.count * 16
        var headOffset = 0
        for name in names {
            let data = tables[name] ?? Data()
            if name == "head" { headOffset = offset }
            directory.append(contentsOf: Array(name.utf8.prefix(4)))
            directory.append(contentsOf: bytes32(checksum(data)) + bytes32(UInt32(offset)) + bytes32(UInt32(data.count)))
            body.append(data)
            while body.count % 4 != 0 { body.append(0) }
            offset = 12 + names.count * 16 + body.count
        }
        var file = header + directory + body
        let adjustment = 0xB1B0_AFBA &- checksum(file)
        file.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: bytes32(adjustment))
        return file
    }
}

/// An installed font put inside a document, holding just the glyphs some text needs.
///
/// Text set this way is drawn by the reader's own font machinery, so it looks like any
/// other text in the document, on screen and in print.
struct EmbeddedFont {
    let fontName: String
    private let source: TrueTypeTables
    /// What each code stands for. One glyph may have several codes, when it stands for
    /// different characters in different places.
    private var entries: [(glyph: Int, text: String)] = [(0, "")]
    private var codes: [String: Int] = [:]

    init?(fontName: String) {
        guard let tables = FontProgram.trueTypeTables(fontName: fontName) else { return nil }
        self.fontName = fontName
        source = TrueTypeTables(tables: tables)
    }

    var isEmpty: Bool { entries.count <= 1 }

    /// The code that stands for a glyph in this font, added if it is new.
    mutating func code(for glyph: TextOutliner.Glyph) -> Int? {
        let key = "\(glyph.index)/\(glyph.text)"
        if let existing = codes[key] { return existing }
        guard entries.count < 0xFFFF, Int(glyph.index) < source.glyphCount else { return nil }
        codes[key] = entries.count
        entries.append((Int(glyph.index), glyph.text))
        return entries.count - 1
    }

    /// How many codes the font has given out.
    var codeCount: Int { entries.count }

    /// The objects a font is made of in a document, so they can be written again when
    /// the font gains glyphs.
    struct Objects: Equatable {
        var font: ObjectID
        var descendant: ObjectID
        var descriptor: ObjectID
        var file: ObjectID
        var glyphMap: ObjectID
        var toUnicode: ObjectID
        var name: PDFName
        /// How many codes the font had when it was last written.
        var codeCount: Int
    }

    /// Writes the font into a document: as new objects, or over the objects it was
    /// written to before, when more glyphs have been added since. Codes never change, so
    /// text set earlier keeps reading right.
    ///
    /// - Returns: The font's objects, or `nil` when its file cannot be cut down.
    func write(to editor: inout PDFEditor, over existing: Objects? = nil) -> Objects? {
        if let existing, existing.codeCount == entries.count { return existing }
        guard let program = source.subset(keeping: Set(entries.map(\.glyph))) else { return nil }
        let scale = 1000 / Double(source.unitsPerEm)
        func units(_ value: Int) -> PDFObject { .integer(wholeNumber(Double(value) * scale)) }

        // Six letters before the name mark a font that holds only some of its glyphs.
        var tag = ""
        var seed = editor.nextObjectNumber &* 7919 &+ entries.count
        for _ in 0..<6 {
            tag.append(Character(UnicodeScalar(UInt8(65 + abs(seed) % 26))))
            seed /= 26
        }
        let name = existing?.name ?? PDFName("\(tag)+\(fontName)")
        var objects = existing ?? Objects(
            font: editor.reserve(), descendant: editor.reserve(), descriptor: editor.reserve(), file: editor.reserve(),
            glyphMap: editor.reserve(), toUnicode: editor.reserve(), name: name, codeCount: 0
        )
        objects.codeCount = entries.count

        editor.set(.stream(PDFStream(
            dictionary: ["Filter": .name("FlateDecode"), "Length1": .integer(program.count)], data: Flate.deflate(program)
        )), for: objects.file)
        let bounds = source.bounds
        var flags = 4
        if source.isFixedPitch { flags |= 1 }
        if source.italicAngle != 0 { flags |= 64 }
        editor.set([
            "Type": .name("FontDescriptor"), "FontName": .name(name), "Flags": .integer(flags),
            "FontBBox": [units(bounds.minX), units(bounds.minY), units(bounds.maxX), units(bounds.maxY)],
            "ItalicAngle": .real(source.italicAngle), "Ascent": units(source.ascent), "Descent": units(source.descent),
            "CapHeight": units(source.capHeight ?? source.ascent), "StemV": 80, "FontFile2": .reference(objects.file),
        ], for: objects.descriptor)

        // Which glyph each code draws, two bytes per code.
        var glyphMap = Data()
        var mappings: [String] = []
        for (code, entry) in entries.enumerated() {
            glyphMap.append(contentsOf: [UInt8(entry.glyph >> 8 & 0xFF), UInt8(entry.glyph & 0xFF)])
            if !entry.text.isEmpty {
                mappings.append(String(format: "<%04X> <%@>", code, entry.text.utf16.map { String(format: "%04X", $0) }.joined()))
            }
        }
        editor.set(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(glyphMap))), for: objects.glyphMap)
        let widths = entries.dropFirst().map { units(source.advance(of: $0.glyph)) }
        editor.set([
            "Type": .name("Font"), "Subtype": .name("CIDFontType2"), "BaseFont": .name(name),
            "CIDSystemInfo": ["Registry": .string(Data("Adobe".utf8)), "Ordering": .string(Data("Identity".utf8)), "Supplement": 0],
            "FontDescriptor": .reference(objects.descriptor), "DW": 1000, "W": [1, .array(widths)], "CIDToGIDMap": .reference(objects.glyphMap),
        ], for: objects.descendant)

        // Tells readers which characters each code stands for, for search and copy.
        var blocks = ""
        for start in stride(from: 0, to: mappings.count, by: 100) {
            let chunk = mappings[start..<min(start + 100, mappings.count)]
            blocks += "\(chunk.count) beginbfchar\n" + chunk.joined(separator: "\n") + "\nendbfchar\n"
        }
        let unicode = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        \(blocks)endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        editor.set(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(Data(unicode.utf8)))), for: objects.toUnicode)

        editor.set([
            "Type": .name("Font"), "Subtype": .name("Type0"), "BaseFont": .name(name), "Encoding": .name("Identity-H"),
            "DescendantFonts": [.reference(objects.descendant)], "ToUnicode": .reference(objects.toUnicode),
        ], for: objects.font)
        return objects
    }
}
