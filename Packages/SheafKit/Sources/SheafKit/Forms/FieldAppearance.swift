import Foundation

/// Draws form fields: the picture each widget shows for the field's current value.
///
/// Text is written as real text in a small font built from the glyphs' outlines
/// (`GlyphFont`), so a value in any script looks right in every viewer without embedding
/// font files, and readers that redraw fields their own way can tell it is text.
enum FieldAppearance {
    /// The fonts forms name by short codes, as the system knows them.
    static let standardFonts: [String: String] = [
        "Helv": "Helvetica", "HeBo": "Helvetica-Bold", "HeOb": "Helvetica-Oblique", "HeBO": "Helvetica-BoldOblique",
        "TiRo": "Times-Roman", "TiBo": "Times-Bold", "TiIt": "Times-Italic", "TiBI": "Times-BoldItalic",
        "Cour": "Courier", "CoBo": "Courier-Bold", "CoOb": "Courier-Oblique", "CoBO": "Courier-BoldOblique",
    ]

    private static func number(_ value: Double) -> String { Serializer.format(value) }

    private static func color(_ color: PDFColor, stroke: Bool = false) -> String {
        "\(number(color.red)) \(number(color.green)) \(number(color.blue)) \(stroke ? "RG" : "rg")\n"
    }

    /// The background and border every kind of field may have.
    private static func frame(_ field: FormField, size: PageSize, borderWidth: Double, round: Bool = false) -> String {
        var content = ""
        let inset = borderWidth / 2
        func shape() -> String {
            guard round else { return "\(number(inset)) \(number(inset)) \(number(size.width - borderWidth)) \(number(size.height - borderWidth)) re\n" }
            // A circle from four curves.
            let radius = min(size.width, size.height) / 2 - inset, cx = size.width / 2, cy = size.height / 2, k = radius * 0.5523
            func p(_ x: Double, _ y: Double) -> String { "\(number(x)) \(number(y))" }
            return "\(p(cx + radius, cy)) m\n"
                + "\(p(cx + radius, cy + k)) \(p(cx + k, cy + radius)) \(p(cx, cy + radius)) c\n"
                + "\(p(cx - k, cy + radius)) \(p(cx - radius, cy + k)) \(p(cx - radius, cy)) c\n"
                + "\(p(cx - radius, cy - k)) \(p(cx - k, cy - radius)) \(p(cx, cy - radius)) c\n"
                + "\(p(cx + k, cy - radius)) \(p(cx + radius, cy - k)) \(p(cx + radius, cy)) c\nh\n"
        }
        if let background = field.backgroundColor {
            content += color(background) + shape() + "f\n"
        }
        if let border = field.borderColor, borderWidth > 0 {
            content += color(border, stroke: true) + "\(number(borderWidth)) w\n" + shape() + "S\n"
        }
        return content
    }

    /// The size text is drawn at when the field leaves it to the viewer.
    static func automaticFontSize(for field: FormField, height: Double, borderWidth: Double) -> Double {
        if field.isMultiline || field.kind == .list { return 12 }
        return min(12, max(4, (height - 2 * borderWidth - 2) * 0.72))
    }

    /// A text field, dropdown or list showing a value.
    ///
    /// - Returns: The drawing, and the glyph fonts its text uses, still to be added to the document.
    static func text(_ field: FormField, value: String, size: PageSize, borderWidth: Double, fontName: String) -> (content: Data, text: GlyphText) {
        var content = frame(field, size: size, borderWidth: borderWidth)
        let fontSize = field.fontSize > 0 ? field.fontSize : automaticFontSize(for: field, height: size.height, borderWidth: borderWidth)
        let padding = borderWidth + 2
        var text = GlyphText()
        var marks = ""

        func aligned(_ width: Double) -> Double {
            switch field.alignment {
            case .left: padding
            case .center: (size.width - width) / 2
            case .right: size.width - padding - width
            }
        }
        func centeredBaseline(_ line: TextOutliner.ShapedLine, in height: Double) -> Double {
            (height - line.ascent - line.descent) / 2 + line.descent
        }

        if field.kind == .list {
            // Every option, with the chosen one marked.
            let lineHeight = fontSize * 1.25
            for (index, option) in field.options.enumerated() {
                let top = size.height - padding - Double(index) * lineHeight
                guard top > 0 else { break }
                let line = TextOutliner.shape(option.title, fontName: fontName, fontSize: fontSize)
                if option.value == value {
                    marks += "0.72 0.82 0.96 rg \(number(borderWidth)) \(number(top - lineHeight)) \(number(size.width - 2 * borderWidth)) \(number(lineHeight)) re f\n"
                }
                text.add(line, x: padding, baseline: top - lineHeight + centeredBaseline(line, in: lineHeight), fontSize: fontSize)
            }
        } else if field.isMultiline {
            let width = max(size.width - 2 * padding, 1)
            for line in TextOutliner.shape(value, fontName: fontName, fontSize: fontSize, width: width, alignment: field.alignment) {
                text.add(line, x: padding + line.x, baseline: size.height - padding - line.baselineFromTop, fontSize: fontSize)
            }
        } else {
            let shown = field.isPassword ? String(repeating: "•", count: value.count) : value
            if field.isComb, let cells = field.maxLength, cells > 0 {
                // One character per box, each centered in its own.
                let cellWidth = size.width / Double(cells)
                for (index, character) in shown.prefix(cells).enumerated() {
                    let line = TextOutliner.shape(String(character), fontName: fontName, fontSize: fontSize)
                    text.add(line, x: Double(index) * cellWidth + (cellWidth - line.width) / 2, baseline: centeredBaseline(line, in: size.height), fontSize: fontSize)
                }
            } else if !shown.isEmpty {
                let line = TextOutliner.shape(shown, fontName: fontName, fontSize: fontSize)
                text.add(line, x: aligned(line.width), baseline: centeredBaseline(line, in: size.height), fontSize: fontSize)
            }
        }

        content += marks
        // Readers that draw fields themselves, as Preview does, replace the text between
        // these marks with their own. Others draw it as it is.
        content += "/Tx BMC\nq\n"
        content += "\(number(borderWidth)) \(number(borderWidth)) \(number(max(size.width - 2 * borderWidth, 0))) \(number(max(size.height - 2 * borderWidth, 0))) re W n\n"
        if !text.isEmpty { content += "BT\n" + color(field.textColor) + text.operators + "ET\n" }
        content += "Q\nEMC\n"
        return (Data(content.utf8), text)
    }

    /// A checkbox, checked or not.
    static func checkbox(_ field: FormField, isOn: Bool, size: PageSize, borderWidth: Double) -> Data {
        var content = frame(field, size: size, borderWidth: borderWidth)
        if isOn {
            let side = min(size.width, size.height), x = (size.width - side) / 2, y = (size.height - side) / 2
            func p(_ px: Double, _ py: Double) -> String { "\(number(x + px * side)) \(number(y + py * side))" }
            content += "q " + color(field.textColor, stroke: true)
            content += "\(number(side * 0.12)) w 1 J 1 j\n\(p(0.22, 0.52)) m \(p(0.42, 0.28)) l \(p(0.78, 0.76)) l S\nQ\n"
        }
        return Data(content.utf8)
    }

    /// A radio button, chosen or not.
    static func radio(_ field: FormField, isOn: Bool, size: PageSize, borderWidth: Double) -> Data {
        var content = frame(field, size: size, borderWidth: borderWidth, round: true)
        if isOn {
            var dot = field
            dot.backgroundColor = field.textColor
            dot.borderColor = nil
            let side = min(size.width, size.height) * 0.5
            let shift = "q 1 0 0 1 \(number((size.width - side) / 2)) \(number((size.height - side) / 2)) cm\n"
            content += shift + frame(dot, size: PageSize(width: side, height: side), borderWidth: 0, round: true) + "Q\n"
        }
        return Data(content.utf8)
    }

    /// An empty signature field: a line to sign on.
    static func signature(_ field: FormField, size: PageSize, borderWidth: Double) -> Data {
        var content = frame(field, size: size, borderWidth: borderWidth)
        let y = max(size.height * 0.18, 2)
        content += "q 0.45 0.45 0.45 RG 0.75 w \(number(4)) \(number(y)) m \(number(max(size.width - 4, 4))) \(number(y)) l S Q\n"
        return Data(content.utf8)
    }
}
