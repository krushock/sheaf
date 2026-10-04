import Foundation

/// A font as a page uses it: which text each code stands for, and how wide each glyph is.
final class PageFont: @unchecked Sendable {
    enum Kind { case simple, composite, type3 }

    let kind: Kind
    /// The font's name without the tag that marks a subset.
    let baseName: String
    /// Whether the document carries only the glyphs it uses.
    let isSubset: Bool
    let isEmbedded: Bool
    /// How many bytes make one character code.
    let codeLength: Int
    let traits: FontMatcher.Traits
    /// How far the font reaches above and below the baseline, in thousandths of its size.
    let ascent: Double
    let descent: Double
    /// False when the font numbers its characters in a way the engine does not follow, so
    /// the text and widths read from it cannot be trusted.
    let isReliable: Bool

    private var widths: [Int: Double] = [:]
    private var defaultWidth = 0.0
    private var texts: [Int: String] = [:]
    private var codes: [String: Int] = [:]
    /// The installed font to measure with when the document gives no widths.
    private var metricsFont: String?

    init(dictionary: PDFDictionary, source: some ObjectSource) throws {
        let subtype = dictionary["Subtype"]?.nameValue
        var name = try source.value("BaseFont", in: dictionary).nameValue?.text ?? ""
        if name.isEmpty { name = try source.value("Name", in: dictionary).nameValue?.text ?? "Unknown" }
        let tagged = name.count > 7 && name.dropFirst(6).first == "+" && name.prefix(6).allSatisfy(\.isUppercase)
        if tagged { name = String(name.dropFirst(7)) }
        baseName = name
        isSubset = tagged

        var descriptor = try source.value("FontDescriptor", in: dictionary).dictionaryValue
        var reliable = true

        switch subtype {
        case "Type0":
            kind = .composite
            let descendant = try source.resolve(try source.value("DescendantFonts", in: dictionary).arrayValue?.first ?? .null).dictionaryValue ?? [:]
            descriptor = try source.value("FontDescriptor", in: descendant).dictionaryValue
            defaultWidth = try source.value("DW", in: descendant).doubleValue ?? 1000
            // Runs of widths: a first code with a list, or a range with one width.
            let entries = try source.value("W", in: descendant).arrayValue ?? []
            var index = 0
            while index < entries.count {
                guard let first = try source.resolve(entries[index]).intValue, index + 1 < entries.count else { break }
                let next = try source.resolve(entries[index + 1])
                if let list = next.arrayValue {
                    for (offset, entry) in list.enumerated() {
                        if let width = try source.resolve(entry).doubleValue { widths[first + offset] = width }
                    }
                    index += 2
                } else if let last = next.intValue, index + 2 < entries.count, let width = try source.resolve(entries[index + 2]).doubleValue {
                    if last >= first, last - first < 65_536 { for code in first...last { widths[code] = width } }
                    index += 3
                } else {
                    break
                }
            }
            // Codes are glyph numbers only under the identity encodings. Other encodings
            // need tables the engine does not carry.
            let encoding = try source.resolve(dictionary["Encoding"] ?? .null)
            if let named = encoding.nameValue {
                reliable = named == "Identity-H" || named == "Identity-V"
            } else {
                reliable = false
            }
            codeLength = 2

        case "Type3":
            kind = .type3
            codeLength = 1
            let matrix = try source.value("FontMatrix", in: dictionary).arrayValue?.compactMap(\.doubleValue) ?? [0.001, 0, 0, 0.001, 0, 0]
            let scale = (matrix.first ?? 0.001) * 1000
            let first = try source.value("FirstChar", in: dictionary).intValue ?? 0
            for (offset, entry) in (try source.value("Widths", in: dictionary).arrayValue ?? []).enumerated() {
                if let width = try source.resolve(entry).doubleValue { widths[first + offset] = width * scale }
            }

        default:
            kind = .simple
            codeLength = 1
            let first = try source.value("FirstChar", in: dictionary).intValue ?? 0
            let list = try source.value("Widths", in: dictionary).arrayValue ?? []
            for (offset, entry) in list.enumerated() {
                if let width = try source.resolve(entry).doubleValue { widths[first + offset] = width }
            }
            defaultWidth = try descriptor.map { try source.value("MissingWidth", in: $0) }?.doubleValue ?? 0
        }

        isEmbedded = descriptor.map { $0["FontFile"] != nil || $0["FontFile2"] != nil || $0["FontFile3"] != nil } ?? (kind == .type3)
        let flags = try descriptor.map { try source.value("Flags", in: $0) }?.intValue ?? 0
        let lowered = name.lowercased()
        let weight = try descriptor.map { try source.value("FontWeight", in: $0) }?.doubleValue ?? 400
        let angle = try descriptor.map { try source.value("ItalicAngle", in: $0) }?.doubleValue ?? 0
        // The fonts TeX sets its pages in say little about themselves beyond their
        // names: CMR10 is the roman, CMBX12 the bold, CMTI the italic, CMSL the slanted,
        // CMTT the typewriter face, CMSS the sans. The Latin Modern fonts follow suit.
        let plain = name.split(separator: "+").last.map { $0.uppercased() } ?? ""
        let isTeX = plain.hasPrefix("CM") && plain.count <= 9 || plain.hasPrefix("LMROMAN") || plain.hasPrefix("LMMONO") || plain.hasPrefix("LMSANS") || plain.hasPrefix("SFRM") || plain.hasPrefix("SFTT")
        let texFace = plain.hasPrefix("LM") ? String(plain.dropFirst(2)) : String(plain.dropFirst(2).prefix { $0.isLetter })
        let texBold = isTeX && (texFace.hasPrefix("B") || texFace.contains("BX") || texFace.contains("BOLD"))
        let texItalic = isTeX && (texFace.contains("TI") || texFace.contains("SL") || texFace.hasSuffix("I") || texFace.contains("ITALIC") || texFace.contains("OBLIQUE"))
        let texFixed = isTeX && (texFace.contains("TT") || texFace.hasPrefix("MONO"))
        let texSans = isTeX && (texFace.hasPrefix("SS") || texFace.hasPrefix("SANS"))
        let serifNames = ["times", "georgia", "garamond", "palatino", "minion", "baskerville", "bookman", "century", "cambria", "caslon", "didot", "bodoni", "charter", "nimbusrom", "liberationserif", "dejavuserif"]
        traits = FontMatcher.Traits(
            isBold: lowered.contains("bold") || lowered.contains("black") || lowered.contains("heavy") || weight >= 600 || flags & (1 << 18) != 0 || texBold,
            isItalic: lowered.contains("italic") || lowered.contains("oblique") || angle != 0 || flags & (1 << 6) != 0 || texItalic,
            isSerif: flags & (1 << 1) != 0 || serifNames.contains { lowered.contains($0) } || lowered.contains("serif") && !lowered.contains("sans") || isTeX && !texFixed && !texSans,
            isFixedPitch: flags & 1 != 0 || lowered.contains("courier") || lowered.contains("mono") || lowered.contains("menlo") || texFixed
        )
        let declaredAscent = try descriptor.map { try source.value("Ascent", in: $0) }?.doubleValue ?? 0
        let declaredDescent = try descriptor.map { try source.value("Descent", in: $0) }?.doubleValue ?? 0
        ascent = declaredAscent > 0 && declaredAscent < 2000 ? declaredAscent : 750
        descent = declaredDescent < 0 && declaredDescent > -1000 ? -declaredDescent : 250

        // Which text each code stands for: the font's own map if it has one, else its encoding.
        var map: UnicodeMap?
        if let stream = try source.value("ToUnicode", in: dictionary).streamValue, let data = try? source.decodedData(of: stream) {
            map = UnicodeMap(data: data)
        }
        if let map, !map.isEmpty {
            texts = map.text
        }
        if kind != .composite {
            let encoding = try source.resolve(dictionary["Encoding"] ?? .null)
            let isSymbolic = flags & (1 << 2) != 0 && flags & (1 << 5) == 0
            var table = Encodings.base(named: encoding.nameValue)
                ?? Encodings.base(named: encoding.dictionaryValue?["BaseEncoding"]?.nameValue)
            // With nothing said, the font program's own numbering applies. For text fonts
            // that is nearly always the standard one, even when the font is marked as a
            // symbol font, as subsets often are.
            _ = isSymbolic
            // A font of drawn glyphs has no numbering of its own: only the names it lists count.
            if table == nil, kind != .type3 { table = subtype == "TrueType" ? Encodings.winAnsi : Encodings.standard }
            var named = table ?? [String](repeating: "", count: 256)
            var code = 0
            for entry in try encoding.dictionaryValue.map({ try source.value("Differences", in: $0) })?.arrayValue ?? [] {
                if let start = entry.intValue {
                    code = start
                } else if let glyph = entry.nameValue {
                    if (0..<256).contains(code) { named[code] = Encodings.text(forGlyphNamed: glyph.text) ?? "" }
                    code += 1
                }
            }
            for (code, text) in named.enumerated() where !text.isEmpty && texts[code] == nil { texts[code] = text }
            if kind == .simple, widths.isEmpty {
                // One of the fonts every reader has built in: measured from the installed one.
                metricsFont = FontMatcher.installedName(for: name, traits: traits)
            }
        } else if texts.isEmpty {
            reliable = false
        }
        isReliable = reliable

        // The reverse: which code to write for some text. Only codes the font really has
        // a glyph for are offered, which for a subset means the codes it gives a width.
        for (code, text) in texts.sorted(by: { $0.key < $1.key }) where codes[text] == nil {
            if kind != .composite, !widths.isEmpty {
                guard let width = widths[code], width > 0 || text == " " else { continue }
            }
            codes[text] = code
        }
    }

    /// A glyph's width in thousandths of the font size.
    func width(of code: Int) -> Double {
        if let width = widths[code] { return width }
        if let metricsFont, let character = texts[code]?.first, let measured = FontMatcher.advance(of: character, fontName: metricsFont) {
            widths[code] = measured
            return measured
        }
        return defaultWidth
    }

    /// The text a code stands for, or `nil` when the font does not say.
    func text(of code: Int) -> String? { texts[code] }

    /// The code that draws some text, or `nil` when the font has no glyph known to draw it.
    func code(for text: String) -> Int? { codes[text] }

    /// Splits the bytes of a shown string into character codes.
    func codes(in string: Data) -> [Int] {
        guard codeLength == 2 else { return string.map(Int.init) }
        var result: [Int] = []
        result.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index + 1 < string.endIndex {
            result.append(Int(string[index]) << 8 | Int(string[index + 1]))
            index += 2
        }
        return result
    }

    /// The bytes that show a code.
    func bytes(for code: Int) -> [UInt8] {
        codeLength == 2 ? [UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)] : [UInt8(code & 0xFF)]
    }
}
