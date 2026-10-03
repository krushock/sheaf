import CoreGraphics
import CoreText
import Foundation

/// One step of a vector outline.
public enum PathElement: Sendable, Equatable, Codable {
    case move(PDFPoint)
    case line(PDFPoint)
    case curve(control1: PDFPoint, control2: PDFPoint, end: PDFPoint)
    case close
}

/// Turns text into vector outlines, so it can be drawn without embedding a font.
///
/// Text drawn this way looks right in every viewer and in every script, but it is shapes,
/// not text: it cannot be selected or searched. The words themselves are kept in the
/// annotation's contents.
public enum TextOutliner {
    public struct Result: Sendable, Equatable {
        public var elements: [PathElement]
        /// The height the laid-out lines take up.
        public var height: Double
    }

    /// Lays text out inside a rectangle, wrapping lines, and returns its outline in the
    /// rectangle's coordinate system.
    public static func outline(
        _ text: String, fontName: String, fontSize: Double, in rect: PDFRectangle, alignment: Annotation.TextAlignment
    ) -> Result {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return Result(elements: [], height: 0) }
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var ctAlignment: CTTextAlignment = alignment == .center ? .center : alignment == .right ? .right : .left
        let style = withUnsafeBytes(of: &ctAlignment) { bytes in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)], 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Tall enough for any amount of text; the caller decides whether to clip.
        let frameRect = CGRect(x: 0, y: 0, width: rect.width, height: 100_000)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var elements: [PathElement] = []
        var lowest = frameRect.height
        for (line, origin) in zip(lines, origins) {
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, nil, &descent, nil)
            lowest = min(lowest, origin.y - descent)
            // Frame coordinates start at the frame's bottom; move them so the first line
            // sits at the top of the target rectangle.
            let shift = CGAffineTransform(translationX: rect.x + origin.x, y: rect.y + rect.height - (frameRect.height - origin.y))
            append(line, transform: shift, to: &elements)
        }
        return Result(elements: elements, height: frameRect.height - lowest)
    }

    /// One line of text at its natural size.
    public struct Line: Sendable, Equatable {
        /// The outline, with the baseline starting at the origin.
        public var elements: [PathElement]
        public var width: Double
        /// How far the font reaches above and below the baseline.
        public var ascent: Double
        public var descent: Double
    }

    /// The outline of one line of text. Characters the font lacks are drawn from a
    /// fallback font, as on screen.
    public static func line(_ text: String, fontName: String, fontSize: Double) -> Line {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        var elements: [PathElement] = []
        append(line, transform: .identity, to: &elements)
        return Line(elements: elements, width: width, ascent: ascent, descent: descent)
    }

    /// One glyph of laid-out text.
    public struct Glyph: Sendable, Equatable {
        /// The font the glyph comes from, which is a fallback font where the asked-for
        /// font lacks the character.
        public var fontName: String
        public var index: UInt16
        /// Where the glyph's origin sits, from the line's left end and baseline.
        public var x: Double
        public var y: Double
        /// How far the glyph moves the pen, in thousandths of the font size.
        public var advance: Double
        /// The glyph's shape in thousandths of the font size, origin at the glyph's own origin.
        public var outline: [PathElement]
        /// The characters the glyph stands for. Empty for the later glyphs of a group that
        /// together stand for the characters given to the first.
        public var text: String
    }

    /// A line of text as positioned glyphs.
    public struct ShapedLine: Sendable, Equatable {
        public var glyphs: [Glyph]
        public var width: Double
        public var ascent: Double
        public var descent: Double
        /// Where the line starts inside the area it was laid out in: its left end, and its
        /// baseline measured down from the top.
        public var x = 0.0
        public var baselineFromTop = 0.0
    }

    /// Lays out one line of text as glyphs.
    public static func shape(_ text: String, fontName: String, fontSize: Double) -> ShapedLine {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        return shaped(line, text: text, fontSize: fontSize)
    }

    /// Lays text out in lines no wider than `width`, as glyphs.
    public static func shape(_ text: String, fontName: String, fontSize: Double, width: Double, alignment: Annotation.TextAlignment) -> [ShapedLine] {
        guard !text.isEmpty, width > 0 else { return [] }
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var ctAlignment: CTTextAlignment = alignment == .center ? .center : alignment == .right ? .right : .left
        let style = withUnsafeBytes(of: &ctAlignment) { bytes in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)], 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frameRect = CGRect(x: 0, y: 0, width: width, height: 100_000)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return zip(lines, origins).map { line, origin in
            var result = shaped(line, text: text, fontSize: fontSize)
            result.x = origin.x
            result.baselineFromTop = frameRect.height - origin.y
            return result
        }
    }

    private static func shaped(_ line: CTLine, text: String, fontSize: Double) -> ShapedLine {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let utf16 = Array(text.utf16)
        var glyphs: [Glyph] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontValue = attributes[kCTFontAttributeName as String] else { continue }
            let font = fontValue as! CTFont
            let name = CTFontCopyPostScriptName(font) as String
            // The same font at a thousand points gives outlines in thousandths of the size.
            let unitFont = CTFontCreateCopyWithAttributes(font, 1000, nil, nil)
            let count = CTRunGetGlyphCount(run)
            var indexes = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var stringIndexes = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &indexes)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndexes)
            let range = CTRunGetStringRange(run)
            let runEnd = range.location + range.length
            // Each glyph stands for the characters from its own index up to the next glyph's.
            let sortedStarts = Set(stringIndexes).sorted()
            var seen: Set<CFIndex> = []
            for position in 0..<count {
                var elements: [PathElement] = []
                if let path = CTFontCreatePathForGlyph(unitFont, indexes[position], nil) { append(path, to: &elements) }
                var characters = ""
                let start = stringIndexes[position]
                if seen.insert(start).inserted {
                    let end = sortedStarts.first { $0 > start } ?? runEnd
                    if start >= 0, end <= utf16.count, start < end {
                        characters = String(decoding: utf16[start..<end], as: UTF16.self)
                    }
                }
                glyphs.append(Glyph(
                    fontName: name, index: indexes[position], x: positions[position].x, y: positions[position].y,
                    advance: fontSize > 0 ? advances[position].width / fontSize * 1000 : 0, outline: elements, text: characters
                ))
            }
        }
        return ShapedLine(glyphs: glyphs, width: width, ascent: ascent, descent: descent)
    }

    /// One line of text scaled to fill a rectangle, centered. For stamps.
    public static func outline(line text: String, fontName: String, fitting rect: PDFRectangle) -> [PathElement] {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let reference = 100.0
        let font = CTFontCreateWithName(fontName as CFString, reference, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform(
            translationX: rect.x + (rect.width - bounds.width * scale) / 2 - bounds.minX * scale,
            y: rect.y + (rect.height - bounds.height * scale) / 2 - bounds.minY * scale
        ).scaledBy(x: scale, y: scale)
        var elements: [PathElement] = []
        append(line, transform: transform, to: &elements)
        return elements
    }

    private static func append(_ line: CTLine, transform: CGAffineTransform, to elements: inout [PathElement]) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontValue = attributes[kCTFontAttributeName as String] else { continue }
            let font = fontValue as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                var placement = CGAffineTransform(translationX: position.x, y: position.y).concatenating(transform)
                // Glyphs with no outline, such as spaces and color emoji, are skipped.
                guard let path = CTFontCreatePathForGlyph(font, glyph, &placement) else { continue }
                append(path, to: &elements)
            }
        }
    }

    private static func append(_ path: CGPath, to elements: inout [PathElement]) {
        var current = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            func point(_ index: Int) -> PDFPoint { PDFPoint(x: element.points[index].x, y: element.points[index].y) }
            switch element.type {
            case .moveToPoint:
                elements.append(.move(point(0)))
                current = element.points[0]
            case .addLineToPoint:
                elements.append(.line(point(0)))
                current = element.points[0]
            case .addQuadCurveToPoint:
                // PDF has only cubic curves.
                let control = element.points[0], end = element.points[1]
                elements.append(.curve(
                    control1: PDFPoint(x: current.x + 2 / 3 * (control.x - current.x), y: current.y + 2 / 3 * (control.y - current.y)),
                    control2: PDFPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y)),
                    end: PDFPoint(x: end.x, y: end.y)
                ))
                current = end
            case .addCurveToPoint:
                elements.append(.curve(control1: point(0), control2: point(1), end: point(2)))
                current = element.points[2]
            case .closeSubpath:
                elements.append(.close)
            @unknown default:
                break
            }
        }
    }
}
