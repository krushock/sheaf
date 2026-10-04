import Foundation

/// The few operations a picture drawn on its own sits in: `q`, perhaps a `gs` that sets
/// how solid it is, a `cm` that places it, perhaps a rectangle that masks it, the picture
/// itself, and `Q`. Many writers draw pictures this way, and Sheaf keeps the ones it
/// changes in this form, so a change edits the numbers in place.
struct PictureGroup {
    /// From the `q` to the `Q`.
    var range: ClosedRange<Int>
    var state: ContentStream.Operation?
    var matrix: Affine
    /// The part of the picture that shows, in fractions of its unit square.
    var mask: PDFRectangle?

    /// - Parameter index: The operation that draws the picture.
    init?(around index: Int, in operations: [ContentStream.Operation]) {
        guard operations.indices.contains(index), index + 1 < operations.count, operations[index + 1].name == "Q" else { return nil }
        var cursor = index - 1
        if cursor >= 2, operations[cursor].name == "n", ["W", "W*"].contains(operations[cursor - 1].name), operations[cursor - 2].name == "re" {
            let numbers = operations[cursor - 2].operands.compactMap(\.doubleValue)
            guard numbers.count == 4 else { return nil }
            let left = max(min(numbers[0], numbers[0] + numbers[2]), 0), right = min(max(numbers[0], numbers[0] + numbers[2]), 1)
            let bottom = max(min(numbers[1], numbers[1] + numbers[3]), 0), top = min(max(numbers[1], numbers[1] + numbers[3]), 1)
            guard right - left > 1e-6, top - bottom > 1e-6 else { return nil }
            if left > 1e-6 || bottom > 1e-6 || right < 1 - 1e-6 || top < 1 - 1e-6 {
                mask = PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom)
            }
            cursor -= 3
        }
        guard cursor >= 0, operations[cursor].name == "cm", let matrix = Affine(operations[cursor].operands.compactMap(\.doubleValue)), matrix.inverse != nil else { return nil }
        self.matrix = matrix
        cursor -= 1
        if cursor >= 0, operations[cursor].name == "gs" {
            state = operations[cursor]
            cursor -= 1
        }
        guard cursor >= 0, operations[cursor].name == "q" else { return nil }
        range = cursor...(index + 1)
    }
}

extension PageImage {
    /// The part of the picture that shows, in fractions of the whole picture's width and
    /// height from the bottom left corner of `unmaskedPlacement`. `nil` when all of it shows.
    public var shownPart: PDFRectangle? {
        guard let mask else { return nil }
        // A mirrored picture's own left is on the right of where it shows.
        return matrix.determinant < 0 ? PDFRectangle(x: 1 - mask.x - mask.width, y: mask.y, width: mask.width, height: mask.height) : mask
    }
}

extension PDFEditor {
    private func editable(image id: Int, pageAt index: Int) throws -> (Interpretation, PageImage) {
        let interpretation = try interpret(pageAt: index)
        let content = Self.content(from: interpretation, source: self)
        guard let image = content.images.first(where: { $0.id == id }) else { throw SheafError.malformed("the page has no such picture") }
        guard image.isEditable else { throw SheafError.unsupported("changing this picture") }
        return (interpretation, image)
    }

    /// The operations that draw a picture, changed in some ways, and the operations of
    /// the page they take the place of.
    ///
    /// - Parameters:
    ///   - target: Where the whole picture's unit square goes on the page as displayed. `nil` leaves it.
    ///   - mask: The part that shows. `nil` leaves it as it is; `.some(nil)` shows all of it.
    ///   - state: The graphics state to draw it with. `nil` leaves it as it is.
    ///   - draw: The operation that draws the picture. `nil` keeps the one there.
    func pictureOperations(
        for image: PageImage, _ interpretation: Interpretation, matrix target: Affine? = nil, mask: PDFRectangle?? = nil,
        state: PDFName? = nil, draw: ContentStream.Operation? = nil
    ) -> (range: ClosedRange<Int>, operations: [ContentStream.Operation])? {
        let operations = interpretation.streams[0].content.operations
        let at = image.source.operation
        guard operations.indices.contains(at) else { return nil }
        let group = PictureGroup(around: at, in: operations)
        // The coordinates the picture's own `cm` is given in, seen from the page as displayed.
        let outer = group.flatMap { $0.matrix.inverse?.then(image.matrix) } ?? image.matrix
        guard let inverse = outer.inverse else { return nil }
        let own = (target ?? image.matrix).then(inverse)
        let numbers = [own.a, own.b, own.c, own.d, own.e, own.f].map { PDFObject.real(($0 * 100_000_000).rounded() / 100_000_000) }

        var result = [ContentStream.Operation("q")]
        if let state {
            result.append(ContentStream.Operation("gs", [.name(state)]))
        } else if let kept = group?.state {
            result.append(kept)
        }
        result.append(ContentStream.Operation("cm", numbers))
        let shown: PDFRectangle? = if let mask { mask } else { group?.mask }
        if let shown {
            let rectangle = [shown.x, shown.y, shown.width, shown.height].map { PDFObject.real(($0 * 1_000_000).rounded() / 1_000_000) }
            result += [ContentStream.Operation("re", rectangle), ContentStream.Operation("W"), ContentStream.Operation("n")]
        }
        result += [draw ?? operations[at], ContentStream.Operation("Q")]
        return (group?.range ?? at...at, result)
    }

    private mutating func redraw(
        _ image: PageImage, _ interpretation: Interpretation, onPageAt index: Int, matrix target: Affine? = nil, mask: PDFRectangle?? = nil,
        state: PDFName? = nil, draw: ContentStream.Operation? = nil, adding addition: PageAddition = PageAddition()
    ) throws {
        guard let (range, operations) = pictureOperations(for: image, interpretation, matrix: target, mask: mask, state: state, draw: draw) else { return }
        var replacements: [Int: [ContentStream.Operation]] = [:]
        for position in range { replacements[position] = [] }
        replacements[range.lowerBound] = operations
        try rewritePage(at: index, interpretation, replacing: replacements, adding: addition)
    }

    /// Moves and resizes a picture so that what shows of it fills a new frame, given on
    /// the page as displayed. The picture stays where it is in the page's stacking order.
    public mutating func setImageFrame(_ frame: PDFRectangle, ofImage id: Int, onPageAt index: Int) throws {
        let (interpretation, image) = try editable(image: id, pageAt: index)
        let old = image.frame
        guard old.width > 0, old.height > 0, frame.width > 0, frame.height > 0 else { return }
        // On the page as displayed: from the old frame to the new one.
        let change = Affine.translation(-old.x, -old.y)
            .then(.scale(frame.width / old.width, frame.height / old.height))
            .then(.translation(frame.x, frame.y))
        try redraw(image, interpretation, onPageAt: index, matrix: image.matrix.then(change))
    }

    /// Puts a picture somewhere else, at another size, turned by another angle, or mirrored.
    /// The picture stays where it is in the page's stacking order.
    public mutating func setImagePlacement(_ placement: ImagePlacement, ofImage id: Int, onPageAt index: Int) throws {
        let (interpretation, image) = try editable(image: id, pageAt: index)
        guard placement.width > 0, placement.height > 0, placement.width.isFinite, placement.height.isFinite, placement.rotation.isFinite else { return }
        try redraw(image, interpretation, onPageAt: index, matrix: placement.matrix(showing: image.mask))
    }

    /// Mirrors a picture where it is: left to right, or top to bottom, along its own sides.
    public mutating func flipImage(_ id: Int, onPageAt index: Int, horizontally: Bool) throws {
        let (interpretation, image) = try editable(image: id, pageAt: index)
        var placement = image.placement
        placement.isMirrored.toggle()
        // Top to bottom is left to right and half a turn.
        if !horizontally { placement.rotation = (placement.rotation + 180).truncatingRemainder(dividingBy: 360) }
        try redraw(image, interpretation, onPageAt: index, matrix: placement.matrix(showing: image.mask))
    }

    /// Sets how solid a picture is, from 0, which shows nothing of it, to 1.
    public mutating func setImageOpacity(_ opacity: Double, ofImage id: Int, onPageAt index: Int) throws {
        let (interpretation, image) = try editable(image: id, pageAt: index)
        let amount = (min(max(opacity.isFinite ? opacity : 1, 0), 1) * 1000).rounded() / 1000
        // One graphics state per amount, shared by every picture on the page that has it.
        let name = PDFName("SheafA\(Int(amount * 1000))")
        let state: PDFDictionary = ["Type": .name("ExtGState"), "ca": .real(amount), "CA": .real(amount)]
        try redraw(image, interpretation, onPageAt: index, state: name, adding: PageAddition(graphicsStates: [name: .dictionary(state)]))
    }

    /// Masks a picture, so only part of it shows, or shows all of it again. The picture
    /// itself stays where it is, and all of it stays in the file.
    ///
    /// - Parameter part: The part to show, as `PageImage.shownPart` gives it. `nil` shows everything.
    public mutating func setImageMask(_ part: PDFRectangle?, ofImage id: Int, onPageAt index: Int) throws {
        let (interpretation, image) = try editable(image: id, pageAt: index)
        guard var part else { return try redraw(image, interpretation, onPageAt: index, mask: .some(nil)) }
        let left = max(part.x, 0), bottom = max(part.y, 0), right = min(part.x + part.width, 1), top = min(part.y + part.height, 1)
        guard right - left > 0.001, top - bottom > 0.001 else { return }
        part = PDFRectangle(x: left, y: bottom, width: right - left, height: top - bottom)
        if image.matrix.determinant < 0 { part.x = 1 - part.x - part.width }
        let all = part.x < 1e-6 && part.y < 1e-6 && part.width > 1 - 1e-6 && part.height > 1 - 1e-6
        try redraw(image, interpretation, onPageAt: index, mask: .some(all ? nil : part))
    }

    /// Takes a picture off the page.
    public mutating func removeImage(_ id: Int, onPageAt index: Int) throws {
        let (interpretation, image) = try editable(image: id, pageAt: index)
        // With the operations that only placed it, when it was drawn on its own.
        let range = PictureGroup(around: image.source.operation, in: interpretation.streams[0].content.operations)?.range
        var replacements: [Int: [ContentStream.Operation]] = [:]
        for position in range ?? image.source.operation...image.source.operation { replacements[position] = [] }
        try rewritePage(at: index, interpretation, replacing: replacements)
    }

    /// Puts another picture in a picture's place. The new one is fitted inside what
    /// showed of the old one, keeping its own proportions, turned the way the old one
    /// was, and keeps the old one's place in the page's stacking order and how solid it was.
    ///
    /// - Parameter keepingShape: For a new version of the same picture, such as one with
    ///   its background taken out: it goes exactly where the old one is, stretched,
    ///   mirrored and masked the same.
    public mutating func replaceImage(_ id: Int, onPageAt index: Int, with data: Data, keepingShape: Bool = false) throws {
        let (interpretation, image) = try editable(image: id, pageAt: index)
        let (object, new) = try addImageObject(data)
        let name = PDFName("SheafIm\(object.number)")
        if keepingShape {
            return try redraw(image, interpretation, onPageAt: index, draw: ContentStream.Operation("Do", [.name(name)]), adding: PageAddition(xObjects: [name: .reference(object)]))
        }
        let upright = new.uprightSize
        let placement = image.placement
        let scale = min(placement.width / upright.width, placement.height / upright.height)
        // Where the new picture's unit square should show on the page as displayed:
        // in the middle of the old one, turned the way it was.
        let shown = Affine.scale(new.storedSize.width, new.storedSize.height)
            .then(new.uprightTransform)
            .then(.scale(scale, scale))
            .then(.translation(-upright.width * scale / 2, -upright.height * scale / 2))
            .then(.rotation(degrees: placement.rotation))
            .then(.translation(placement.center.x, placement.center.y))
        try redraw(
            image, interpretation, onPageAt: index, matrix: shown, mask: .some(nil),
            draw: ContentStream.Operation("Do", [.name(name)]), adding: PageAddition(xObjects: [name: .reference(object)])
        )
    }

    /// Adds a picture to a page, on top of what is there.
    ///
    /// - Parameter frame: Where it goes on the page as displayed. The picture is fitted
    ///   inside it, keeping its proportions. `nil` centers it at its natural size, scaled
    ///   down if it would not fit the page.
    /// - Returns: The frame the picture ended up with.
    @discardableResult
    public mutating func addImage(_ data: Data, toPageAt index: Int, in frame: PDFRectangle? = nil) throws -> PDFRectangle {
        let interpretation = try interpret(pageAt: index)
        let (object, image) = try addImageObject(data)
        let name = PDFName("SheafIm\(object.number)")
        let upright = image.uprightSize
        let page = interpretation.geometry.displaySize
        let area = frame ?? {
            let scale = min(1, page.width * 0.8 / upright.width, page.height * 0.8 / upright.height)
            let width = upright.width * scale, height = upright.height * scale
            return PDFRectangle(x: (page.width - width) / 2, y: (page.height - height) / 2, width: width, height: height)
        }()
        let scale = min(area.width / upright.width, area.height / upright.height)
        let placed = PDFRectangle(
            x: area.x + (area.width - upright.width * scale) / 2, y: area.y + (area.height - upright.height * scale) / 2,
            width: upright.width * scale, height: upright.height * scale
        )
        let matrix = Affine.scale(image.storedSize.width, image.storedSize.height)
            .then(image.uprightTransform)
            .then(.scale(scale, scale))
            .then(.translation(placed.x, placed.y))
        let addition = PageAddition(operators: "q \(matrix.operands) cm /\(name.rawValue) Do Q\n", xObjects: [name: .reference(object)])
        try rewritePage(at: index, interpretation, adding: addition)
        return placed
    }

    /// A one-page PDF showing one of a page's pictures alone: all of it, upright, a
    /// point to each of its pixels. An app can draw this to get at the picture itself,
    /// whichever way the file stores it. `nil` for a picture that cannot be read.
    public func pictureDocument(forImage id: Int, onPageAt index: Int) throws -> Data? {
        let interpretation = try interpret(pageAt: index)
        let content = Self.content(from: interpretation, source: self)
        guard let image = content.images.first(where: { $0.id == id }), interpretation.streams.indices.contains(image.source.stream) else { return nil }
        let operations = interpretation.streams[image.source.stream].content.operations
        guard operations.indices.contains(image.source.operation) else { return nil }
        var draw = operations[image.source.operation]

        var width = Double(image.pixelWidth), height = Double(image.pixelHeight)
        if draw.name == "BI", let dictionary = draw.operands.first?.dictionaryValue {
            width = (dictionary["W"] ?? dictionary["Width"] ?? .null).doubleValue ?? 0
            height = (dictionary["H"] ?? dictionary["Height"] ?? .null).doubleValue ?? 0
        }
        if width < 1 || height < 1 {
            let whole = image.unmaskedPlacement
            (width, height) = (max(whole.width, 1), max(whole.height, 1))
        }
        var target = PDFEditor(try PDFFile(data: MinimalPDF.data(version: base.version, pageBoxes: [PDFRectangle(x: 0, y: 0, width: width, height: height)])))
        let page = try target.pageIDs()[0]
        if let object = image.objectID {
            var copier = ObjectCopier(source: self, sourcePages: Set(try pageIDs()))
            let copied = try copier.copy(.reference(object), into: &target)
            try copier.finish(into: &target)
            try target.update(page) { $0["Resources"] = ["XObject": ["Im": copied]] }
            draw = ContentStream.Operation("Do", [.name("Im")])
        } else if draw.name != "BI" {
            return nil
        }
        var stream = ContentStream(data: Data())
        stream.operations = [
            ContentStream.Operation("q"), ContentStream.Operation("cm", [width, 0, 0, height, 0, 0].map(PDFObject.real)), draw, ContentStream.Operation("Q"),
        ]
        try target.setContentStream(stream, forPageAt: 0)
        return try target.rewritten()
    }
}
