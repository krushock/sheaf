import Foundation

/// Builds a small font holding just the glyphs some text needs, each drawn from its outline.
///
/// This lets the engine write real text in any script without reading or embedding font
/// files: the text can be selected, searched and copied, and readers that draw form
/// fields their own way recognize it as text they may replace. The glyphs are plain
/// shapes with no hinting, which is not noticeable at screen and print resolutions.
struct GlyphFont {
    private struct Entry {
        var outline: [PathElement]
        var advance: Double
        var text: String
    }

    private var codes: [String: UInt8] = [:]
    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var isFull: Bool { entries.count >= 256 }

    /// The code that stands for a glyph in this font, added if it is new. `nil` when the
    /// font already holds as many glyphs as one font can.
    mutating func code(for glyph: TextOutliner.Glyph) -> UInt8? {
        // The same glyph standing for different characters, as in a ligature and its
        // parts, needs separate entries for the text to copy correctly.
        let key = "\(glyph.fontName)/\(glyph.index)/\(glyph.text)"
        if let existing = codes[key] { return existing }
        guard !isFull else { return nil }
        let code = UInt8(entries.count)
        codes[key] = code
        entries.append(Entry(outline: glyph.outline, advance: glyph.advance, text: glyph.text))
        return code
    }

    /// Adds the font to a document.
    func add(to editor: inout PDFEditor) -> ObjectID {
        func number(_ value: Double) -> String { Serializer.format((value * 100).rounded() / 100) }
        var procedures: PDFDictionary = [:]
        var names: [PDFObject] = [0]
        var widths: [PDFObject] = []
        var box = (minX: 0.0, minY: 0.0, maxX: 0.0, maxY: 0.0)
        var mappings = ""

        for (code, entry) in entries.enumerated() {
            let points = entry.outline.flatMap(\.points)
            var content: String
            if let bounds = PDFRectangle(enclosing: points) {
                // "d1" says how far the glyph moves the pen and the box it fits in, and that
                // it takes whatever color the text is drawn in.
                content = "\(number(entry.advance)) 0 \(number(bounds.x)) \(number(bounds.y)) \(number(bounds.x + bounds.width)) \(number(bounds.y + bounds.height)) d1\n"
                for element in entry.outline {
                    switch element {
                    case .move(let p): content += "\(number(p.x)) \(number(p.y)) m\n"
                    case .line(let p): content += "\(number(p.x)) \(number(p.y)) l\n"
                    case .curve(let a, let b, let c): content += "\(number(a.x)) \(number(a.y)) \(number(b.x)) \(number(b.y)) \(number(c.x)) \(number(c.y)) c\n"
                    case .close: content += "h\n"
                    }
                }
                content += "f\n"
                box = (min(box.minX, bounds.x), min(box.minY, bounds.y), max(box.maxX, bounds.x + bounds.width), max(box.maxY, bounds.y + bounds.height))
            } else {
                // A space, or anything else with nothing to draw.
                content = "\(number(entry.advance)) 0 d0\n"
            }
            let name = PDFName("g\(code)")
            procedures[name] = .reference(editor.add(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(Data(content.utf8))))))
            names.append(.name(name))
            widths.append(.real((entry.advance * 100).rounded() / 100))
            if !entry.text.isEmpty {
                let units = entry.text.utf16.map { String(format: "%04X", $0) }.joined()
                mappings += String(format: "<%02X> <%@>\n", code, units)
            }
        }

        // Tells readers which characters each code stands for, for search and copy.
        let map = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <00> <FF>
        endcodespacerange
        \(mappings.split(separator: "\n").count) beginbfchar
        \(mappings)endbfchar
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        let toUnicode = editor.add(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(Data(map.utf8)))))

        return editor.add([
            "Type": .name("Font"), "Subtype": .name("Type3"),
            "FontBBox": [.real(box.minX.rounded(.down)), .real(box.minY.rounded(.down)), .real(box.maxX.rounded(.up)), .real(box.maxY.rounded(.up))],
            "FontMatrix": [.real(0.001), 0, 0, .real(0.001), 0, 0],
            "CharProcs": .dictionary(procedures),
            "Encoding": ["Type": .name("Encoding"), "Differences": .array(names)],
            "FirstChar": 0, "LastChar": .integer(max(entries.count - 1, 0)),
            "Widths": .array(widths), "Resources": [:], "ToUnicode": .reference(toUnicode),
        ])
    }
}

/// Text placed glyph by glyph, with the fonts it needs.
struct GlyphText {
    private(set) var fonts: [GlyphFont] = [GlyphFont()]
    private(set) var operators = ""
    private var currentFont = -1

    var isEmpty: Bool { operators.isEmpty }

    /// Adds a line whose left end and baseline are at a point.
    mutating func add(_ line: TextOutliner.ShapedLine, x: Double, baseline: Double, fontSize: Double) {
        for glyph in line.glyphs {
            var code = fonts[fonts.count - 1].code(for: glyph)
            if code == nil {
                fonts.append(GlyphFont())
                code = fonts[fonts.count - 1].code(for: glyph)
            }
            guard let code else { continue }
            if currentFont != fonts.count - 1 {
                currentFont = fonts.count - 1
                operators += "/SheafF\(currentFont) \(Serializer.format(fontSize)) Tf\n"
            }
            // Each glyph is put exactly where the layout put it, kerning included.
            operators += "1 0 0 1 \(Serializer.format(x + glyph.x)) \(Serializer.format(baseline + glyph.y)) Tm <\(String(format: "%02X", code))> Tj\n"
        }
    }

    /// Adds the fonts to a document and gives the entries for a resource dictionary.
    func fontResources(in editor: inout PDFEditor) -> PDFDictionary {
        var resources: PDFDictionary = [:]
        for (index, font) in fonts.enumerated() where !font.isEmpty {
            resources[PDFName("SheafF\(index)")] = .reference(font.add(to: &editor))
        }
        return resources
    }
}
