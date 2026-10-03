import Foundation

public struct PDFPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A color in the device RGB space, each component from 0 to 1.
public struct PDFColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = PDFColor(red: 0, green: 0, blue: 0)
    public static let white = PDFColor(red: 1, green: 1, blue: 1)
    public static let red = PDFColor(red: 1, green: 0.23, blue: 0.19)
    public static let orange = PDFColor(red: 1, green: 0.58, blue: 0)
    public static let yellow = PDFColor(red: 1, green: 0.84, blue: 0.04)
    public static let green = PDFColor(red: 0.2, green: 0.78, blue: 0.35)
    public static let blue = PDFColor(red: 0, green: 0.48, blue: 1)
    public static let purple = PDFColor(red: 0.69, green: 0.32, blue: 0.87)
    public static let pink = PDFColor(red: 1, green: 0.18, blue: 0.33)

    /// From a color array of one (gray), three (RGB) or four (CMYK) numbers.
    init?(_ object: PDFObject?) {
        guard let values = object?.arrayValue?.compactMap(\.doubleValue) else { return nil }
        switch values.count {
        case 1: self.init(red: values[0], green: values[0], blue: values[0])
        case 3: self.init(red: values[0], green: values[1], blue: values[2])
        case 4:
            let black = 1 - values[3]
            self.init(red: (1 - values[0]) * black, green: (1 - values[1]) * black, blue: (1 - values[2]) * black)
        default: return nil
        }
    }

    var object: PDFObject { [.real(red), .real(green), .real(blue)] }
}

/// The pixels of an image placed by a stamp, such as a scanned signature.
public struct StampImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Three bytes per pixel, rows from the top.
    public var rgb: Data
    /// One byte of opacity per pixel, when the image has transparent parts.
    public var alpha: Data?

    public init(width: Int, height: Int, rgb: Data, alpha: Data?) {
        self.width = width
        self.height = height
        self.rgb = rgb
        self.alpha = alpha
    }
}

/// A comment, drawing, stamp or link placed on top of a page.
///
/// One type covers every kind, so that code handling selection, styling and undo does not
/// branch on kind. Fields that do not apply to a kind are simply left at their defaults.
public struct Annotation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case highlight, underline, strikeOut, note, freeText, square, circle, line, ink, stamp, link
        /// Anything this engine does not model, such as form fields. Kept as it is.
        case other
    }

    public enum LineEnding: String, Sendable {
        case none, openArrow, closedArrow
    }

    public enum TextAlignment: Int, Sendable {
        case left, center, right
    }

    public enum LinkTarget: Sendable, Equatable {
        case url(String)
        /// A page of this document, counted from zero.
        case page(Int)
    }

    public enum StampContent: Sendable, Equatable {
        /// Words in a frame, such as "Approved".
        case text(String)
        /// Pen strokes, with points inside the unit square and the origin at the bottom left.
        case strokes([[PDFPoint]], lineWidth: Double)
        /// Filled outlines inside the unit square, such as a name set in a script typeface.
        case shapes([PathElement])
        case image(StampImage)
    }

    public var kind: Kind
    /// Where the annotation is on the page, in page coordinates.
    public var rect: PDFRectangle
    /// The main color: the marker color, the line color, or the text color of a text box.
    public var color: PDFColor?
    /// What a shape or text box is filled with.
    public var fillColor: PDFColor?
    public var opacity = 1.0
    public var lineWidth = 1.0
    /// A note's text, a text box's text, or a comment attached to any other kind.
    public var contents = ""
    public var author: String?
    public var modified: Date?
    /// The areas of text a highlight, underline or strikethrough covers, one per line.
    public var quads: [PDFRectangle] = []
    /// Freehand strokes.
    public var paths: [[PDFPoint]] = []
    public var lineStart: PDFPoint?
    public var lineEnd: PDFPoint?
    public var startEnding = LineEnding.none
    public var endEnding = LineEnding.none
    public var fontName = "Helvetica"
    public var fontSize = 14.0
    public var alignment = TextAlignment.left
    public var link: LinkTarget?
    /// What a new stamp shows. `nil` for stamps read from a file, whose look is kept as it is.
    public var stamp: StampContent?
    /// The annotation this one is a reply to.
    public var replyTo: ObjectID?

    /// The object that holds the annotation, once it is part of a document.
    public internal(set) var objectID: ObjectID?
    /// The raw type name, for kinds this engine does not model.
    public internal(set) var subtype: PDFName
    /// Names the picture the document stores for the annotation and the state it is in.
    /// It changes when either does, which is how a form field shows that it was filled in.
    public internal(set) var storedLook: String?

    public var id: ObjectID { objectID ?? ObjectID(-1) }

    public init(kind: Kind, rect: PDFRectangle) {
        self.kind = kind
        self.rect = rect
        subtype = Self.subtypes[kind] ?? "Unknown"
    }

    static let subtypes: [Kind: PDFName] = [
        .highlight: "Highlight", .underline: "Underline", .strikeOut: "StrikeOut", .note: "Text", .freeText: "FreeText",
        .square: "Square", .circle: "Circle", .line: "Line", .ink: "Ink", .stamp: "Stamp", .link: "Link",
    ]

    /// Kinds that mark up a run of text.
    public var isTextMarkup: Bool {
        kind == .highlight || kind == .underline || kind == .strikeOut
    }

    /// Whether dragging a corner should change the annotation's size.
    public var isResizable: Bool {
        switch kind {
        case .freeText, .square, .circle, .stamp, .link, .ink, .line: true
        // Form fields, which are moved and sized like anything else on the page.
        default: subtype == "Widget"
        }
    }

    /// Moves the annotation, including the geometry inside it.
    public mutating func translate(dx: Double, dy: Double) {
        rect.x += dx
        rect.y += dy
        quads = quads.map { PDFRectangle(x: $0.x + dx, y: $0.y + dy, width: $0.width, height: $0.height) }
        paths = paths.map { $0.map { PDFPoint(x: $0.x + dx, y: $0.y + dy) } }
        lineStart = lineStart.map { PDFPoint(x: $0.x + dx, y: $0.y + dy) }
        lineEnd = lineEnd.map { PDFPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// Gives the annotation a new frame, scaling the geometry inside it to match.
    public mutating func resize(to newRect: PDFRectangle) {
        let old = rect
        guard old.width > 0, old.height > 0, newRect.width > 0, newRect.height > 0 else { return }
        func map(_ point: PDFPoint) -> PDFPoint {
            PDFPoint(
                x: newRect.x + (point.x - old.x) / old.width * newRect.width,
                y: newRect.y + (point.y - old.y) / old.height * newRect.height
            )
        }
        paths = paths.map { $0.map(map) }
        lineStart = lineStart.map(map)
        lineEnd = lineEnd.map(map)
        rect = newRect
    }
}

// MARK: - Reading

extension ObjectSource {
    /// The annotations on a page, in the order the page lists them.
    public func annotations(forPage page: ObjectID) throws -> [Annotation] {
        guard let dictionary = try object(page).dictionaryValue else { return [] }
        var pageIndexes: [ObjectID: Int]?
        var result: [Annotation] = []
        for entry in try value("Annots", in: dictionary).arrayValue ?? [] {
            guard let annotation = try resolve(entry).dictionaryValue else { continue }
            result.append(try read(annotation, id: entry.referenceValue) { [self] target in
                if pageIndexes == nil {
                    pageIndexes = Dictionary(try pageIDs().enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                }
                return pageIndexes?[target]
            })
        }
        return result
    }

    private func read(_ dictionary: PDFDictionary, id: ObjectID?, pageIndex: (ObjectID) throws -> Int?) throws -> Annotation {
        let subtype = dictionary["Subtype"]?.nameValue ?? "Unknown"
        let kind = Annotation.subtypes.first { $0.value == subtype }?.key ?? .other
        let rect = PDFRectangle(try value("Rect", in: dictionary)) ?? PDFRectangle(x: 0, y: 0, width: 0, height: 0)
        var annotation = Annotation(kind: kind, rect: rect)
        annotation.subtype = subtype
        annotation.objectID = id
        if subtype == "Widget" {
            let normal = try value("AP", in: dictionary).dictionaryValue?["N"]
            let state = dictionary["AS"]?.nameValue?.rawValue ?? ""
            annotation.storedLook = "\(normal?.referenceValue?.number ?? 0)/\(state)/\(String(describing: normal).count)"
        }
        annotation.color = PDFColor(try value("C", in: dictionary))
        annotation.fillColor = PDFColor(try value("IC", in: dictionary))
        annotation.opacity = try value("CA", in: dictionary).doubleValue ?? 1
        annotation.contents = try value("Contents", in: dictionary).textValue ?? ""
        annotation.author = try value("T", in: dictionary).textValue
        annotation.modified = try value("M", in: dictionary).textValue.flatMap(PDFDate.decode)
        annotation.replyTo = dictionary["IRT"]?.referenceValue

        let style = try value("BS", in: dictionary).dictionaryValue
        let border = try value("Border", in: dictionary).arrayValue
        annotation.lineWidth = style?["W"]?.doubleValue ?? border?.dropFirst(2).first?.doubleValue ?? 1

        let numbers = try value("QuadPoints", in: dictionary).arrayValue?.compactMap(\.doubleValue) ?? []
        var index = 0
        while index + 8 <= numbers.count {
            let xs = stride(from: index, to: index + 8, by: 2).map { numbers[$0] }
            let ys = stride(from: index + 1, to: index + 8, by: 2).map { numbers[$0] }
            annotation.quads.append(PDFRectangle(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            index += 8
        }

        for stroke in try value("InkList", in: dictionary).arrayValue ?? [] {
            let values = try resolve(stroke).arrayValue?.compactMap(\.doubleValue) ?? []
            annotation.paths.append(stride(from: 0, to: values.count - 1, by: 2).map { PDFPoint(x: values[$0], y: values[$0 + 1]) })
        }

        if let ends = try value("L", in: dictionary).arrayValue?.compactMap(\.doubleValue), ends.count == 4 {
            annotation.lineStart = PDFPoint(x: ends[0], y: ends[1])
            annotation.lineEnd = PDFPoint(x: ends[2], y: ends[3])
        }
        if let endings = try value("LE", in: dictionary).arrayValue?.map(\.nameValue), endings.count == 2 {
            func ending(_ name: PDFName?) -> Annotation.LineEnding {
                name == "OpenArrow" ? .openArrow : name == "ClosedArrow" ? .closedArrow : .none
            }
            annotation.startEnding = ending(endings[0])
            annotation.endEnding = ending(endings[1])
        }

        if kind == .freeText {
            // The text style lives in a snippet of content stream syntax: "/Helv 12 Tf 0 g".
            let appearance = try value("DA", in: dictionary).stringValue ?? Data()
            var textColor: PDFColor?
            for operation in ContentStream(data: appearance).operations {
                switch operation.name {
                case "Tf": annotation.fontSize = operation.operands.last?.doubleValue ?? annotation.fontSize
                case "g", "rg", "k": textColor = PDFColor(.array(operation.operands))
                default: break
                }
            }
            annotation.fillColor = annotation.color
            annotation.color = textColor ?? .black
            annotation.alignment = Annotation.TextAlignment(rawValue: try value("Q", in: dictionary).intValue ?? 0) ?? .left
            if let font = try value("SheafFont", in: dictionary).textValue { annotation.fontName = font }
            if style == nil, border == nil { annotation.lineWidth = 0 }
        }

        // Lines, drawings and text marks take their frame from their geometry. The stored
        // rectangle is larger, to make room for line thickness and arrowheads.
        let geometry: [PDFPoint] = switch kind {
        case .ink: annotation.paths.flatMap { $0 }
        case .line: [annotation.lineStart, annotation.lineEnd].compactMap { $0 }
        case .highlight, .underline, .strikeOut:
            annotation.quads.flatMap { [PDFPoint(x: $0.x, y: $0.y), PDFPoint(x: $0.x + $0.width, y: $0.y + $0.height)] }
        default: []
        }
        if let frame = PDFRectangle(enclosing: geometry) { annotation.rect = frame }

        if kind == .link {
            let action = try value("A", in: dictionary).dictionaryValue
            if action?["S"]?.nameValue == "URI", let url = try action.map({ try value("URI", in: $0) })?.textValue {
                annotation.link = .url(url)
            } else if let destination = try resolveDestination(dictionary["Dest"] ?? action?["D"] ?? .null),
                      let target = destination.first?.referenceValue, let index = try pageIndex(target) {
                annotation.link = .page(index)
            }
        }
        return annotation
    }

    /// A destination as its array form, looking names up in the document's name tables.
    func resolveDestination(_ destination: PDFObject) throws -> [PDFObject]? {
        let resolved = try resolve(destination)
        if let array = resolved.arrayValue { return array }
        if let dictionary = resolved.dictionaryValue { return try value("D", in: dictionary).arrayValue }
        let key: Data
        if let name = resolved.nameValue {
            key = Data(name.bytes)
            if let table = try value("Dests", in: try catalog()).dictionaryValue, let found = table[name] {
                return try resolveDestination(found)
            }
        } else if let string = resolved.stringValue {
            key = string
        } else {
            return nil
        }
        guard let names = try value("Names", in: try catalog()).dictionaryValue,
              let tree = names["Dests"], let found = try lookup(key, inNameTree: tree, depth: 0)
        else { return nil }
        return try resolveDestination(found)
    }

    private func lookup(_ key: Data, inNameTree node: PDFObject, depth: Int) throws -> PDFObject? {
        guard depth < 32, let dictionary = try resolve(node).dictionaryValue else { return nil }
        if let pairs = try value("Names", in: dictionary).arrayValue {
            var index = 0
            while index + 1 < pairs.count {
                if try resolve(pairs[index]).stringValue == key { return pairs[index + 1] }
                index += 2
            }
        }
        for kid in try value("Kids", in: dictionary).arrayValue ?? [] {
            if let limits = try resolve(kid).dictionaryValue.flatMap({ try value("Limits", in: $0).arrayValue }),
               limits.count == 2, let low = limits[0].stringValue, let high = limits[1].stringValue,
               key.lexicographicallyPrecedes(low) || high.lexicographicallyPrecedes(key) { continue }
            if let found = try lookup(key, inNameTree: kid, depth: depth + 1) { return found }
        }
        return nil
    }
}
