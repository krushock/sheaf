import AppKit
import SheafKit
import SwiftUI

/// What clicking and dragging on a page does.
enum MarkupTool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strikeOut, note, text, rectangle, ellipse, line, arrow, draw, link

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .select: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strikethrough"
        case .note: "Note"
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .draw: "Draw"
        case .link: "Link"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "note.text"
        case .text: "character.textbox"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .draw: "scribble"
        case .link: "link"
        }
    }

    /// Tools that mark the text that gets selected while they are active.
    var textMarkupKind: Annotation.Kind? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        default: nil
        }
    }

    /// Whether the tool stays chosen after one use. Marking text and drawing usually come
    /// in runs; a shape or a note is usually a single thing.
    var staysActive: Bool {
        textMarkupKind != nil || self == .draw
    }

    /// The tool's name as text, for labels drawn by hand.
    var name: String {
        switch self {
        case .select: String(localized: "Select")
        case .highlight: String(localized: "Highlight")
        case .underline: String(localized: "Underline")
        case .strikeOut: String(localized: "Strikethrough")
        case .note: String(localized: "Note")
        case .text: String(localized: "Text")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .line: String(localized: "Line")
        case .arrow: String(localized: "Arrow")
        case .draw: String(localized: "Draw")
        case .link: String(localized: "Link")
        }
    }

    static let shapes: [MarkupTool] = [.rectangle, .ellipse, .line, .arrow]
    static let textMarks: [MarkupTool] = [.highlight, .underline, .strikeOut]
}

/// How the next thing a tool makes will look.
struct MarkupStyle: Equatable {
    var color: PDFColor
    var fillColor: PDFColor?
    var lineWidth = 2.0
    var opacity = 1.0
    var fontSize = 14.0

    static func standard(for tool: MarkupTool) -> MarkupStyle {
        switch tool {
        case .highlight, .note: MarkupStyle(color: .yellow)
        case .underline: MarkupStyle(color: .green)
        case .strikeOut, .rectangle, .ellipse, .line, .arrow: MarkupStyle(color: .red)
        case .text, .draw, .select, .link: MarkupStyle(color: .black)
        }
    }
}

/// One annotation, by where it is.
struct AnnotationSelection: Hashable {
    var pageIndex: Int
    var id: ObjectID
}

/// The places an annotation can be grabbed to change its size.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case lineStart, lineEnd

    /// Where the handle sits on a frame, as fractions of its width and height.
    var anchor: (x: Double, y: Double)? {
        switch self {
        case .topLeft: (0, 1)
        case .top: (0.5, 1)
        case .topRight: (1, 1)
        case .right: (1, 0.5)
        case .bottomRight: (1, 0)
        case .bottom: (0.5, 0)
        case .bottomLeft: (0, 0)
        case .left: (0, 0.5)
        case .lineStart, .lineEnd: nil
        }
    }

    static let frameHandles: [ResizeHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
}

/// The stamps offered in the Stamp menu.
enum StandardStamp: String, CaseIterable, Identifiable {
    case approved, draft, confidential, final, notApproved, completed, forComment, void

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .approved: "Approved"
        case .draft: "Draft"
        case .confidential: "Confidential"
        case .final: "Final"
        case .notApproved: "Not Approved"
        case .completed: "Completed"
        case .forComment: "For Comment"
        case .void: "Void"
        }
    }

    /// The words on the stamp. Stamps are part of the document, so they are not translated
    /// with the interface.
    var text: String {
        switch self {
        case .approved: "Approved"
        case .draft: "Draft"
        case .confidential: "Confidential"
        case .final: "Final"
        case .notApproved: "Not Approved"
        case .completed: "Completed"
        case .forComment: "For Comment"
        case .void: "Void"
        }
    }

    var color: PDFColor {
        switch self {
        case .approved, .completed, .final: .green
        case .draft, .forComment: .blue
        case .confidential, .notApproved, .void: .red
        }
    }
}

nonisolated extension PDFColor {
    init(_ color: NSColor) {
        let converted = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(converted.redComponent), green: Double(converted.greenComponent), blue: Double(converted.blueComponent))
    }

    init(_ color: Color) {
        self.init(NSColor(color))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// The colors offered as swatches, as in the system's markup tools.
    static let palette: [PDFColor] = [.yellow, .green, .blue, .pink, .purple, .red, .orange, .black, .white]
}

extension PDFRectangle {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(_ rect: CGRect) {
        let standardized = rect.standardized
        self.init(x: standardized.minX, y: standardized.minY, width: standardized.width, height: standardized.height)
    }

    /// The rectangle with two points as opposite corners.
    init(from first: PDFPoint, to second: PDFPoint) {
        self.init(x: min(first.x, second.x), y: min(first.y, second.y), width: abs(first.x - second.x), height: abs(first.y - second.y))
    }
}

extension PDFPoint {
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
