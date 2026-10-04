import Foundation

/// One character on a page, with where it is.
public struct PageGlyph: Sendable, Equatable {
    /// The character, or characters, the glyph stands for. A single space for a gap
    /// between words that the page leaves without a glyph.
    public var text: String
    /// Where the glyph starts on the baseline, on the page as displayed.
    public var origin: PDFPoint
    /// How far the glyph moves the pen.
    public var advance: Double
    /// The size of the type, in points on the page.
    public var fontSize: Double
    public var fontName: String
    public var color: PDFColor
    public var isBold: Bool
    public var isItalic: Bool

    /// A space the page implies with a gap but does not draw.
    var isImplied = false
    var font = 0
    var code = 0
    var matrix = Affine.identity
    var source = ContentSource(stream: 0, operation: 0)
    var index = 0
    var renderMode = 0
    var charSpacing = 0.0
    var wordSpacing = 0.0
    var horizontalScale = 1.0
    var textFontSize = 0.0
    var width = 0.0
    var ascent = 0.0
    var descent = 0.0

    /// The box the glyph takes up.
    public var frame: PDFRectangle {
        PDFRectangle(x: origin.x, y: origin.y - descent, width: advance, height: ascent + descent)
    }
}

/// A line of text.
public struct TextLine: Sendable, Equatable {
    public var glyphs: [PageGlyph]
    /// The height of the baseline on the page as displayed.
    public var baseline: Double
    public var frame: PDFRectangle

    public var text: String { glyphs.map(\.text).joined() }
    /// The size of most of the line's type.
    public var fontSize: Double
}

/// A paragraph, or other group of lines that belong together.
public struct TextBlock: Sendable, Equatable, Identifiable {
    public enum Alignment: String, Sendable { case left, center, right, justified }

    /// The block's place among the page's blocks. It is only good until the page changes.
    public var id: Int
    public var lines: [TextLine]
    public var frame: PDFRectangle
    public var alignment = Alignment.left
    /// False for text the engine can read but not safely change: turned or slanted text,
    /// text inside a repeated form, invisible text, and fonts whose numbering it cannot follow.
    public var isEditable = true
    /// The PostScript name of an installed font that looks like the block's own, for
    /// showing its text while it is being changed.
    public internal(set) var installedFontName = "Helvetica"

    /// The block's lines, one per line.
    public var text: String { lines.map(\.text).joined(separator: "\n") }

    /// The text as a paragraph: lines that run on are joined with a space, and only lines
    /// that stop short keep their break.
    public var flowingText: String {
        flow.map(\.text).joined()
    }
}

/// A picture on a page.
public struct PageImage: Sendable, Equatable, Identifiable {
    public var id: Int
    /// The box around what shows of the picture, on the page as displayed.
    public var frame: PDFRectangle
    /// The image object. `nil` for a picture written inline in the page's content.
    public var objectID: ObjectID?
    /// False for pictures inside a repeated form, and for skewed ones.
    public var isEditable: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// How solid the picture is: 1 hides what is behind it, 0 shows nothing of it.
    public var opacity = 1.0
    /// The part of the picture that shows, in the picture's own terms: fractions of its
    /// width and height from its bottom left corner. `nil` when all of it shows.
    public var mask: PDFRectangle?

    /// Takes the unit square to where the whole picture is on the page as displayed.
    var matrix = Affine.identity
    var source = ContentSource(stream: 0, operation: 0)
    var name: PDFName?
}

/// Where a picture sits on a page as displayed: a rectangle of some size about a
/// center, turned by an angle.
public struct ImagePlacement: Sendable, Equatable {
    public var center: PDFPoint
    public var width: Double
    public var height: Double
    /// Degrees counterclockwise, from 0 up to 360.
    public var rotation: Double
    /// Whether the picture shows as in a mirror: its left and right swapped, before it
    /// is turned. A picture flipped top to bottom is one mirrored and turned half way.
    public var isMirrored = false

    public init(center: PDFPoint, width: Double, height: Double, rotation: Double = 0, isMirrored: Bool = false) {
        self.center = center
        self.width = width
        self.height = height
        self.rotation = rotation
        self.isMirrored = isMirrored
    }

    /// A point given in the rectangle's own terms, as fractions of its width and height
    /// from its bottom left corner, on the page.
    public func point(atFractionX x: Double, y: Double) -> PDFPoint {
        let radians = rotation * .pi / 180
        let dx = (x - 0.5) * width, dy = (y - 0.5) * height
        return PDFPoint(x: center.x + dx * cos(radians) - dy * sin(radians), y: center.y + dx * sin(radians) + dy * cos(radians))
    }

    /// A point on the page in the rectangle's own terms: across and up from its center,
    /// along its own sides.
    public func local(_ point: PDFPoint) -> PDFPoint {
        let radians = -rotation * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return PDFPoint(x: dx * cos(radians) - dy * sin(radians), y: dx * sin(radians) + dy * cos(radians))
    }

    /// The corners: bottom left, bottom right, top right, top left, as the rectangle has them.
    public var corners: [PDFPoint] {
        [point(atFractionX: 0, y: 0), point(atFractionX: 1, y: 0), point(atFractionX: 1, y: 1), point(atFractionX: 0, y: 1)]
    }

    /// The upright box the rectangle fits in.
    public var frame: PDFRectangle {
        PDFRectangle(enclosing: corners) ?? PDFRectangle(x: center.x, y: center.y, width: 0, height: 0)
    }

    public func contains(_ point: PDFPoint) -> Bool {
        let inside = local(point)
        return abs(inside.x) <= width / 2 && abs(inside.y) <= height / 2
    }

    /// The transform that takes a picture's unit square to the page, so that the part of
    /// it given by `mask` lands on this rectangle.
    func matrix(showing mask: PDFRectangle?) -> Affine {
        let part = mask ?? PDFRectangle(x: 0, y: 0, width: 1, height: 1)
        let radians = rotation * .pi / 180
        let side = isMirrored ? -1.0 : 1.0
        let a = side * width * cos(radians) / part.width, b = side * width * sin(radians) / part.width
        let c = -height * sin(radians) / part.height, d = height * cos(radians) / part.height
        let middleX = part.x + part.width / 2, middleY = part.y + part.height / 2
        return Affine(a: a, b: b, c: c, d: d, e: center.x - a * middleX - c * middleY, f: center.y - b * middleX - d * middleY)
    }
}

extension PageImage {
    /// Where what shows of the picture sits, with the angle it is turned by.
    public var placement: ImagePlacement {
        let part = mask ?? PDFRectangle(x: 0, y: 0, width: 1, height: 1)
        let width = (matrix.a * matrix.a + matrix.b * matrix.b).squareRoot() * part.width
        let height = (matrix.c * matrix.c + matrix.d * matrix.d).squareRoot() * part.height
        // A mirrored picture runs right to left along its own bottom edge.
        let isMirrored = matrix.determinant < 0
        var degrees = (isMirrored ? atan2(-matrix.b, -matrix.a) : atan2(matrix.b, matrix.a)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        // Not the negative zero a mirrored picture's numbers can give.
        if degrees == 0 || degrees >= 360 { degrees = 0 }
        let center = matrix.apply(PDFPoint(x: part.x + part.width / 2, y: part.y + part.height / 2))
        return ImagePlacement(center: center, width: width, height: height, rotation: degrees, isMirrored: isMirrored)
    }

    /// Where the whole picture would sit if none of it were masked off.
    public var unmaskedPlacement: ImagePlacement {
        var whole = self
        whole.mask = nil
        return whole.placement
    }

    /// Whether a point on the page is on what shows of the picture, turned as it is.
    public func contains(_ point: PDFPoint) -> Bool {
        placement.contains(point)
    }
}

/// What is on a page: its text in blocks and lines, and its pictures.
public struct PageContent: Sendable, Equatable {
    public var blocks: [TextBlock]
    public var images: [PageImage]
    public var geometry: PageGeometry

    /// All the text, blocks from the top of the page down.
    public var text: String { blocks.map(\.text).joined(separator: "\n") }

    /// The block a point on the page as displayed is in.
    public func block(at point: PDFPoint) -> TextBlock? {
        blocks.last { $0.frame.contains(point) }
    }

    public func image(at point: PDFPoint) -> PageImage? {
        images.last { $0.contains(point) }
    }

    /// How far right a block's lines may reach when its text is set again.
    ///
    /// A paragraph keeps its width. A single line, such as a heading, has no width of its
    /// own to keep, so it may grow until it is as far from the right edge of the page as
    /// it is from the left. The same goes for the lines of an address or a list.
    public func rightLimit(of block: TextBlock) -> Double {
        let right = block.frame.x + block.frame.width
        // Lines that each stand alone, as in an address, are like so many single lines:
        // none was fitted to the others' width.
        let standsAlone = block.lines.count == 1 || (block.alignment == .left && block.paragraphStarts.allSatisfy(\.self))
        guard standsAlone else { return right }
        let margin = min(max(block.frame.x, 0), geometry.displaySize.width * 0.12)
        return max(right, geometry.displaySize.width - margin)
    }
}

extension PDFEditor {
    /// Reads what a page draws: text grouped into lines and blocks, and pictures.
    ///
    /// Positions are on the page as displayed. `PageGeometry` converts to and from the
    /// page's own coordinates.
    public func pageContent(at index: Int) throws -> PageContent {
        Self.content(from: try interpret(pageAt: index), source: self)
    }

    static func content(from interpretation: Interpretation, source: PDFEditor) -> PageContent {
        // Glyphs with what is needed to group them.
        var upright: [PageGlyph] = []
        var other: [PageGlyph] = []
        var seen: Set<String> = []
        for raw in interpretation.glyphs {
            let font = interpretation.fonts[raw.font]
            let matrix = raw.matrix
            let size = (matrix.c * matrix.c + matrix.d * matrix.d).squareRoot()
            let scaleX = (matrix.a * matrix.a + matrix.b * matrix.b).squareRoot()
            guard size > 0.1, scaleX > 0.01 else { continue }
            var text = raw.text ?? "\u{FFFD}"
            // Characters that only say how the next ones combine have no place of their own.
            if text.unicodeScalars.allSatisfy({ $0.value < 0x20 }) { text = raw.code == 9 || raw.code == 32 ? " " : "" }
            guard !text.isEmpty else { continue }
            var glyph = PageGlyph(
                text: text, origin: PDFPoint(x: matrix.e, y: matrix.f), advance: raw.width / 1000 * scaleX, fontSize: size,
                fontName: font.baseName, color: raw.color, isBold: font.traits.isBold, isItalic: font.traits.isItalic
            )
            glyph.font = raw.font
            glyph.code = raw.code
            glyph.matrix = matrix
            glyph.source = raw.source
            glyph.index = raw.index
            glyph.renderMode = raw.renderMode
            glyph.charSpacing = raw.charSpacing
            glyph.wordSpacing = raw.wordSpacing
            glyph.horizontalScale = raw.horizontalScale
            glyph.textFontSize = raw.textFontSize
            glyph.width = raw.width
            glyph.ascent = font.ascent / 1000 * size
            glyph.descent = font.descent / 1000 * size
            // Text left outside the page cannot be seen, read or pointed at.
            let page = interpretation.geometry.displaySize
            guard abs(matrix.e) < 1e6, abs(matrix.f) < 1e6, glyph.origin.x + glyph.advance > -1, glyph.origin.x < page.width + 1,
                  glyph.origin.y + glyph.ascent > -1, glyph.origin.y - glyph.descent < page.height + 1
            else { continue }
            // Text drawn twice in the same place, for a bold or shadow effect, counts once.
            let key = "\(Int((matrix.e * 4).rounded()))/\(Int((matrix.f * 4).rounded()))/\(text)"
            guard text == " " || seen.insert(key).inserted else { continue }
            let isUpright = abs(matrix.b) < 0.01 * scaleX && abs(matrix.c) < 0.01 * size && matrix.a > 0 && matrix.d > 0
            if isUpright { upright.append(glyph) } else { other.append(glyph) }
        }

        var lines = Self.lines(from: upright)
        // Turned text is kept readable, in the order the page draws it, but not editable.
        var turned: [TextLine] = []
        if !other.isEmpty {
            var current: [PageGlyph] = []
            func flush() {
                guard let first = current.first, let frame = PDFRectangle(enclosing: current.flatMap { glyph -> [PDFPoint] in
                    let end = glyph.matrix.apply(PDFPoint(x: glyph.advance / max(glyph.fontSize, 0.01), y: 0.8))
                    return [glyph.origin, end]
                }) else { return }
                turned.append(TextLine(glyphs: current, baseline: first.origin.y, frame: frame, fontSize: first.fontSize))
                current = []
            }
            for glyph in other {
                if let last = current.last {
                    let distance = abs(glyph.origin.x - last.origin.x) + abs(glyph.origin.y - last.origin.y)
                    if distance > last.fontSize * 3 || glyph.source.stream != last.source.stream { flush() }
                }
                current.append(glyph)
            }
            flush()
        }

        var blocks = Self.blocks(from: &lines)
        for line in turned {
            var block = TextBlock(id: 0, lines: [line], frame: line.frame)
            block.isEditable = false
            blocks.append(block)
        }
        var installed: [Int: String] = [:]
        for index in blocks.indices {
            blocks[index].id = index
            let fonts = Dictionary(grouping: blocks[index].lines.flatMap(\.glyphs).filter { !$0.isImplied }, by: \.font)
            // Ties go to the lower number: a dictionary's own order changes from run to run.
            if let font = fonts.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) })?.key, interpretation.fonts.indices.contains(font) {
                if installed[font] == nil {
                    installed[font] = FontMatcher.installedName(for: interpretation.fonts[font].baseName, traits: interpretation.fonts[font].traits)
                }
                blocks[index].installedFontName = installed[font] ?? "Helvetica"
            }
            if blocks[index].isEditable {
                let glyphs = blocks[index].lines.flatMap(\.glyphs).filter { !$0.isImplied }
                // Text in a form that may be drawn elsewhere too, invisible text, and
                // fonts that cannot be followed are read-only.
                blocks[index].isEditable = glyphs.allSatisfy { glyph in
                    glyph.source.stream == 0 && glyph.renderMode != 3 && glyph.renderMode != 7 && interpretation.fonts[glyph.font].isReliable
                }
            }
        }

        let operations = interpretation.streams.first?.content.operations ?? []
        let images = interpretation.images.enumerated().compactMap { index, raw -> PageImage? in
            // The part that shows, when the picture is in the few operations Sheaf keeps a masked one in.
            let mask = raw.source.stream == 0 ? PictureGroup(around: raw.source.operation, in: operations)?.mask : nil
            let part = mask ?? PDFRectangle(x: 0, y: 0, width: 1, height: 1)
            let corners = [(0.0, 0.0), (1, 0), (0, 1), (1, 1)].map { raw.matrix.apply(PDFPoint(x: part.x + $0.0 * part.width, y: part.y + $0.1 * part.height)) }
            guard let frame = PDFRectangle(enclosing: corners), frame.width > 0.5, frame.height > 0.5 else { return nil }
            var width = 0, height = 0
            if let id = raw.object, let dictionary = try? source.object(id).streamValue?.dictionary {
                // A stencil for painting a color through, not a picture.
                if (try? source.value("ImageMask", in: dictionary).boolValue) == true { return nil }
                width = (try? source.value("Width", in: dictionary).intValue) ?? 0
                height = (try? source.value("Height", in: dictionary).intValue) ?? 0
            }
            // Turned pictures can be moved, resized and turned further. Skewed ones, whose
            // sides are no longer square to each other, cannot.
            let across = (raw.matrix.a * raw.matrix.a + raw.matrix.b * raw.matrix.b).squareRoot()
            let up = (raw.matrix.c * raw.matrix.c + raw.matrix.d * raw.matrix.d).squareRoot()
            let isSquare = across > 0 && up > 0 && abs(raw.matrix.a * raw.matrix.c + raw.matrix.b * raw.matrix.d) < 0.001 * across * up
            var image = PageImage(
                id: index, frame: frame, objectID: raw.object, isEditable: raw.source.stream == 0 && isSquare,
                pixelWidth: width, pixelHeight: height
            )
            image.opacity = min(max(raw.alpha, 0), 1)
            image.mask = mask
            image.matrix = raw.matrix
            image.source = raw.source
            image.name = raw.name
            return image
        }
        return PageContent(blocks: blocks, images: images, geometry: interpretation.geometry)
    }

    /// Groups upright glyphs into lines: same baseline, close together.
    private static func lines(from glyphs: [PageGlyph]) -> [TextLine] {
        // Rows by baseline, then split where a gap is too wide for a space between words.
        let sorted = glyphs.sorted { a, b in
            abs(a.origin.y - b.origin.y) > 0.01 ? a.origin.y > b.origin.y : a.origin.x < b.origin.x
        }
        var rows: [[PageGlyph]] = []
        for glyph in sorted {
            if let last = rows.last?.last, abs(last.origin.y - glyph.origin.y) <= max(min(last.fontSize, glyph.fontSize) * 0.2, 0.5) {
                rows[rows.count - 1].append(glyph)
            } else {
                rows.append([glyph])
            }
        }

        var lines: [TextLine] = []
        for row in rows {
            let ordered = row.sorted { $0.origin.x < $1.origin.x }
            var current: [PageGlyph] = []
            func flush() {
                // Spaces at either end are not part of the line.
                while current.last?.text == " " { current.removeLast() }
                while current.first?.text == " " { current.removeFirst() }
                guard let first = current.first, let last = current.last else { return }
                let sizes = Dictionary(grouping: current, by: { ($0.fontSize * 10).rounded() / 10 })
                let size = sizes.max { ($0.value.count, $0.key) < ($1.value.count, $1.key) }?.key ?? first.fontSize
                let ascent = current.map(\.ascent).max() ?? size * 0.75, descent = current.map(\.descent).max() ?? size * 0.25
                let baseline = first.origin.y
                let frame = PDFRectangle(x: first.origin.x, y: baseline - descent, width: max(last.origin.x + last.advance - first.origin.x, 0.1), height: ascent + descent)
                lines.append(TextLine(glyphs: current, baseline: baseline, frame: frame, fontSize: size))
                current = []
            }
            for glyph in ordered {
                if let last = current.last {
                    let gap = glyph.origin.x - (last.origin.x + last.advance)
                    let size = min(last.fontSize, glyph.fontSize)
                    if gap > size * 1.8 {
                        // Too far for the same line: another column, or a table cell.
                        flush()
                    } else if gap > size * 0.17, last.text != " ", glyph.text != " " {
                        // The page leaves a gap between words without drawing a space.
                        var space = last
                        space.text = " "
                        space.isImplied = true
                        space.origin = PDFPoint(x: last.origin.x + last.advance, y: last.origin.y)
                        space.advance = gap
                        current.append(space)
                    } else if gap < -size * 0.5 {
                        // Drawn over what came before, not after it.
                        flush()
                    }
                }
                current.append(glyph)
            }
            flush()
        }
        return lines
    }

    /// Groups lines into blocks: stacked closely, lined up, in type of about one size.
    private static func blocks(from lines: inout [TextLine]) -> [TextBlock] {
        lines.sort { a, b in abs(a.baseline - b.baseline) > 0.5 ? a.baseline > b.baseline : a.frame.x < b.frame.x }
        var groups: [[TextLine]] = []
        for line in lines {
            // The block whose last line this one continues, if any.
            var match: Int?
            for (index, group) in groups.enumerated().reversed() {
                guard let last = group.last else { continue }
                let drop = last.baseline - line.baseline
                let size = max(last.fontSize, line.fontSize)
                guard drop > size * 0.6, drop < size * 1.75 else { continue }
                guard min(last.fontSize, line.fontSize) / size > 0.8 else { continue }
                let overlap = min(last.frame.x + last.frame.width, line.frame.x + line.frame.width) - max(last.frame.x, line.frame.x)
                guard overlap > min(last.frame.width, line.frame.width) * 0.5 else { continue }
                // The line spacing of the block so far has to continue.
                if group.count > 1 {
                    let spacing = group[group.count - 2].baseline - last.baseline
                    guard abs(spacing - drop) < size * 0.25 else { continue }
                }
                match = index
                break
            }
            if let match {
                groups[match].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map { group in
            let left = group.map(\.frame.x).min() ?? 0, right = group.map { $0.frame.x + $0.frame.width }.max() ?? 0
            let bottom = group.map(\.frame.y).min() ?? 0, top = group.map { $0.frame.y + $0.frame.height }.max() ?? 0
            var block = TextBlock(id: 0, lines: group, frame: PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom))
            block.alignment = alignment(of: group, left: left, right: right)
            return block
        }
    }

    private static func alignment(of lines: [TextLine], left: Double, right: Double) -> TextBlock.Alignment {
        guard lines.count > 1 else { return .left }
        let tolerance = max((lines.first?.fontSize ?? 10) * 0.3, 1.5)
        // The last line of a paragraph says nothing about its right edge.
        let body = lines.dropLast()
        let startsLeft = lines.filter { abs($0.frame.x - left) < tolerance }.count
        let endsRight = body.filter { abs($0.frame.x + $0.frame.width - right) < tolerance }.count
        let allEndRight = lines.filter { abs($0.frame.x + $0.frame.width - right) < tolerance }.count
        let center = (left + right) / 2
        let centered = lines.filter { abs($0.frame.x + $0.frame.width / 2 - center) < tolerance }.count
        if startsLeft >= lines.count - 1, body.count >= 2, endsRight == body.count { return .justified }
        // Several paragraphs in one block: most lines run from edge to edge, and the
        // ones that do not are first lines, set in, and last lines, which stop short.
        if lines.count >= 3, allEndRight * 10 >= lines.count * 6, startsLeft * 2 >= lines.count { return .justified }
        if startsLeft == lines.count { return .left }
        if allEndRight == lines.count { return .right }
        if centered == lines.count { return .center }
        return .left
    }
}

extension TextBlock {
    private var drawnGlyphs: [PageGlyph] { lines.flatMap(\.glyphs).filter { !$0.isImplied && $0.text != " " } }

    private func mostCommon<Value: Hashable>(_ value: (PageGlyph) -> Value) -> Value? {
        // The value most glyphs have; of several equally common ones, the one that comes
        // first in the text, so the answer is the same every time.
        var counts: [Value: (count: Int, first: Int)] = [:]
        for (position, glyph) in drawnGlyphs.enumerated() {
            let key = value(glyph)
            counts[key] = ((counts[key]?.count ?? 0) + 1, counts[key]?.first ?? position)
        }
        return counts.max { ($0.value.count, -$0.value.first) < ($1.value.count, -$1.value.first) }?.key
    }

    /// The name of the font most of the block is set in, as the document has it.
    public var fontName: String { mostCommon(\.fontName) ?? "" }

    /// The size of most of the block's type, in points.
    public var fontSize: Double { mostCommon { ($0.fontSize * 100).rounded() / 100 } ?? 12 }

    public var color: PDFColor { mostCommon(\.color) ?? .black }

    /// The distance from one baseline to the next. For a single line, a usual distance for its size.
    public var leading: Double {
        let gaps = zip(lines, lines.dropFirst()).map { $0.baseline - $1.baseline }.sorted()
        return gaps.isEmpty ? fontSize * 1.2 : gaps[gaps.count / 2]
    }
}
