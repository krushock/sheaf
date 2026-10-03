import Foundation

/// How an annotation looks: drawing instructions plus what they need.
///
/// The instructions are in page coordinates, so the same appearance can be stored in the
/// document as the annotation's appearance stream and drawn on screen as it is.
public struct Appearance: Sendable, Equatable {
    /// The area the drawing covers, in page coordinates.
    public var bounds: PDFRectangle
    public var content: Data
    var graphicsStates: [PDFName: PDFDictionary] = [:]
    var images: [PDFName: StampImage] = [:]

    /// A one-page PDF showing just this appearance, with the page the size of `bounds`.
    /// The app draws annotations being edited from this, so the screen matches the saved file.
    public func previewPDF() -> Data {
        var output = Data("%PDF-1.7\n".utf8)
        var offsets: [(id: ObjectID, offset: Int)] = []
        func write(_ number: Int, _ object: PDFObject) {
            offsets.append((ObjectID(number), output.count))
            Serializer.append(indirect: object, id: ObjectID(number), to: &output)
        }
        var nextNumber = 5
        var xObjects: PDFDictionary = [:]
        var imageObjects: [(Int, PDFObject)] = []
        for name in images.keys.sorted() {
            let (image, mask) = Self.imageObjects(for: images[name]!)
            var dictionary = image
            if let mask {
                imageObjects.append((nextNumber, .stream(mask)))
                dictionary.dictionary["SMask"] = .reference(ObjectID(nextNumber))
                nextNumber += 1
            }
            imageObjects.append((nextNumber, .stream(dictionary)))
            xObjects[name] = .reference(ObjectID(nextNumber))
            nextNumber += 1
        }
        // Shift the drawing so the bounds' corner lands on the page's origin.
        var shifted = Data("1 0 0 1 \(Serializer.format(-bounds.x)) \(Serializer.format(-bounds.y)) cm\n".utf8)
        shifted.append(content)

        write(1, ["Type": .name("Catalog"), "Pages": .reference(ObjectID(2))])
        write(2, ["Type": .name("Pages"), "Kids": [.reference(ObjectID(3))], "Count": 1])
        write(3, [
            "Type": .name("Page"), "Parent": .reference(ObjectID(2)),
            "MediaBox": PDFRectangle(x: 0, y: 0, width: max(bounds.width, 1), height: max(bounds.height, 1)).object,
            "Contents": .reference(ObjectID(4)),
            "Resources": ["ExtGState": .dictionary(graphicsStates.mapValues(PDFObject.dictionary)), "XObject": .dictionary(xObjects)],
            // Transparency must mix with the page underneath, not with a white sheet.
            "Group": ["S": .name("Transparency"), "I": false, "K": false],
        ])
        write(4, .stream(PDFStream(data: shifted)))
        for (number, object) in imageObjects { write(number, object) }

        let tableOffset = output.count
        CrossReferenceWriter.appendTable(entries: offsets, includeFreeHead: true, to: &output)
        output.append(contentsOf: "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(tableOffset)\n%%EOF\n".utf8)
        return output
    }

    static func imageObjects(for image: StampImage) -> (image: PDFStream, mask: PDFStream?) {
        let common: PDFDictionary = [
            "Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(image.width), "Height": .integer(image.height),
            "BitsPerComponent": 8, "Filter": .name("FlateDecode"),
        ]
        var imageDictionary = common
        imageDictionary["ColorSpace"] = .name("DeviceRGB")
        let mask = image.alpha.map { alpha -> PDFStream in
            var dictionary = common
            dictionary["ColorSpace"] = .name("DeviceGray")
            return PDFStream(dictionary: dictionary, data: Flate.deflate(alpha))
        }
        return (PDFStream(dictionary: imageDictionary, data: Flate.deflate(image.rgb)), mask)
    }
}

/// Builds the drawing instructions for each kind of annotation.
enum AppearanceBuilder {
    /// The look of an annotation, or `nil` for kinds that show nothing, such as links.
    static func make(for annotation: Annotation) -> Appearance? {
        var canvas = Canvas()
        switch annotation.kind {
        case .highlight:
            guard !annotation.quads.isEmpty else { return nil }
            canvas.useGraphicsState(opacity: annotation.opacity, multiply: true)
            canvas.fillColor(annotation.color ?? .yellow)
            for quad in annotation.quads { canvas.rectangle(quad) }
            canvas.add("f")

        case .underline, .strikeOut:
            guard !annotation.quads.isEmpty else { return nil }
            canvas.useGraphicsState(opacity: annotation.opacity, multiply: false)
            canvas.strokeColor(annotation.color ?? .red)
            for quad in annotation.quads {
                let thickness = max(quad.height * 0.06, 0.6)
                let y = quad.y + quad.height * (annotation.kind == .underline ? 0.08 : 0.42)
                canvas.add("\(number(thickness)) w")
                canvas.move(PDFPoint(x: quad.x, y: y))
                canvas.line(PDFPoint(x: quad.x + quad.width, y: y))
                canvas.add("S")
            }

        case .square, .circle:
            let inset = annotation.lineWidth / 2
            let shape = PDFRectangle(
                x: annotation.rect.x + inset, y: annotation.rect.y + inset,
                width: max(annotation.rect.width - annotation.lineWidth, 0.1), height: max(annotation.rect.height - annotation.lineWidth, 0.1)
            )
            canvas.useGraphicsState(opacity: annotation.opacity, multiply: false)
            canvas.add("\(number(annotation.lineWidth)) w")
            if let fill = annotation.fillColor { canvas.fillColor(fill) }
            canvas.strokeColor(annotation.color ?? .red)
            if annotation.kind == .square { canvas.rectangle(shape) } else { canvas.ellipse(in: shape) }
            let strokes = annotation.lineWidth > 0
            canvas.add(annotation.fillColor != nil ? (strokes ? "B" : "f") : (strokes ? "S" : "n"))

        case .line:
            guard let start = annotation.lineStart, let end = annotation.lineEnd else { return nil }
            canvas.useGraphicsState(opacity: annotation.opacity, multiply: false)
            canvas.strokeColor(annotation.color ?? .red)
            canvas.fillColor(annotation.color ?? .red)
            canvas.add("\(number(annotation.lineWidth)) w 1 J 1 j")
            canvas.move(start)
            canvas.line(end)
            canvas.add("S")
            canvas.arrowhead(annotation.startEnding, at: start, from: end, lineWidth: annotation.lineWidth)
            canvas.arrowhead(annotation.endEnding, at: end, from: start, lineWidth: annotation.lineWidth)

        case .ink:
            guard annotation.paths.contains(where: { !$0.isEmpty }) else { return nil }
            canvas.useGraphicsState(opacity: annotation.opacity, multiply: false)
            canvas.strokeColor(annotation.color ?? .black)
            canvas.fillColor(annotation.color ?? .black)
            canvas.add("\(number(annotation.lineWidth)) w 1 J 1 j")
            for path in annotation.paths { canvas.smoothStroke(through: path, lineWidth: annotation.lineWidth) }

        case .freeText:
            canvas.useGraphicsState(opacity: annotation.opacity, multiply: false)
            if let fill = annotation.fillColor {
                canvas.fillColor(fill)
                canvas.rectangle(annotation.rect)
                canvas.add("f")
            }
            let padding = Annotation.textPadding
            let textRect = PDFRectangle(
                x: annotation.rect.x + padding, y: annotation.rect.y + padding,
                width: max(annotation.rect.width - 2 * padding, 1), height: max(annotation.rect.height - 2 * padding, 1)
            )
            // Text that does not fit is cut off at the box, as in a text box on screen.
            canvas.add("q")
            canvas.rectangle(annotation.rect)
            canvas.add("W n")
            canvas.fillColor(annotation.color ?? .black)
            let outline = TextOutliner.outline(
                annotation.contents, fontName: annotation.fontName, fontSize: annotation.fontSize, in: textRect, alignment: annotation.alignment
            )
            canvas.fill(outline.elements)
            canvas.add("Q")

        case .note:
            canvas.noteIcon(in: annotation.rect, color: annotation.color ?? .yellow)

        case .stamp:
            guard let stamp = annotation.stamp else { return nil }
            canvas.useGraphicsState(opacity: annotation.opacity, multiply: false)
            let rect = annotation.rect
            switch stamp {
            case .text(let text):
                let color = annotation.color ?? .red
                let border = max(min(rect.width, rect.height) * 0.06, 1)
                canvas.strokeColor(color)
                canvas.fillColor(color)
                canvas.add("\(number(border)) w")
                canvas.roundedRectangle(
                    PDFRectangle(x: rect.x + border / 2, y: rect.y + border / 2, width: rect.width - border, height: rect.height - border),
                    radius: min(rect.height * 0.2, 8)
                )
                canvas.add("S")
                let inset = border * 2.5
                let textRect = PDFRectangle(x: rect.x + inset, y: rect.y + inset, width: rect.width - 2 * inset, height: rect.height - 2 * inset)
                canvas.fill(TextOutliner.outline(line: text.uppercased(), fontName: "Helvetica-Bold", fitting: textRect))
            case .strokes(let strokes, let lineWidth):
                canvas.strokeColor(annotation.color ?? .black)
                canvas.fillColor(annotation.color ?? .black)
                // The pen keeps its thickness relative to the signature as it is resized.
                let width = lineWidth * min(rect.width, rect.height)
                canvas.add("\(number(width)) w 1 J 1 j")
                for stroke in strokes {
                    canvas.smoothStroke(
                        through: stroke.map { PDFPoint(x: rect.x + $0.x * rect.width, y: rect.y + $0.y * rect.height) }, lineWidth: width
                    )
                }
            case .shapes(let elements):
                canvas.fillColor(annotation.color ?? .black)
                func place(_ point: PDFPoint) -> PDFPoint {
                    PDFPoint(x: rect.x + point.x * rect.width, y: rect.y + point.y * rect.height)
                }
                canvas.fill(elements.map { element -> PathElement in
                    switch element {
                    case .move(let point): .move(place(point))
                    case .line(let point): .line(place(point))
                    case .curve(let control1, let control2, let end): .curve(control1: place(control1), control2: place(control2), end: place(end))
                    case .close: .close
                    }
                })
            case .image(let image):
                canvas.images["Im0"] = image
                canvas.add("q \(number(rect.width)) 0 0 \(number(rect.height)) \(number(rect.x)) \(number(rect.y)) cm /Im0 Do Q")
            }

        case .link, .other:
            return nil
        }
        return canvas.appearance(bounds: bounds(for: annotation))
    }

    /// The area an annotation's drawing covers: its frame, grown where lines stick out of it.
    static func bounds(for annotation: Annotation) -> PDFRectangle {
        var margin = 0.0
        switch annotation.kind {
        case .line: margin = annotation.lineWidth * 5 + 4
        case .ink: margin = annotation.lineWidth
        case .underline, .strikeOut: margin = 1
        default: break
        }
        let rect = annotation.rect
        return PDFRectangle(x: rect.x - margin, y: rect.y - margin, width: rect.width + 2 * margin, height: rect.height + 2 * margin)
    }

    private static func number(_ value: Double) -> String { Serializer.format(value) }

    /// Collects drawing instructions.
    private struct Canvas {
        var content = Data()
        var graphicsStates: [PDFName: PDFDictionary] = [:]
        var images: [PDFName: StampImage] = [:]

        mutating func add(_ text: String) {
            content.append(contentsOf: text.utf8)
            content.append(0x0A)
        }

        private func point(_ point: PDFPoint) -> String { "\(number(point.x)) \(number(point.y))" }

        mutating func useGraphicsState(opacity: Double, multiply: Bool) {
            guard opacity < 1 || multiply else { return }
            var state: PDFDictionary = ["Type": .name("ExtGState"), "CA": .real(opacity), "ca": .real(opacity)]
            if multiply { state["BM"] = .name("Multiply") }
            graphicsStates["GS0"] = state
            add("/GS0 gs")
        }

        mutating func fillColor(_ color: PDFColor) { add("\(number(color.red)) \(number(color.green)) \(number(color.blue)) rg") }
        mutating func strokeColor(_ color: PDFColor) { add("\(number(color.red)) \(number(color.green)) \(number(color.blue)) RG") }
        mutating func move(_ target: PDFPoint) { add("\(point(target)) m") }
        mutating func line(_ target: PDFPoint) { add("\(point(target)) l") }
        mutating func curve(_ control1: PDFPoint, _ control2: PDFPoint, _ end: PDFPoint) {
            add("\(point(control1)) \(point(control2)) \(point(end)) c")
        }

        mutating func rectangle(_ rect: PDFRectangle) {
            add("\(number(rect.x)) \(number(rect.y)) \(number(rect.width)) \(number(rect.height)) re")
        }

        mutating func ellipse(in rect: PDFRectangle) {
            // Four curves; 0.5523 is the handle length that best approximates a circle.
            let rx = rect.width / 2, ry = rect.height / 2, cx = rect.x + rx, cy = rect.y + ry
            let kx = rx * 0.5523, ky = ry * 0.5523
            move(PDFPoint(x: cx + rx, y: cy))
            curve(PDFPoint(x: cx + rx, y: cy + ky), PDFPoint(x: cx + kx, y: cy + ry), PDFPoint(x: cx, y: cy + ry))
            curve(PDFPoint(x: cx - kx, y: cy + ry), PDFPoint(x: cx - rx, y: cy + ky), PDFPoint(x: cx - rx, y: cy))
            curve(PDFPoint(x: cx - rx, y: cy - ky), PDFPoint(x: cx - kx, y: cy - ry), PDFPoint(x: cx, y: cy - ry))
            curve(PDFPoint(x: cx + kx, y: cy - ry), PDFPoint(x: cx + rx, y: cy - ky), PDFPoint(x: cx + rx, y: cy))
            add("h")
        }

        mutating func roundedRectangle(_ rect: PDFRectangle, radius: Double) {
            let r = max(min(radius, rect.width / 2, rect.height / 2), 0), k = r * 0.5523
            let (x0, y0, x1, y1) = (rect.x, rect.y, rect.x + rect.width, rect.y + rect.height)
            move(PDFPoint(x: x0 + r, y: y0))
            line(PDFPoint(x: x1 - r, y: y0))
            curve(PDFPoint(x: x1 - r + k, y: y0), PDFPoint(x: x1, y: y0 + r - k), PDFPoint(x: x1, y: y0 + r))
            line(PDFPoint(x: x1, y: y1 - r))
            curve(PDFPoint(x: x1, y: y1 - r + k), PDFPoint(x: x1 - r + k, y: y1), PDFPoint(x: x1 - r, y: y1))
            line(PDFPoint(x: x0 + r, y: y1))
            curve(PDFPoint(x: x0 + r - k, y: y1), PDFPoint(x: x0, y: y1 - r + k), PDFPoint(x: x0, y: y1 - r))
            line(PDFPoint(x: x0, y: y0 + r))
            curve(PDFPoint(x: x0, y: y0 + r - k), PDFPoint(x: x0 + r - k, y: y0), PDFPoint(x: x0 + r, y: y0))
            add("h")
        }

        mutating func fill(_ elements: [PathElement]) {
            guard !elements.isEmpty else { return }
            for element in elements {
                switch element {
                case .move(let target): move(target)
                case .line(let target): line(target)
                case .curve(let control1, let control2, let end): curve(control1, control2, end)
                case .close: add("h")
                }
            }
            add("f")
        }

        /// A stroke through points, rounded at the corners so pen strokes look drawn.
        mutating func smoothStroke(through points: [PDFPoint], lineWidth: Double) {
            guard let first = points.first else { return }
            if points.count == 1 {
                // A tap: a dot the size of the pen.
                ellipse(in: PDFRectangle(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2, width: lineWidth, height: lineWidth))
                add("f")
                return
            }
            move(first)
            if points.count == 2 {
                line(points[1])
            } else {
                // Curve through the midpoints, using each point as a control point.
                var current = first
                for index in 1..<points.count - 1 {
                    let control = points[index], next = points[index + 1]
                    let middle = PDFPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
                    curve(
                        PDFPoint(x: current.x + 2 / 3 * (control.x - current.x), y: current.y + 2 / 3 * (control.y - current.y)),
                        PDFPoint(x: middle.x + 2 / 3 * (control.x - middle.x), y: middle.y + 2 / 3 * (control.y - middle.y)),
                        middle
                    )
                    current = middle
                }
                line(points[points.count - 1])
            }
            add("S")
        }

        mutating func arrowhead(_ ending: Annotation.LineEnding, at tip: PDFPoint, from other: PDFPoint, lineWidth: Double) {
            guard ending != .none else { return }
            let dx = tip.x - other.x, dy = tip.y - other.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return }
            let size = max(lineWidth * 4, 7), angle = 0.45
            func wing(_ sign: Double) -> PDFPoint {
                let ux = dx / length, uy = dy / length
                let (cosine, sine) = (cos(angle * sign), sin(angle * sign))
                return PDFPoint(x: tip.x - size * (ux * cosine - uy * sine), y: tip.y - size * (ux * sine + uy * cosine))
            }
            move(wing(1))
            line(tip)
            line(wing(-1))
            add(ending == .closedArrow ? "h B" : "S")
        }

        /// A small sticky note.
        mutating func noteIcon(in rect: PDFRectangle, color: PDFColor) {
            let s = min(rect.width, rect.height)
            func p(_ x: Double, _ y: Double) -> PDFPoint { PDFPoint(x: rect.x + x * s, y: rect.y + y * s) }
            fillColor(color)
            strokeColor(PDFColor(red: color.red * 0.55, green: color.green * 0.55, blue: color.blue * 0.55))
            add("\(number(s * 0.05)) w 1 j")
            // The sheet, with its bottom right corner folded.
            move(p(0.08, 0.92))
            line(p(0.92, 0.92))
            line(p(0.92, 0.36))
            line(p(0.64, 0.08))
            line(p(0.08, 0.08))
            add("h B")
            move(p(0.92, 0.36))
            line(p(0.64, 0.36))
            line(p(0.64, 0.08))
            add("S")
            for y in [0.72, 0.56] {
                move(p(0.24, y))
                line(p(0.76, y))
                add("S")
            }
        }

        func appearance(bounds: PDFRectangle) -> Appearance {
            Appearance(bounds: bounds, content: content, graphicsStates: graphicsStates, images: images)
        }
    }
}

extension Annotation {
    /// Space between a text box's edge and its text.
    public static let textPadding = 3.0
    /// The size of a note's icon on the page.
    public static let noteSize = 20.0
}
