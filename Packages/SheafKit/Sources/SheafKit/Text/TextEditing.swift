import Foundation

/// One piece of a block's text as a paragraph: a glyph, a typed character, a space
/// between words, or a break between lines.
struct FlowItem {
    var text: String
    /// The glyph the page draws for it. `nil` for typed characters and for spaces and
    /// breaks the page only implies.
    var glyph: PageGlyph?
    /// Where the look comes from: the glyph itself, or its neighbor.
    var style: PageGlyph
    /// The line of the block the item was on. -1 for typed characters.
    var line: Int
    var isBreak = false

    var isSpace: Bool { text == " " }
}

extension TextBlock {
    /// Which of the block's lines start a paragraph. The first always does.
    ///
    /// A line starts one when the line before it stops well short of the block's right
    /// edge, or when it starts further in or out than the body of the text does, as the
    /// first line of an indented paragraph or of a list item does.
    var paragraphStarts: [Bool] {
        var starts = [Bool](repeating: false, count: lines.count)
        guard !starts.isEmpty else { return starts }
        starts[0] = true
        guard lines.count > 1 else { return starts }
        // Running text has long lines, each as full as its words allow. Short lines one
        // under the other, as in an address, a list of names or a heading on two lines,
        // look the same to a ruler but were each ended on purpose, so each stays a line
        // of its own. Justified text is running text whatever its width.
        let longest = lines.map { line in line.glyphs.reduce(0) { $0 + ($1.isImplied ? 1 : $1.text.count) } }.max() ?? 0
        if alignment != .justified, longest < 34 {
            return [Bool](repeating: true, count: lines.count)
        }
        let flows = alignment == .left || alignment == .justified
        let size = fontSize
        let right = frame.x + frame.width
        // Where the body of the text starts: where most lines do.
        var bodyLeft = frame.x
        if flows, lines.count >= 3 {
            let places = Dictionary(grouping: lines, by: { ($0.frame.x * 2).rounded() / 2 })
            bodyLeft = places.max { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }?.key ?? frame.x
        }
        for index in 1..<lines.count {
            let previous = lines[index - 1], line = lines[index]
            let stopsShort = previous.frame.width < frame.width * 0.72 && alignment != .center && alignment != .right
            let endsEarly = alignment == .justified && previous.frame.x + previous.frame.width < right - size * 2
            let stepsAside = flows && lines.count >= 3 && abs(line.frame.x - bodyLeft) > size * 0.8
            starts[index] = stopsShort || endsEarly || stepsAside
        }
        return starts
    }

    /// How far in from the block's left edge the first line of a paragraph starts, and
    /// how far in its other lines do.
    public var indents: (first: Double, rest: Double) {
        guard alignment == .left || alignment == .justified, lines.count > 1 else { return (0, 0) }
        let starts = paragraphStarts
        func median(_ values: [Double]) -> Double? {
            let sorted = values.sorted()
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }
        let first = median(zip(lines, starts).filter { $0.1 }.map { $0.0.frame.x - frame.x }) ?? 0
        let rest = median(zip(lines, starts).filter { !$0.1 }.map { $0.0.frame.x - frame.x }) ?? first
        return (max(first, 0), max(rest, 0))
    }

    /// The extra distance between the last line of one paragraph and the first of the next.
    public var paragraphGap: Double {
        let starts = paragraphStarts
        let drops = lines.indices.dropFirst().filter { starts[$0] }.map { lines[$0 - 1].baseline - lines[$0].baseline - leading }.sorted()
        return drops.isEmpty ? 0 : max(drops[drops.count / 2], 0)
    }

    /// The usual width of the gap between two words.
    var wordGap: Double? {
        var gaps: [Double] = []
        for line in lines {
            var before: PageGlyph?
            var sawSpace = false
            for glyph in line.glyphs {
                if glyph.text == " " {
                    sawSpace = true
                } else {
                    if sawSpace, let before { gaps.append(glyph.origin.x - before.origin.x - before.advance) }
                    before = glyph
                    sawSpace = false
                }
            }
        }
        gaps = gaps.filter { $0 > 0 }.sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    /// The block's text in reading order, with the breaks between paragraphs made explicit.
    var flow: [FlowItem] {
        var items: [FlowItem] = []
        let starts = paragraphStarts
        for (index, line) in lines.enumerated() {
            for glyph in line.glyphs {
                items.append(FlowItem(text: glyph.text, glyph: glyph.isImplied ? nil : glyph, style: glyph, line: index))
            }
            guard index + 1 < lines.count, let last = line.glyphs.last else { continue }
            if starts[index + 1] {
                items.append(FlowItem(text: "\n", glyph: nil, style: last, line: index, isBreak: true))
            } else if last.text != " " {
                items.append(FlowItem(text: " ", glyph: nil, style: last, line: index))
            }
        }
        return items
    }
}

/// How a block's look may be changed when it is set again.
public struct TextRestyle: Sendable, Equatable {
    /// An installed font to set the whole block in. `nil` keeps each character's own font.
    public var fontName: String?
    public var fontSize: Double?
    public var color: PDFColor?
    /// Where lines start and where they have to end, on the page as displayed: the
    /// sides of the box the text is set in. `nil` keeps the side the block has.
    public var left: Double?
    public var right: Double?
    /// How the lines sit between the sides. `nil` keeps the block's own alignment.
    public var alignment: TextBlock.Alignment?
    /// From one baseline to the next, in points. `nil` keeps the block's spacing.
    public var leading: Double?
    /// The extra distance before a paragraph, in points. `nil` keeps the block's.
    public var paragraphGap: Double?
    /// Whether the text is set in the bold or the italic member of its font's family.
    /// `nil` keeps each character as it is.
    public var isBold: Bool?
    public var isItalic: Bool?

    public init(
        fontName: String? = nil, fontSize: Double? = nil, color: PDFColor? = nil, left: Double? = nil, right: Double? = nil,
        alignment: TextBlock.Alignment? = nil, leading: Double? = nil, paragraphGap: Double? = nil, isBold: Bool? = nil, isItalic: Bool? = nil
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.left = left
        self.right = right
        self.alignment = alignment
        self.leading = leading
        self.paragraphGap = paragraphGap
        self.isBold = isBold
        self.isItalic = isItalic
    }

    /// Whether words have to be set again in an installed font, rather than kept or
    /// written in the document's own.
    var reshapes: Bool { fontName != nil || fontSize != nil || isBold != nil || isItalic != nil }
}

extension PDFEditor {
    private func editable(block id: Int, pageAt index: Int) throws -> (Interpretation, PageContent, TextBlock) {
        let interpretation = try interpret(pageAt: index)
        let content = Self.content(from: interpretation, source: self)
        guard let block = content.blocks.first(where: { $0.id == id }) else { throw SheafError.malformed("the page has no such block of text") }
        guard block.isEditable else { throw SheafError.unsupported("changing this text") }
        return (interpretation, content, block)
    }

    func fontPrefix() -> String { "SheafT\(nextObjectNumber)x" }

    // MARK: Whole blocks

    /// Takes a block of text off the page.
    public mutating func removeText(ofBlock id: Int, onPageAt index: Int) throws {
        let (interpretation, _, block) = try editable(block: id, pageAt: index)
        try rewritePage(at: index, interpretation, removing: block.lines.flatMap(\.glyphs))
    }

    /// Moves a block of text. Every glyph keeps its place within the block.
    public mutating func moveText(ofBlock id: Int, onPageAt index: Int, dx: Double, dy: Double) throws {
        try redraw(block: id, pageAt: index, dx: dx, dy: dy, color: nil)
    }

    /// Sets a block of text a second time, on top of everything, moved by an offset.
    public mutating func duplicateText(ofBlock id: Int, onPageAt index: Int, dx: Double, dy: Double) throws {
        let (interpretation, _, block) = try editable(block: id, pageAt: index)
        var emitter = TextEmitter(fontPrefix: fontPrefix(), in: self)
        for glyph in block.lines.flatMap(\.glyphs) where !glyph.isImplied {
            guard let resource = interpretation.fontNames[glyph.font] else { throw SheafError.unsupported("changing this text") }
            emitter.exact(glyph, font: interpretation.fonts[glyph.font], resource: resource, dx: dx, dy: dy)
        }
        let addition = emitter.addition(in: &self)
        try rewritePage(at: index, interpretation, adding: addition)
    }

    /// Changes the color of a block of text.
    public mutating func setTextColor(_ color: PDFColor, ofBlock id: Int, onPageAt index: Int) throws {
        try redraw(block: id, pageAt: index, dx: 0, dy: 0, color: color)
    }

    private mutating func redraw(block id: Int, pageAt index: Int, dx: Double, dy: Double, color: PDFColor?) throws {
        let (interpretation, _, block) = try editable(block: id, pageAt: index)
        var emitter = TextEmitter(fontPrefix: fontPrefix(), in: self)
        let glyphs = block.lines.flatMap(\.glyphs).filter { !$0.isImplied }
        for glyph in glyphs {
            guard let resource = interpretation.fontNames[glyph.font] else { throw SheafError.unsupported("changing this text") }
            emitter.exact(glyph, font: interpretation.fonts[glyph.font], resource: resource, dx: dx, dy: dy, color: color)
        }
        let addition = emitter.addition(in: &self)
        try rewritePage(at: index, interpretation, removing: glyphs, adding: addition)
    }

    // MARK: Changing the words

    /// Replaces a block's text.
    ///
    /// - Parameter newText: The block as a paragraph, in the form `TextBlock.flowingText`
    ///   gives it: lines that run on are joined, and a line break starts a new line.
    ///
    /// What did not change keeps its glyphs, and lines that are not affected are not
    /// touched at all. Typed characters take the look of what is next to them. They use
    /// the document's own font where it has the characters; a word with a character the
    /// font lacks is set in the closest installed font. From the first changed line on,
    /// words are fitted to the block's width again.
    public mutating func replaceText(ofBlock id: Int, onPageAt index: Int, with newText: String, restyle: TextRestyle = TextRestyle()) throws {
        let (interpretation, content, block) = try editable(block: id, pageAt: index)
        var restyle = restyle
        let page = try pageIDs()[index]
        let boxes = try textBoxes(onPage: page)
        let top = block.frame.y + block.frame.height
        // The box Sheaf set this block in before, if it did: the lines of a centered or
        // right-aligned paragraph are narrower than their box, and do not say how wide it was.
        let known = boxes.firstIndex { box in
            abs(box.top - top) < 3 && box.left <= block.frame.x + 1 && box.right >= block.frame.x + block.frame.width - 1
        }
        if restyle.left == nil, restyle.right == nil {
            if let known {
                restyle.left = boxes[known].left
                restyle.right = boxes[known].right
            } else if block.lines.count == 1, restyle.alignment != nil {
                // A single line has no width of its own to center or right-align it in. It
                // takes the page's column instead.
                restyle.left = content.column.left
                restyle.right = content.column.right
            }
        }
        var emitter = TextEmitter(fontPrefix: fontPrefix(), in: self)
        guard let removed = try plan(replacing: block, with: newText, restyle: restyle, interpretation, emitter: &emitter) else { return }
        let addition = emitter.addition(in: &self)
        try rewritePage(at: index, interpretation, removing: removed, adding: addition)

        // Remembered for the next time, when the box is not simply the lines' own.
        var kept = boxes
        if let known { kept.remove(at: known) }
        let alignment = restyle.alignment ?? block.alignment
        if restyle.left != nil || restyle.right != nil || alignment == .center || alignment == .right {
            let left = restyle.left ?? block.frame.x
            let right = restyle.right ?? content.rightLimit(of: block)
            kept.append((left, right, top))
        }
        if known != nil || kept.count != boxes.count {
            try setTextBoxes(kept, onPage: page)
        }
    }

    /// Where Sheaf set paragraphs of a page, as displayed: their sides, and the top of their first line.
    private func textBoxes(onPage page: ObjectID) throws -> [(left: Double, right: Double, top: Double)] {
        guard let dictionary = try object(page).dictionaryValue else { return [] }
        return try (value(Self.textBoxesKey, in: dictionary).arrayValue ?? []).compactMap { entry in
            guard let numbers = try resolve(entry).arrayValue?.compactMap(\.doubleValue), numbers.count == 3 else { return nil }
            return (numbers[0], numbers[1], numbers[2])
        }
    }

    private mutating func setTextBoxes(_ boxes: [(left: Double, right: Double, top: Double)], onPage page: ObjectID) throws {
        try update(page) { dictionary in
            dictionary[Self.textBoxesKey] = boxes.isEmpty ? nil : .array(boxes.map { [.real($0.left), .real($0.right), .real($0.top)] })
        }
    }

    /// A page's own entry for the boxes, which other programs pass over.
    static let textBoxesKey: PDFName = "SheafTextBoxes"

    /// Replaces the text of several blocks of one page at once, which reads and writes
    /// the page once however many blocks change.
    ///
    /// - Parameter changes: Blocks by their place among the page's blocks, each with its new text.
    /// - Returns: How many blocks were changed. Blocks that cannot be changed are skipped.
    @discardableResult
    mutating func replaceText(inBlocks changes: [(id: Int, text: String)], onPageAt index: Int) throws -> Int {
        let interpretation = try interpret(pageAt: index)
        let content = Self.content(from: interpretation, source: self)
        var emitter = TextEmitter(fontPrefix: fontPrefix(), in: self)
        var removed: [PageGlyph] = []
        var count = 0
        for change in changes {
            guard let block = content.blocks.first(where: { $0.id == change.id }), block.isEditable,
                  let glyphs = try plan(replacing: block, with: change.text, restyle: TextRestyle(), interpretation, emitter: &emitter)
            else { continue }
            removed.append(contentsOf: glyphs)
            count += 1
        }
        guard count > 0 else { return 0 }
        let addition = emitter.addition(in: &self)
        try rewritePage(at: index, interpretation, removing: removed, adding: addition)
        return count
    }

    /// Works out what replacing a block's text takes: which glyphs come off the page,
    /// and, written into the emitter, what goes on in their place.
    ///
    /// - Returns: The glyphs to remove, or `nil` when the text is what the block already says.
    private func plan(
        replacing block: TextBlock, with newText: String, restyle: TextRestyle, _ interpretation: Interpretation, emitter: inout TextEmitter
    ) throws -> [PageGlyph]? {
        let old = block.flow
        guard !old.isEmpty else { throw SheafError.unsupported("changing this text") }
        let oldText = old.map(\.text).joined()
        let isRestyled = restyle != TextRestyle()
        guard newText != oldText || isRestyled else { return nil }
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return block.lines.flatMap(\.glyphs)
        }

        // What stays at the start and at the end; the middle is what was typed. Compared
        // scalar by scalar: a glyph may be only a part of a character, as a vowel sign is.
        let oldScalars = Array(oldText.unicodeScalars), newScalars = Array(newText.unicodeScalars)
        var prefix = 0
        while prefix < oldScalars.count, prefix < newScalars.count, oldScalars[prefix] == newScalars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldScalars.count - prefix, suffix < newScalars.count - prefix,
              oldScalars[oldScalars.count - 1 - suffix] == newScalars[newScalars.count - 1 - suffix] { suffix += 1 }

        // Whole items inside the unchanged start and end.
        var kept = 0, covered = 0
        while kept < old.count, covered + old[kept].text.unicodeScalars.count <= prefix {
            covered += old[kept].text.unicodeScalars.count
            kept += 1
        }
        var keptAtEnd = 0, coveredAtEnd = 0
        while keptAtEnd < old.count - kept, coveredAtEnd + old[old.count - 1 - keptAtEnd].text.unicodeScalars.count <= suffix {
            coveredAtEnd += old[old.count - 1 - keptAtEnd].text.unicodeScalars.count
            keptAtEnd += 1
        }
        var typedText = String.UnicodeScalarView()
        typedText.append(contentsOf: newScalars[covered..<(newScalars.count - coveredAtEnd)])
        let typed = Array(String(typedText))
        let style = kept > 0 ? old[kept - 1].style : (keptAtEnd > 0 ? old[old.count - keptAtEnd].style : old[0].style)
        var items = Array(old[..<kept])
        for character in typed {
            items.append(FlowItem(text: String(character), glyph: nil, style: style, line: -1, isBreak: character.isNewline))
        }
        items.append(contentsOf: old[(old.count - keptAtEnd)...])

        // The first line that changes. Everything before it stays as the page has it.
        // The line of the last unchanged item counts too: typing at the start of a line
        // may belong to the end of the one before.
        var firstLine = kept < old.count ? old[kept].line : block.lines.count - 1
        if kept > 0 { firstLine = min(firstLine, old[kept - 1].line) }
        if isRestyled { firstLine = 0 }
        // Text written with codes the font has no glyphs for draws nothing. Its lines are
        // set again, now in a font that shows it.
        if let unseen = old.first(where: { item in item.glyph.map { !interpretation.fonts[$0.font].draws($0.code) } ?? false }) {
            firstLine = min(firstLine, unseen.line)
        }
        firstLine = max(min(firstLine, block.lines.count - 1), 0)
        let start = items.firstIndex { $0.line >= firstLine || $0.line == -1 } ?? items.count

        // Whether that line starts a paragraph: the block does, and so does what follows a break.
        let startsParagraph = start == 0 || items[start - 1].isBreak
        return try relay(Array(items[start...]), of: block, fromLine: firstLine, startingParagraph: startsParagraph, interpretation, restyle: restyle, emitter: &emitter)
    }

    /// A word ready to be placed on a line.
    private struct Word {
        enum Drawing {
            /// Glyphs kept exactly as they were, as a group.
            case exact([PageGlyph])
            /// Codes in the document's own fonts, each with the look it takes.
            case codes([(code: Int, style: PageGlyph)])
            /// Text in an installed font.
            case shaped(TextOutliner.ShapedLine, size: Double, color: PDFColor)
        }

        var drawing: Drawing
        var width: Double
        var spaceBefore: Double
        var startsParagraph: Bool
        var identity: [String]
    }

    private struct LaidLine {
        var words: [Word] = []
        var width = 0.0
        var startsParagraph = false
        var endsParagraph = false
        /// The old line this one is, word for word, when it is one.
        var verbatim: Int?
    }

    /// Sets items in lines from one of a block's lines on, and writes the result to the page.
    ///
    /// - Returns: The glyphs of the block that the new lines take the place of.
    private func relay(
        _ items: [FlowItem], of block: TextBlock, fromLine firstLine: Int, startingParagraph firstStartsParagraph: Bool,
        _ interpretation: Interpretation, restyle: TextRestyle, emitter: inout TextEmitter
    ) throws -> [PageGlyph] {
        let fonts = interpretation.fonts

        // Words, with the space that comes before each.
        var words: [Word] = []
        var current: [FlowItem] = []
        var pendingSpace = 0.0
        var pendingBreak = false
        let measuredGap = block.wordGap
        func naturalSpace(_ style: PageGlyph) -> Double {
            let font = fonts[style.font]
            let size = restyle.fontSize ?? style.fontSize
            // The font's own space, when it has one worth the name. Fonts made by TeX and
            // its kin have none, and their pages leave gaps instead; there the block's
            // usual gap is the measure.
            if restyle.fontName == nil, let code = font.code(for: " ") {
                let width = font.width(of: code) * style.matrix.a / 1000 * (restyle.fontSize.map { $0 / max(style.fontSize, 0.01) } ?? 1)
                if width > size * 0.12 { return width }
            }
            if restyle.fontName == nil, let measuredGap, style.fontSize > 0 { return measuredGap * size / style.fontSize }
            return size * 0.28
        }
        func finishWord() {
            guard !current.isEmpty else { return }
            defer { current = [] }
            // A word with glyphs that draw nothing is treated as newly typed, so that it shows.
            let unseen = current.contains { item in item.glyph.map { !fonts[$0.font].draws($0.code) } ?? false }
            let identity = current.map { item in item.glyph.map { unseen ? "+\(item.text)" : "\($0.source.operation)/\($0.index)" } ?? "+\(item.text)" }
            let space = words.isEmpty && !pendingBreak ? 0 : pendingSpace
            // A word nobody touched is drawn exactly as it was, kerning and all.
            let glyphs = current.compactMap(\.glyph)
            if !unseen, !restyle.reshapes, glyphs.count == current.count, Set(current.map(\.line)).count == 1, let first = glyphs.first, let last = glyphs.last {
                var kept = glyphs
                if let color = restyle.color { for position in kept.indices { kept[position].color = color } }
                words.append(Word(drawing: .exact(kept), width: last.origin.x + last.advance - first.origin.x, spaceBefore: space, startsParagraph: pendingBreak, identity: identity))
                return
            }
            // Otherwise in the document's own fonts, if they have every character.
            var codes: [(code: Int, style: PageGlyph)] = []
            if !restyle.reshapes {
                for item in current {
                    if let glyph = item.glyph, !unseen {
                        codes.append((glyph.code, glyph))
                    } else if interpretation.fontNames[item.style.font] != nil, let code = fonts[item.style.font].code(for: item.text) {
                        codes.append((code, item.style))
                    } else {
                        codes = []
                        break
                    }
                }
            }
            if codes.count == current.count {
                let width = codes.reduce(0) { $0 + fonts[$1.style.font].width(of: $1.code) * $1.style.matrix.a / 1000 }
                words.append(Word(drawing: .codes(codes), width: width, spaceBefore: space, startsParagraph: pendingBreak, identity: identity))
                return
            }
            // Or the whole word in the closest installed font.
            let style = current[0].style
            let font = fonts[style.font]
            var name = restyle.fontName ?? FontMatcher.installedName(for: font.baseName, traits: font.traits)
            if restyle.isBold != nil || restyle.isItalic != nil { name = FontMatcher.styled(name, bold: restyle.isBold, italic: restyle.isItalic) }
            let size = restyle.fontSize ?? style.fontSize
            let line = TextOutliner.shape(current.map(\.text).joined(), fontName: name, fontSize: size)
            words.append(Word(drawing: .shaped(line, size: size, color: restyle.color ?? style.color), width: line.width, spaceBefore: space, startsParagraph: pendingBreak, identity: identity))
        }
        for item in items {
            if item.isBreak {
                finishWord()
                pendingBreak = true
                pendingSpace = 0
            } else if item.isSpace {
                if !current.isEmpty {
                    finishWord()
                    pendingBreak = false
                    pendingSpace = 0
                }
                pendingSpace += naturalSpace(item.style)
            } else {
                current.append(item)
            }
        }
        finishWord()

        // Lines, each as full as it gets.
        // The box the text is set in: the block's own, unless it is being given another.
        let left = restyle.left ?? block.frame.x
        let right = max(restyle.right ?? PageContent(blocks: [], images: [], geometry: interpretation.geometry).rightLimit(of: block), left + 1)
        let alignment = restyle.alignment ?? block.alignment
        let indents = alignment == .left || alignment == .justified ? block.indents : (first: 0.0, rest: 0.0)
        func lineStart(_ line: LaidLine) -> Double { left + (line.startsParagraph ? indents.first : indents.rest) }
        // The old lines as words, to recognize them when they come around again.
        let oldStarts = block.paragraphStarts
        var oldWords: [Int: [[String]]] = [:]
        var oldLineByFirstGlyph: [String: Int] = [:]
        if restyle == TextRestyle() {
            for (lineIndex, line) in block.lines.enumerated() where lineIndex >= firstLine {
                var lineWords: [[String]] = [[]]
                for glyph in line.glyphs {
                    if glyph.text == " " {
                        if lineWords[lineWords.count - 1].isEmpty == false { lineWords.append([]) }
                    } else if !glyph.isImplied {
                        lineWords[lineWords.count - 1].append("\(glyph.source.operation)/\(glyph.index)")
                    }
                }
                lineWords.removeAll(where: \.isEmpty)
                guard let first = lineWords.first?.first else { continue }
                oldWords[lineIndex] = lineWords
                oldLineByFirstGlyph[first] = lineIndex
            }
        }

        var lines: [LaidLine] = [LaidLine(startsParagraph: firstStartsParagraph)]
        var position = 0
        var breaksBeforeNext = false
        while position < words.count {
            let word = words[position]
            if !lines[lines.count - 1].words.isEmpty, word.startsParagraph || breaksBeforeNext {
                if word.startsParagraph { lines[lines.count - 1].endsParagraph = true }
                lines.append(LaidLine(startsParagraph: word.startsParagraph))
            } else if lines[lines.count - 1].words.isEmpty, word.startsParagraph {
                lines[lines.count - 1].startsParagraph = true
            }
            breaksBeforeNext = false
            let number = lines.count - 1

            // A line that starts where an old line started, and whose words are all still
            // there, is that line again: whoever set the page chose where it ends, and
            // squeezed or stretched its spaces to suit.
            if lines[number].words.isEmpty, let first = word.identity.first, let old = oldLineByFirstGlyph[first], let known = oldWords[old],
               oldStarts[old] == lines[number].startsParagraph, position + known.count <= words.count,
               known.indices.allSatisfy({ words[position + $0].identity == known[$0] && ($0 == 0 || !words[position + $0].startsParagraph) }) {
                var taken = Array(words[position..<(position + known.count)])
                taken[0].spaceBefore = 0
                lines[number].words = taken
                lines[number].width = taken.reduce(0) { $0 + $1.spaceBefore + $1.width }
                lines[number].verbatim = old
                position += known.count
                breaksBeforeNext = true
                continue
            }

            let available = right - lineStart(lines[number])
            // Justified lines may close up their spaces a little to take one more word.
            let spaces = lines[number].words.dropFirst().reduce(word.spaceBefore) { $0 + $1.spaceBefore }
            let squeeze = alignment == .justified ? spaces * 0.15 : 0
            let fits = lines[number].width + word.spaceBefore + word.width <= available + 0.5 + squeeze
            if !lines[number].words.isEmpty, !fits { lines.append(LaidLine()) }
            var placed = word
            if lines[lines.count - 1].words.isEmpty { placed.spaceBefore = 0 }
            lines[lines.count - 1].words.append(placed)
            lines[lines.count - 1].width += placed.spaceBefore + placed.width
            position += 1
        }
        lines.removeAll { $0.words.isEmpty }
        if let last = lines.indices.last { lines[last].endsParagraph = true }

        // Baselines. A line that takes the place of an old line of the same kind sits
        // where that one sat. Once the lines no longer match up, they follow on at the
        // block's usual spacing, with its usual extra space before a paragraph.
        var leading = block.leading
        var paragraphGap = block.paragraphGap
        if let newSize = restyle.fontSize, let oldSize = block.lines.first?.fontSize, oldSize > 0 {
            leading *= newSize / oldSize
            paragraphGap *= newSize / oldSize
        }
        if let chosen = restyle.leading { leading = max(chosen, 1) }
        if let chosen = restyle.paragraphGap { paragraphGap = max(chosen, 0) }
        var baselines: [Double] = []
        var matchesOld = restyle.fontSize == nil && restyle.leading == nil && restyle.paragraphGap == nil
        for (number, line) in lines.enumerated() {
            let old = firstLine + number
            if number == 0 {
                baselines.append(block.lines[min(max(old, 0), block.lines.count - 1)].baseline)
                continue
            }
            matchesOld = matchesOld && block.lines.indices.contains(old) && oldStarts[old] == line.startsParagraph
            if matchesOld {
                baselines.append(block.lines[old].baseline)
            } else {
                baselines.append(baselines[number - 1] - leading - (line.startsParagraph ? paragraphGap : 0))
            }
        }
        func baseline(_ number: Int) -> Double { baselines[number] }

        // Lines that come out exactly as they were stay as the page has them.
        var untouched: Set<Int> = []
        for (number, line) in lines.enumerated() {
            let oldIndex = firstLine + number
            if let old = line.verbatim {
                // An old line again: where it was, or moved up or down as it is.
                let drop = baseline(number) - block.lines[old].baseline
                if old == oldIndex, abs(drop) < 0.001 {
                    untouched.insert(old)
                } else {
                    for glyph in block.lines[old].glyphs where !glyph.isImplied {
                        guard let resource = interpretation.fontNames[glyph.font] else { continue }
                        emitter.exact(glyph, font: fonts[glyph.font], resource: resource, dy: drop)
                    }
                }
                continue
            }
            if restyle == TextRestyle(), block.lines.indices.contains(oldIndex) {
                let before = block.lines[oldIndex].glyphs.filter { !$0.isImplied && $0.text != " " }.map { "\($0.source.operation)/\($0.index)" }
                if before == line.words.flatMap(\.identity) {
                    untouched.insert(oldIndex)
                    continue
                }
            }
            let start = lineStart(line)
            let available = right - start
            var gapStretch = 0.0
            var x = start
            switch alignment {
            case .justified:
                let extra = available - line.width
                // Spread to fill the line. The last line of a paragraph is only ever closed up.
                if line.words.count > 1, extra < available * 0.35, extra < 0 || !line.endsParagraph { gapStretch = extra / Double(line.words.count - 1) }
            case .center: x = (left + right) / 2 - line.width / 2
            case .right: x = right - line.width
            case .left: break
            }
            let y = baseline(number)
            for (position, word) in line.words.enumerated() {
                if position > 0 { x += word.spaceBefore + gapStretch }
                switch word.drawing {
                case .exact(let glyphs):
                    guard let first = glyphs.first else { continue }
                    for glyph in glyphs {
                        guard let resource = interpretation.fontNames[glyph.font] else { continue }
                        emitter.exact(glyph, font: fonts[glyph.font], resource: resource, dx: x - first.origin.x, dy: y - first.origin.y)
                    }
                case .codes(let codes):
                    // Runs of one font, size and color, each set from where it starts.
                    var runStart = x, cursor = x
                    var run: [Int] = []
                    var runStyle = codes[0].style
                    func flush() {
                        guard !run.isEmpty, let resource = interpretation.fontNames[runStyle.font] else { return }
                        emitter.run(codes: run, font: fonts[runStyle.font], resource: resource, size: runStyle.matrix.d, x: runStart, baseline: y, color: restyle.color ?? runStyle.color)
                        run = []
                    }
                    for (code, style) in codes {
                        if style.font != runStyle.font || style.matrix.d != runStyle.matrix.d || style.color != runStyle.color || abs(style.matrix.a - style.matrix.d) > 0.001 {
                            flush()
                            runStart = cursor
                            runStyle = style
                        }
                        if abs(style.matrix.a - style.matrix.d) > 0.001 {
                            // Squeezed or stretched type: placed glyph by glyph to keep its proportions.
                            var single = style
                            single.code = code
                            single.matrix.e = cursor
                            single.matrix.f = y
                            if let resource = interpretation.fontNames[style.font] {
                                emitter.exact(single, font: fonts[style.font], resource: resource, color: restyle.color)
                            }
                            cursor += fonts[style.font].width(of: code) * style.matrix.a / 1000
                            runStart = cursor
                            continue
                        }
                        run.append(code)
                        cursor += fonts[style.font].width(of: code) * style.matrix.a / 1000
                    }
                    flush()
                case .shaped(let shaped, let size, let color):
                    emitter.shaped(shaped, size: size, x: x, baseline: y, color: color)
                }
                x += word.width
            }
        }

        var removed: [PageGlyph] = []
        for (lineIndex, line) in block.lines.enumerated() where lineIndex >= firstLine && !untouched.contains(lineIndex) {
            removed.append(contentsOf: line.glyphs)
        }
        return removed
    }

    // MARK: New text

    /// Adds text to a page as part of its content, set in an installed font.
    ///
    /// - Parameters:
    ///   - origin: The top left corner of the text, on the page as displayed.
    ///   - width: Lines wrap at this width. `nil` keeps each paragraph on one line.
    public mutating func addText(
        _ text: String, toPageAt index: Int, at origin: PDFPoint, width: Double? = nil,
        fontName: String = "Helvetica", fontSize: Double = 12, color: PDFColor = .black
    ) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let interpretation = try interpret(pageAt: index)
        var emitter = TextEmitter(fontPrefix: fontPrefix(), in: self)
        let metrics = FontMatcher.verticalMetrics(fontName: fontName)
        let ascent = metrics.ascent / 1000 * fontSize
        let leading = max((metrics.ascent + metrics.descent) / 1000 * fontSize * 1.15, fontSize)
        var top = origin.y
        for paragraph in text.components(separatedBy: .newlines) {
            let lines: [TextOutliner.ShapedLine] = width.map {
                TextOutliner.shape(paragraph, fontName: fontName, fontSize: fontSize, width: $0, alignment: .left)
            } ?? [TextOutliner.shape(paragraph, fontName: fontName, fontSize: fontSize)]
            if lines.isEmpty { top -= leading }
            for (number, line) in lines.enumerated() {
                // Wrapped lines say how far down they are; a single line starts at the top.
                let baseline = width == nil ? top - ascent : top - line.baselineFromTop
                emitter.shaped(line, size: fontSize, x: origin.x + line.x, baseline: baseline, color: color)
                if number == lines.count - 1 { top = width == nil ? top - leading : baseline - (leading - ascent) }
            }
        }
        let addition = emitter.addition(in: &self)
        try rewritePage(at: index, interpretation, adding: addition)
    }
}
