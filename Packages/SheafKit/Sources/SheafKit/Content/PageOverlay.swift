import Foundation

/// Text or a picture repeated across pages, such as "Draft" or a logo.
public struct Watermark: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// One or more lines of text.
        case text(String)
        case image(StampImage)
    }

    public enum Position: String, Sendable, CaseIterable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    }

    public var content: Content
    public var fontName = "Helvetica-Bold"
    public var fontSize = 72.0
    public var color = PDFColor(red: 0.5, green: 0.5, blue: 0.5)
    /// A picture's width as a share of the page's width.
    public var imageScale = 0.5
    public var opacity = 0.3
    /// Counter-clockwise, in degrees.
    public var rotation = 45.0
    public var position = Position.center
    /// Repeats the mark across the whole page instead of placing it once.
    public var isTiled = false
    /// Draws the mark under the page's content instead of on top of it.
    public var isBehindContent = false
    /// Space kept between the mark and the page's edges, except at the center.
    public var margin = 36.0

    public init(content: Content) {
        self.content = content
    }
}

/// Lines of text at the top and bottom of pages, such as page numbers.
public struct HeaderFooter: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var left = "", center = "", right = ""

        public init(left: String = "", center: String = "", right: String = "") {
            self.left = left
            self.center = center
            self.right = right
        }

        var isEmpty: Bool { left.isEmpty && center.isEmpty && right.isEmpty }
    }

    /// Replaced by the page's number.
    public static let pageToken = "{page}"
    /// Replaced by the number of the last page.
    public static let pagesToken = "{pages}"
    public static let dateToken = "{date}"
    /// Replaced by the document's name.
    public static let nameToken = "{name}"
    /// Replaced by the page's Bates number, counted among the pages marked.
    public static let batesToken = "{bates}"

    public var header = Row()
    public var footer = Row()
    public var fontName = "Helvetica"
    public var fontSize = 10.0
    public var color = PDFColor.black
    /// From the page's top edge to the top of the header.
    public var topMargin = 36.0
    /// From the page's bottom edge to the bottom of the footer.
    public var bottomMargin = 36.0
    public var sideMargin = 54.0
    /// The number the document's first page gets.
    public var firstNumber = 1
    /// What a Bates number is made of: the number the first marked page gets, how many
    /// digits it has at least, and the text before and after it.
    public var batesStart = 1
    public var batesDigits = 6
    public var batesPrefix = ""
    public var batesSuffix = ""

    public init() {}

    /// The Bates number of the page that comes at some place among the marked pages.
    public func batesNumber(at position: Int) -> String {
        let number = String(batesStart + position)
        let padding = String(repeating: "0", count: max(min(batesDigits, 15) - number.count, 0))
        return batesPrefix + padding + number + batesSuffix
    }

    public var isEmpty: Bool { header.isEmpty && footer.isEmpty }
}

extension PDFEditor {
    // MARK: Watermark

    /// Draws a watermark on pages. It becomes part of each page.
    ///
    /// The mark is stored once however many pages show it, and stands upright on pages
    /// that are turned.
    ///
    /// - Parameter indexes: The pages to mark. All of them when `nil`.
    public mutating func addWatermark(_ watermark: Watermark, toPagesAt indexes: [Int]? = nil) throws {
        let pages = try pageIDs()
        let targets = indexes ?? Array(pages.indices)
        for index in targets where !pages.indices.contains(index) { throw SheafError.pageOutOfRange(index) }

        // Text is the same on every page. A picture is sized to each page, so its drawing
        // is made one unit wide and stretched when placed.
        let mark: (form: ObjectID, width: Double, height: Double)
        switch watermark.content {
        case .text(let text):
            guard let made = textWatermark(text, watermark) else { return }
            mark = made
        case .image(let image):
            guard image.width > 0, image.height > 0 else { return }
            mark = imageWatermark(image, opacity: watermark.opacity)
        }

        var wrappers = ContentWrappers()
        for index in Set(targets).sorted() {
            let geometry = try geometry(ofPageAt: index)
            let page = geometry.displaySize
            var scale = 1.0
            if case .image = watermark.content { scale = page.width * max(watermark.imageScale, 0.01) }
            let width = mark.width * scale, height = mark.height * scale

            // The room the mark takes once turned.
            let radians = watermark.rotation * .pi / 180
            let turnedWidth = abs(width * cos(radians)) + abs(height * sin(radians))
            let turnedHeight = abs(width * sin(radians)) + abs(height * cos(radians))
            let centers = watermark.isTiled
                ? Self.tileCenters(page: page, width: turnedWidth, height: turnedHeight)
                : [Self.center(for: watermark.position, page: page, width: turnedWidth, height: turnedHeight, margin: watermark.margin)]

            try addDrawing(toPage: pages[index], behind: watermark.isBehindContent, wrappers: &wrappers) { resources in
                let name = resources.add(xObject: mark.form, prefix: "SheafWm")
                var content = "/Artifact <</Type /Pagination /Subtype /Watermark>> BDC\n"
                for center in centers {
                    let placement = Affine.scale(scale, scale)
                        .then(.rotation(degrees: watermark.rotation))
                        .then(.translation(center.x, center.y))
                        .then(geometry.fromDisplay)
                    content += "q \(placement.operands) cm /\(name.rawValue) Do Q\n"
                }
                content += "EMC\n"
                return Data(content.utf8)
            }
        }
    }

    private mutating func textWatermark(_ text: String, _ watermark: Watermark) -> (form: ObjectID, width: Double, height: Double)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { TextOutliner.line(String($0), fontName: watermark.fontName, fontSize: watermark.fontSize) }
        guard let width = lines.map(\.width).max(), width > 0, let first = lines.first else { return nil }
        let lineHeight = (first.ascent + first.descent) * 1.15
        let height = lineHeight * Double(lines.count)

        // Centered on the origin, so the mark turns about its middle.
        var content = "/GS0 gs \(Serializer.format(watermark.color.red)) \(Serializer.format(watermark.color.green)) \(Serializer.format(watermark.color.blue)) rg\n"
        for (index, line) in lines.enumerated() {
            let baseline = height / 2 - lineHeight * Double(index) - (lineHeight - first.ascent - first.descent) / 2 - first.ascent
            let shift = Affine.translation(-line.width / 2, baseline)
            content += Self.pathOperators(line.elements.map { $0.applying(shift) })
        }
        content += "f\n"
        // Room for accents and tails that reach past the line's nominal size.
        let reach = watermark.fontSize * 0.3
        let box = PDFRectangle(x: -width / 2 - reach, y: -height / 2 - reach, width: width + 2 * reach, height: height + 2 * reach)
        let form = add(.stream(PDFStream(
            dictionary: [
                "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": box.object, "Filter": .name("FlateDecode"),
                "Resources": ["ExtGState": ["GS0": Self.opacityState(watermark.opacity)]],
            ],
            data: Flate.deflate(Data(content.utf8))
        )))
        return (form, width, height)
    }

    private mutating func imageWatermark(_ image: StampImage, opacity: Double) -> (form: ObjectID, width: Double, height: Double) {
        var (stream, mask) = Appearance.imageObjects(for: image)
        if let mask { stream.dictionary["SMask"] = .reference(add(.stream(mask))) }
        let picture = add(.stream(stream))
        // One unit wide, centered on the origin.
        let height = Double(image.height) / Double(image.width)
        let content = "/GS0 gs q 1 0 0 \(Serializer.format(height)) -0.5 \(Serializer.format(-height / 2)) cm /Im0 Do Q\n"
        let form = add(.stream(PDFStream(
            dictionary: [
                "Type": .name("XObject"), "Subtype": .name("Form"),
                "BBox": [.real(-0.5), .real(-height / 2), .real(0.5), .real(height / 2)],
                "Resources": ["ExtGState": ["GS0": Self.opacityState(opacity)], "XObject": ["Im0": .reference(picture)]],
            ],
            data: Data(content.utf8)
        )))
        return (form, 1, height)
    }

    private static func opacityState(_ opacity: Double) -> PDFObject {
        let value = min(max(opacity, 0), 1)
        return ["Type": .name("ExtGState"), "CA": .real(value), "ca": .real(value)]
    }

    private static func center(for position: Watermark.Position, page: PageSize, width: Double, height: Double, margin: Double) -> PDFPoint {
        let left = margin + width / 2, right = page.width - margin - width / 2
        let bottom = margin + height / 2, top = page.height - margin - height / 2
        let (centerX, centerY) = (page.width / 2, page.height / 2)
        return switch position {
        case .topLeft: PDFPoint(x: left, y: top)
        case .top: PDFPoint(x: centerX, y: top)
        case .topRight: PDFPoint(x: right, y: top)
        case .left: PDFPoint(x: left, y: centerY)
        case .center: PDFPoint(x: centerX, y: centerY)
        case .right: PDFPoint(x: right, y: centerY)
        case .bottomLeft: PDFPoint(x: left, y: bottom)
        case .bottom: PDFPoint(x: centerX, y: bottom)
        case .bottomRight: PDFPoint(x: right, y: bottom)
        }
    }

    /// Centers for a grid of marks covering the page, every other row shifted by half a step.
    private static func tileCenters(page: PageSize, width: Double, height: Double) -> [PDFPoint] {
        let stepX = max(width * 1.4, 40), stepY = max(height * 1.4, 40)
        let rows = Int((page.height / stepY).rounded(.up)) + 1
        let columns = Int((page.width / stepX).rounded(.up)) + 1
        guard rows * columns <= 2000 else { return [PDFPoint(x: page.width / 2, y: page.height / 2)] }
        var centers: [PDFPoint] = []
        // Start from the middle so the pattern sits evenly on the page.
        for row in -rows / 2...rows / 2 {
            for column in -columns / 2...columns / 2 {
                let x = page.width / 2 + (Double(column) + (row % 2 == 0 ? 0 : 0.5)) * stepX
                let y = page.height / 2 + Double(row) * stepY
                if x > -width / 2, x < page.width + width / 2, y > -height / 2, y < page.height + height / 2 {
                    centers.append(PDFPoint(x: x, y: y))
                }
            }
        }
        return centers
    }

    // MARK: Header and footer

    /// Draws a header and footer on pages. They become part of each page.
    ///
    /// - Parameters:
    ///   - indexes: The pages to draw on. All of them when `nil`.
    ///   - documentName: What `{name}` stands for.
    ///   - date: What `{date}` stands for, already written the way it should appear.
    public mutating func addHeaderFooter(_ spec: HeaderFooter, toPagesAt indexes: [Int]? = nil, documentName: String = "", date: String = "") throws {
        guard !spec.isEmpty else { return }
        let pages = try pageIDs()
        let targets = indexes ?? Array(pages.indices)
        for index in targets where !pages.indices.contains(index) { throw SheafError.pageOutOfRange(index) }
        let lastNumber = pages.count + spec.firstNumber - 1

        var wrappers = ContentWrappers()
        for (position, index) in Set(targets).sorted().enumerated() {
            let geometry = try geometry(ofPageAt: index)
            let page = geometry.displaySize
            func filled(_ text: String) -> String {
                text.replacingOccurrences(of: HeaderFooter.batesToken, with: spec.batesNumber(at: position))
                    .replacingOccurrences(of: HeaderFooter.pageToken, with: "\(index + spec.firstNumber)")
                    .replacingOccurrences(of: HeaderFooter.pagesToken, with: "\(lastNumber)")
                    .replacingOccurrences(of: HeaderFooter.dateToken, with: date)
                    .replacingOccurrences(of: HeaderFooter.nameToken, with: documentName)
            }

            var paths = ""
            for (row, isHeader) in [(spec.header, true), (spec.footer, false)] {
                for (text, alignment) in [(row.left, 0), (row.center, 1), (row.right, 2)] where !text.isEmpty {
                    let line = TextOutliner.line(filled(text), fontName: spec.fontName, fontSize: spec.fontSize)
                    let x = switch alignment {
                    case 0: spec.sideMargin
                    case 1: (page.width - line.width) / 2
                    default: page.width - spec.sideMargin - line.width
                    }
                    let baseline = isHeader ? page.height - spec.topMargin - line.ascent : spec.bottomMargin + line.descent
                    let placement = Affine.translation(x, baseline).then(geometry.fromDisplay)
                    paths += Self.pathOperators(line.elements.map { $0.applying(placement) })
                }
            }
            guard !paths.isEmpty else { continue }
            let color = "\(Serializer.format(spec.color.red)) \(Serializer.format(spec.color.green)) \(Serializer.format(spec.color.blue)) rg"
            let content = "/Artifact <</Type /Pagination>> BDC\nq \(color)\n\(paths)f\nQ\nEMC\n"
            try addDrawing(toPage: pages[index], behind: false, wrappers: &wrappers) { _ in Data(content.utf8) }
        }
    }

    // MARK: Background

    /// Fills pages with a color behind what they show, as paper of that color would.
    ///
    /// - Parameters:
    ///   - opacity: How much of the color shows, from 0 to 1.
    ///   - indexes: The pages to fill. All of them when `nil`.
    public mutating func addBackground(_ color: PDFColor, opacity: Double = 1, toPagesAt indexes: [Int]? = nil) throws {
        let pages = try pageIDs()
        let targets = indexes ?? Array(pages.indices)
        for index in targets where !pages.indices.contains(index) { throw SheafError.pageOutOfRange(index) }
        let fill = "\(Serializer.format(color.red)) \(Serializer.format(color.green)) \(Serializer.format(color.blue)) rg"
        // A unit square, stretched over each page when placed.
        let form = add(.stream(PDFStream(
            dictionary: [
                "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": [.integer(0), .integer(0), .integer(1), .integer(1)],
                "Resources": ["ExtGState": ["GS0": Self.opacityState(opacity)]],
            ],
            data: Data("/GS0 gs \(fill) 0 0 1 1 re f\n".utf8)
        )))
        var wrappers = ContentWrappers()
        for index in Set(targets).sorted() {
            let geometry = try geometry(ofPageAt: index)
            let page = geometry.displaySize
            try addDrawing(toPage: pages[index], behind: true, wrappers: &wrappers) { resources in
                let name = resources.add(xObject: form, prefix: "SheafBg")
                let placement = Affine.scale(page.width, page.height).then(geometry.fromDisplay)
                return Data("/Artifact <</Type /Pagination /Subtype /Background>> BDC\nq \(placement.operands) cm /\(name.rawValue) Do Q\nEMC\n".utf8)
            }
        }
    }

    static func pathOperators(_ elements: [PathElement]) -> String {
        func point(_ point: PDFPoint) -> String { "\(Serializer.format(point.x)) \(Serializer.format(point.y))" }
        var result = ""
        for element in elements {
            switch element {
            case .move(let target): result += "\(point(target)) m\n"
            case .line(let target): result += "\(point(target)) l\n"
            case .curve(let control1, let control2, let end): result += "\(point(control1)) \(point(control2)) \(point(end)) c\n"
            case .close: result += "h\n"
            }
        }
        return result
    }

    // MARK: Drawing on pages

    /// Adds drawing to a page, over or under what is already there.
    ///
    /// - Parameters:
    ///   - wrappers: Shared between the pages of one operation, so the small streams that
    ///     fence off the page's own drawing are stored once.
    ///   - build: Returns the drawing instructions, registering what they refer to.
    mutating func addDrawing(
        toPage page: ObjectID, behind: Bool, wrappers: inout ContentWrappers,
        _ build: (inout PageResources) throws -> Data
    ) throws {
        guard let dictionary = try object(page).dictionaryValue else { throw SheafError.malformed("page is not a dictionary") }
        var resources = PageResources(dictionary: try inherited("Resources", forPage: page).map(resolve)?.dictionaryValue ?? [:])
        resources.xObjects = try value("XObject", in: resources.dictionary).dictionaryValue ?? [:]
        let drawing = try build(&resources)
        guard !drawing.isEmpty else { return }

        let stream = add(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(drawing))))
        let original = try value("Contents", in: dictionary)
        let parts: [PDFObject] = original.arrayValue ?? (dictionary["Contents"].map { [$0] } ?? [])
        let contents: [PDFObject]
        if behind {
            // Drawn first, and it restores the drawing state it changes.
            contents = [.reference(stream)] + parts
        } else {
            // The page's own drawing is fenced off, so that whatever state it leaves behind
            // cannot affect what is drawn after it.
            if wrappers.opening == nil { wrappers.opening = add(.stream(PDFStream(data: Data("q\n".utf8)))) }
            if wrappers.closing == nil { wrappers.closing = add(.stream(PDFStream(data: Data("\nQ\n".utf8)))) }
            contents = [.reference(wrappers.opening!)] + parts + [.reference(wrappers.closing!), .reference(stream)]
        }
        if !resources.xObjects.isEmpty { resources.dictionary["XObject"] = .dictionary(resources.xObjects) }
        let pageResources = resources.dictionary
        let usesResources = resources.didChange
        try update(page) { dictionary in
            dictionary["Contents"] = .array(contents)
            // A copy of the resources for this page alone; other pages may share the original.
            if usesResources { dictionary["Resources"] = .dictionary(pageResources) }
        }
    }
}

/// The two tiny streams that fence off a page's own drawing.
struct ContentWrappers {
    var opening: ObjectID?
    var closing: ObjectID?
}

/// What a page's drawing may refer to by name.
struct PageResources {
    var dictionary: PDFDictionary
    var xObjects: PDFDictionary = [:]
    private(set) var didChange = false

    /// Registers a form or image under a name nothing else on the page uses.
    mutating func add(xObject id: ObjectID, prefix: String) -> PDFName {
        var suffix = 1
        while xObjects[PDFName("\(prefix)\(suffix)")] != nil { suffix += 1 }
        let name = PDFName("\(prefix)\(suffix)")
        xObjects[name] = .reference(id)
        didChange = true
        return name
    }
}
