import Foundation

/// Drawing to add to a page, in the coordinates of the page as displayed.
struct PageAddition {
    var operators = ""
    var fonts: PDFDictionary = [:]
    var xObjects: PDFDictionary = [:]
    var graphicsStates: PDFDictionary = [:]

    var isEmpty: Bool { operators.isEmpty }
}

/// Writes text operators, repeating state only when it changes.
struct TextEmitter {
    private(set) var operators = ""
    private var font = ""
    private var color: PDFColor?
    private var charSpacing = 0.0
    private var horizontalScale = 1.0
    var glyphText: GlyphText

    /// - Parameter editor: The document the text is for, whose typed fonts it adds to.
    init(fontPrefix: String, in editor: PDFEditor) {
        glyphText = GlyphText()
        glyphText.prefix = fontPrefix
        glyphText.embedsFonts = true
        glyphText.continueFonts(of: editor)
    }

    private func number(_ value: Double) -> String { Serializer.format((value * 1000).rounded() / 1000) }

    private mutating func set(color new: PDFColor) {
        guard color != new else { return }
        color = new
        operators += "\(number(new.red)) \(number(new.green)) \(number(new.blue)) rg\n"
    }

    private mutating func set(font name: String, size: Double, charSpacing spacing: Double, horizontalScale scale: Double) {
        let key = "\(name) \(number(size))"
        if font != key {
            font = key
            operators += "/\(name) \(number(size)) Tf\n"
        }
        if charSpacing != spacing {
            charSpacing = spacing
            operators += "\(number(spacing)) Tc\n"
        }
        if horizontalScale != scale {
            horizontalScale = scale
            operators += "\(number(scale * 100)) Tz\n"
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
    }

    /// A glyph exactly as the page had it, moved by an offset.
    mutating func exact(_ glyph: PageGlyph, font: PageFont, resource: PDFName, dx: Double = 0, dy: Double = 0, color override: PDFColor? = nil) {
        set(color: override ?? glyph.color)
        // The matrix carries the size, so the font is set at one unit.
        set(font: resource.rawValue, size: 1, charSpacing: 0, horizontalScale: 1)
        let m = glyph.matrix
        operators += "\(number(m.a)) \(number(m.b)) \(number(m.c)) \(number(m.d)) \(number(m.e + dx)) \(number(m.f + dy)) Tm \(hex(font.bytes(for: glyph.code))) Tj\n"
    }

    /// Codes in one of the page's own fonts, set from a point with the font's own spacing.
    mutating func run(codes: [Int], font: PageFont, resource: PDFName, size: Double, x: Double, baseline: Double, color new: PDFColor) {
        guard !codes.isEmpty else { return }
        set(color: new)
        set(font: resource.rawValue, size: size, charSpacing: 0, horizontalScale: 1)
        operators += "1 0 0 1 \(number(x)) \(number(baseline)) Tm \(hex(codes.flatMap(font.bytes))) Tj\n"
    }

    /// Text in an installed font, drawn through a font made of its glyphs' outlines.
    mutating func shaped(_ line: TextOutliner.ShapedLine, size: Double, x: Double, baseline: Double, color new: PDFColor) {
        set(color: new)
        if charSpacing != 0 || horizontalScale != 1 { set(font: "", size: 0, charSpacing: 0, horizontalScale: 1) }
        glyphText.forgetFont()
        glyphText.add(line, x: x, baseline: baseline, fontSize: size)
        operators += glyphText.takeOperators()
        font = ""
    }

    /// Everything written, as one text object ready to be added to a page.
    func addition(in editor: inout PDFEditor) -> PageAddition {
        guard !operators.isEmpty else { return PageAddition() }
        // Whatever spacing and mode the page left set must not carry into this text.
        let body = "BT\n0 Tc 0 Tw 100 Tz 0 Ts 0 Tr\n" + operators + "ET\n"
        return PageAddition(operators: body, fonts: glyphText.fontResources(in: &editor))
    }
}

extension PDFEditor {
    /// Changes a page's own content: takes glyphs out, swaps whole operations, and adds
    /// new drawing, on top or somewhere in the stacking order.
    ///
    /// Glyphs are taken out by turning them into an equal amount of empty space, so
    /// whatever follows them on the page stays exactly where it was.
    ///
    /// - Parameters:
    ///   - block: Operations to add as they are, in the page's own coordinates. They must
    ///     draw the same from a clean start: see `ContentStream.lifted(_:from:)`.
    ///   - position: The operation to draw the new things before. `nil` draws them last, on top.
    mutating func rewritePage(
        at index: Int, _ interpretation: Interpretation, removing glyphs: [PageGlyph] = [],
        replacing operations: [Int: [ContentStream.Operation]] = [:], adding addition: PageAddition = PageAddition(),
        inserting block: [ContentStream.Operation] = [], at position: Int? = nil
    ) throws {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        var replacements = operations
        let original = interpretation.streams[0].content

        var removedByOperation: [Int: Set<Int>] = [:]
        for glyph in glyphs where glyph.source.stream == 0 && !glyph.isImplied {
            removedByOperation[glyph.source.operation, default: []].insert(glyph.index)
        }
        if !removedByOperation.isEmpty {
            // What each affected operation shows, glyph by glyph.
            var shown: [Int: [RawGlyph]] = [:]
            for glyph in interpretation.glyphs where glyph.source.stream == 0 && removedByOperation[glyph.source.operation] != nil {
                shown[glyph.source.operation, default: []].append(glyph)
            }
            for (operationIndex, removed) in removedByOperation {
                guard original.operations.indices.contains(operationIndex), let raw = shown[operationIndex], let first = raw.first else { continue }
                replacements[operationIndex] = Self.stripped(original.operations[operationIndex], removing: removed, glyphs: raw, font: interpretation.fonts[first.font])
            }
        }

        // Everything new, made to draw the same wherever it is put.
        var new = block
        if !addition.isEmpty {
            let text = "q\n\(interpretation.geometry.fromDisplay.operands) cm\n" + addition.operators + "Q\n"
            new.append(contentsOf: ContentStream.operations(parsing: text))
        }
        func kept(_ operationIndex: Int) -> [ContentStream.Operation] {
            replacements[operationIndex] ?? [original.operations[operationIndex]]
        }

        var result: [ContentStream.Operation] = []
        if let position, position < original.operations.count, !new.isEmpty {
            // In the middle of the page's drawing, whatever state is in force there is
            // closed, the new things are drawn, and the state is set up again as it was.
            let state = ContentStream.drawingState(before: position, in: original.operations)
            // State set outside any saved level cannot be undone, unless the whole page
            // is put inside a level of its own.
            let wraps = !state.levels[0].isEmpty
            let save = ContentStream.Operation("q"), restore = ContentStream.Operation("Q")
            if wraps { result.append(save) }
            for operationIndex in original.operations.indices {
                if operationIndex == position {
                    result.append(contentsOf: state.marked.map { _ in ContentStream.Operation("EMC") })
                    result.append(contentsOf: Array(repeating: restore, count: state.levels.count - 1 + (wraps ? 1 : 0)))
                    result.append(contentsOf: new)
                    for (depth, level) in state.levels.enumerated() {
                        if depth > 0 || wraps { result.append(save) }
                        result.append(contentsOf: level)
                    }
                    result.append(contentsOf: state.marked)
                }
                result.append(contentsOf: kept(operationIndex))
            }
            if wraps { result.append(restore) }
        } else {
            // Drawing added after content that leaves its coordinate system changed, or state
            // saved, would land in the wrong place, so such content is fenced off first.
            let fences = !new.isEmpty && !interpretation.endsClean
            if fences { result.append(ContentStream.Operation("q")) }
            for operationIndex in original.operations.indices { result.append(contentsOf: kept(operationIndex)) }
            if fences { result.append(ContentStream.Operation("Q")) }
            result.append(contentsOf: new)
        }
        var content = original
        content.operations = result
        try setContentStream(content, forPageAt: index)

        guard !addition.fonts.isEmpty || !addition.xObjects.isEmpty || !addition.graphicsStates.isEmpty else { return }
        // A copy of the resources for this page alone; other pages may share the original.
        let page = pages[index]
        var resources = try inherited("Resources", forPage: page).map(resolve)?.dictionaryValue ?? [:]
        if !addition.fonts.isEmpty {
            let fonts = try value("Font", in: resources).dictionaryValue ?? [:]
            resources["Font"] = .dictionary(fonts.merging(addition.fonts) { _, new in new })
        }
        if !addition.xObjects.isEmpty {
            let xObjects = try value("XObject", in: resources).dictionaryValue ?? [:]
            resources["XObject"] = .dictionary(xObjects.merging(addition.xObjects) { _, new in new })
        }
        if !addition.graphicsStates.isEmpty {
            let states = try value("ExtGState", in: resources).dictionaryValue ?? [:]
            resources["ExtGState"] = .dictionary(states.merging(addition.graphicsStates) { _, new in new })
        }
        try update(page) { $0["Resources"] = .dictionary(resources) }
    }

    /// A text-showing operation with some of its glyphs replaced by the space they took up.
    static func stripped(_ operation: ContentStream.Operation, removing removed: Set<Int>, glyphs: [RawGlyph], font: PageFont) -> [ContentStream.Operation] {
        var elements: [PDFObject]
        var lead: [ContentStream.Operation] = []
        switch operation.name {
        case "Tj":
            elements = operation.operands.prefix(1).map(\.self)
        case "TJ":
            elements = operation.operands.first?.arrayValue ?? []
        case "'":
            lead = [ContentStream.Operation("T*")]
            elements = operation.operands.suffix(1).map(\.self)
        case "\"":
            // The two spacings it sets apply to what follows as well.
            if operation.operands.count >= 3 {
                lead = [ContentStream.Operation("Tw", [operation.operands[0]]), ContentStream.Operation("Tc", [operation.operands[1]])]
            }
            lead.append(ContentStream.Operation("T*"))
            elements = operation.operands.suffix(1).map(\.self)
        default:
            return [operation]
        }

        var output: [PDFObject] = []
        var kept = Data()
        var gap = 0.0
        var counter = 0
        func flushText() {
            if !kept.isEmpty { output.append(.string(kept)) }
            kept = Data()
        }
        func flushGap() {
            if gap != 0 { output.append(.real((gap * 1000).rounded() / 1000)) }
            gap = 0
        }
        for element in elements {
            if let string = element.stringValue {
                let codes = font.codes(in: string)
                for code in codes {
                    defer { counter += 1 }
                    if removed.contains(counter), counter < glyphs.count {
                        let glyph = glyphs[counter]
                        flushText()
                        // A number in the array moves the pen left by that many thousandths of
                        // the font size; the glyph moved it right by its width and spacing.
                        let size = glyph.textFontSize
                        let spacing = glyph.charSpacing + (code == 32 && font.codeLength == 1 ? glyph.wordSpacing : 0)
                        gap -= glyph.width + (size != 0 ? spacing * 1000 / size : 0)
                    } else {
                        flushGap()
                        kept.append(contentsOf: font.bytes(for: code))
                    }
                }
            } else if let adjustment = element.doubleValue {
                flushText()
                gap += adjustment
            }
        }
        flushText()
        flushGap()
        return lead + [ContentStream.Operation("TJ", [.array(output)])]
    }
}
