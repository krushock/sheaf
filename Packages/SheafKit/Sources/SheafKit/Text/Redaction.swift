import Foundation

/// What a redaction took out.
public struct RedactionResult: Sendable, Equatable {
    public var glyphs = 0
    public var images = 0
    public var shapes = 0
    public var annotations = 0

    public var isEmpty: Bool { glyphs + images + shapes + annotations == 0 }

    static func + (a: RedactionResult, b: RedactionResult) -> RedactionResult {
        RedactionResult(glyphs: a.glyphs + b.glyphs, images: a.images + b.images, shapes: a.shapes + b.shapes, annotations: a.annotations + b.annotations)
    }
}

extension PDFEditor {
    // MARK: Marks

    /// The areas marked for redaction on a page, on the page as displayed.
    public func redactionMarks(onPageAt index: Int) throws -> [PDFRectangle] {
        let geometry = try geometry(ofPageAt: index)
        return try annotations(onPageAt: index).filter { $0.kind == .redact }.map { geometry.displayRect($0.rect) }
    }

    /// The pages that have redaction marks, by index. Quick, as it reads only what kind
    /// each annotation is.
    public func pagesWithRedactionMarks() throws -> [Int] {
        var result: [Int] = []
        for (index, page) in try pageIDs().enumerated() {
            let entries = try value("Annots", in: try object(page).dictionaryValue ?? [:]).arrayValue ?? []
            let isMarked = try entries.contains { entry in
                try value("Subtype", in: try resolve(entry).dictionaryValue ?? [:]).nameValue?.rawValue == "Redact"
            }
            if isMarked { result.append(index) }
        }
        return result
    }

    /// Removes for good what is under every redaction mark, on one page or on all, and
    /// takes the marks away.
    @discardableResult
    public mutating func applyRedactions(onPageAt index: Int? = nil, fill: PDFColor = .black) throws -> RedactionResult {
        var total = RedactionResult()
        let count = try pageCount()
        for page in index.map({ [$0] }) ?? Array(0..<count) {
            let marks = try annotations(onPageAt: page).filter { $0.kind == .redact }
            guard !marks.isEmpty else { continue }
            let geometry = try geometry(ofPageAt: page)
            total = total + (try redact(marks.map { geometry.displayRect($0.rect) }, onPageAt: page, fill: fill))
        }
        return total
    }

    // MARK: Removing

    private static func overlap(_ a: PDFRectangle, _ b: PDFRectangle) -> Double {
        let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x), height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return width > 0 && height > 0 ? width * height : 0
    }

    /// Removes what is inside some areas of a page for good: text, the covered parts of
    /// pictures, shapes that lie inside, and annotations that touch them. A filled box is
    /// drawn over each area.
    ///
    /// The text is taken out of the page's drawing instructions, not hidden. Saving by
    /// appending would still leave the old instructions earlier in the file, so a
    /// redacted document must be written out afresh, with `rewritten`.
    ///
    /// - Parameters:
    ///   - areas: On the page as displayed.
    ///   - fill: The color of the boxes. `nil` draws none.
    @discardableResult
    public mutating func redact(_ areas: [PDFRectangle], onPageAt index: Int, fill: PDFColor? = .black) throws -> RedactionResult {
        guard !areas.isEmpty else { return RedactionResult() }
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        let interpretation = try interpret(pageAt: index, includingPaths: true)
        var result = RedactionResult()

        /// What changes in each stream: operations replaced, and objects to add under new names.
        var replacements: [Int: [Int: [ContentStream.Operation]]] = [:]
        var additions: [Int: PDFDictionary] = [:]

        // Text: every glyph that lies in an area, by its box.
        var removedGlyphs: [ContentSource: Set<Int>] = [:]
        for glyph in interpretation.glyphs {
            let font = interpretation.fonts[glyph.font]
            let size = (glyph.matrix.c * glyph.matrix.c + glyph.matrix.d * glyph.matrix.d).squareRoot()
            guard size > 0 else { continue }
            let corners = [
                PDFPoint(x: 0, y: -font.descent / 1000), PDFPoint(x: glyph.width / 1000, y: -font.descent / 1000),
                PDFPoint(x: 0, y: font.ascent / 1000), PDFPoint(x: glyph.width / 1000, y: font.ascent / 1000),
            ].map(glyph.matrix.apply)
            guard let box = PDFRectangle(enclosing: corners) else { continue }
            let area = max(box.width * box.height, 0.01)
            let center = PDFPoint(x: box.x + box.width / 2, y: box.y + box.height / 2)
            // A font whose numbering cannot be followed may be placed wrongly; any touch counts.
            let threshold = font.isReliable ? 0.3 : 0
            if areas.contains(where: { $0.contains(center) || Self.overlap($0, box) > area * threshold }) {
                removedGlyphs[glyph.source, default: []].insert(glyph.index)
            }
        }
        for (source, removed) in removedGlyphs {
            let stream = interpretation.streams[source.stream]
            guard stream.content.operations.indices.contains(source.operation) else { continue }
            let shown = interpretation.glyphs.filter { $0.source == source }
            guard let first = shown.first else { continue }
            replacements[source.stream, default: [:]][source.operation] = Self.stripped(
                stream.content.operations[source.operation], removing: removed, glyphs: shown, font: interpretation.fonts[first.font]
            )
            result.glyphs += removed.count
        }

        // Shapes that lie inside an area go; shapes that only cross one stay, under the box.
        for path in interpretation.paths {
            let bounds = path.bounds
            guard areas.contains(where: { area in
                bounds.x >= area.x - 0.5 && bounds.y >= area.y - 0.5 && bounds.x + bounds.width <= area.x + area.width + 0.5 && bounds.y + bounds.height <= area.y + area.height + 0.5
            }) else { continue }
            for operation in path.operations where replacements[path.stream]?[operation] == nil {
                replacements[path.stream, default: [:]][operation] = []
            }
            result.shapes += 1
        }

        // Pictures: gone when wholly covered, painted over where partly covered.
        for image in interpretation.images {
            let corners = [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 0, y: 1), PDFPoint(x: 1, y: 1)].map(image.matrix.apply)
            guard let frame = PDFRectangle(enclosing: corners), frame.width > 0, frame.height > 0 else { continue }
            let touching = areas.filter { Self.overlap($0, frame) > 0 }
            guard !touching.isEmpty else { continue }
            let isCovered = touching.contains { Self.overlap($0, frame) >= frame.width * frame.height * 0.999 }
            var replacement: [ContentStream.Operation] = []
            if !isCovered, let inverse = image.matrix.inverse, let object = image.object, let original = try? self.object(object).streamValue,
               let width = try value("Width", in: original.dictionary).intValue, let height = try value("Height", in: original.dictionary).intValue,
               try value("ImageMask", in: original.dictionary).boolValue != true {
                // The areas, in the picture's own unit square.
                let regions = touching.compactMap { area -> PDFRectangle? in
                    let points = [
                        PDFPoint(x: area.x, y: area.y), PDFPoint(x: area.x + area.width, y: area.y),
                        PDFPoint(x: area.x, y: area.y + area.height), PDFPoint(x: area.x + area.width, y: area.y + area.height),
                    ].map(inverse.apply)
                    return PDFRectangle(enclosing: points)
                }
                // A document of its own showing just the picture, to draw it from.
                var single = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: Double(width), height: Double(height))])))
                var copier = ObjectCopier(source: self, sourcePages: Set(pages))
                let copied = try copier.copy(.reference(object), into: &single)
                try copier.finish(into: &single)
                let drawing = single.add(.stream(PDFStream(data: Data("q \(width) 0 0 \(height) 0 0 cm /Im0 Do Q".utf8))))
                try single.update(try single.pageIDs()[0]) { dictionary in
                    dictionary["Resources"] = ["XObject": ["Im0": copied]]
                    dictionary["Contents"] = .reference(drawing)
                }
                let filters = (try? StreamFilters.filters(of: original.dictionary, resolve: resolve).map(\.name)) ?? []
                let wasPhoto = filters.contains("DCTDecode") || filters.contains("JPXDecode")
                if let painted = ImageRedactor.redact(
                    document: try single.rewritten(), width: width, height: height, regions: regions, color: fill ?? .black, asJPEG: wasPhoto
                ) {
                    let name = PDFName("SheafRd\(nextObjectNumber)")
                    additions[image.source.stream, default: [:]][name] = .reference(add(.stream(painted)))
                    replacement = [ContentStream.Operation("Do", [.name(name)])]
                }
            }
            // A picture that could not be painted over is removed whole: better gone than leaked.
            replacements[image.source.stream, default: [:]][image.source.operation] = replacement
            result.images += 1
        }

        // Forms that changed are written out as new forms, innermost first, and each is
        // drawn in its parent under a new name. Other pages that use the old form are not affected.
        for streamIndex in interpretation.streams.indices.reversed() where streamIndex > 0 {
            guard replacements[streamIndex] != nil || additions[streamIndex] != nil else { continue }
            let stream = interpretation.streams[streamIndex]
            guard let form = stream.form, let original = try object(form).streamValue, let parent = stream.invokedFrom else { continue }
            var content = stream.content
            content.operations = content.operations.enumerated().flatMap { replacements[streamIndex]?[$0.offset] ?? [$0.element] }
            var resources = stream.resources
            if let added = additions[streamIndex] {
                let xObjects = try value("XObject", in: resources).dictionaryValue ?? [:]
                resources["XObject"] = .dictionary(xObjects.merging(added) { _, new in new })
            }
            var dictionary = original.dictionary
            for key in ["DecodeParms", "Length"] as [PDFName] { dictionary[key] = nil }
            dictionary["Filter"] = .name("FlateDecode")
            dictionary["Resources"] = .dictionary(resources)
            let copy = add(.stream(PDFStream(dictionary: dictionary, data: Flate.deflate(content.data()))))
            let name = PDFName("SheafRf\(copy.number)")
            additions[parent.stream, default: [:]][name] = .reference(copy)
            replacements[parent.stream, default: [:]][parent.operation] = [ContentStream.Operation("Do", [.name(name)])]
        }

        // The boxes, and the page's own content.
        var boxes = ""
        if let fill {
            boxes = "\(Serializer.format(fill.red)) \(Serializer.format(fill.green)) \(Serializer.format(fill.blue)) rg\n"
            for area in areas {
                boxes += "\(Serializer.format(area.x)) \(Serializer.format(area.y)) \(Serializer.format(area.width)) \(Serializer.format(area.height)) re\n"
            }
            boxes += "f\n"
        }
        try rewritePage(at: index, interpretation, replacing: replacements[0] ?? [:], adding: PageAddition(operators: boxes, xObjects: additions[0] ?? [:]))

        // Annotations in the areas, the marks among them: links, notes and fields can
        // carry the very text being removed.
        let geometry = interpretation.geometry
        for annotation in try annotations(onPageAt: index) {
            guard let id = annotation.objectID else { continue }
            let frame = geometry.displayRect(annotation.rect)
            guard areas.contains(where: { Self.overlap($0, frame) > 0 }) else { continue }
            if annotation.subtype == "Widget", (try? formField(forWidget: id)) != nil {
                try removeWidget(id)
            } else {
                try removeAnnotation(id, fromPageAt: index)
            }
            if annotation.kind != .redact { result.annotations += 1 }
        }
        return result
    }

    // MARK: Text for scanned pages

    /// Lays invisible text over a page, so that a scanned page can be searched, selected
    /// and copied from.
    ///
    /// - Parameter lines: Text with where it is, in fractions of the page as displayed.
    public mutating func addTextLayer(_ lines: [RecognizedText], toPageAt index: Int) throws {
        let interpretation = try interpret(pageAt: index)
        let page = interpretation.geometry.displaySize
        var text = GlyphText()
        text.prefix = "SheafOcr\(nextObjectNumber)x"
        for line in lines {
            let frame = PDFRectangle(x: line.frame.x * page.width, y: line.frame.y * page.height, width: line.frame.width * page.width, height: line.frame.height * page.height)
            guard frame.width > 0.5, frame.height > 0.5, !line.text.isEmpty else { continue }
            // One size and baseline for the whole line, so it reads as a line.
            let size = max(frame.height * 0.8, 1)
            let baseline = frame.y + frame.height * 0.2
            // Each word is stretched over its own place in the picture, or the line over
            // its place when the words' places are not known.
            let pieces = line.words.isEmpty ? [line] : line.words
            for (number, piece) in pieces.enumerated() {
                let left = piece.frame.x * page.width, width = piece.frame.width * page.width
                // A space after each word but the last, so readers that do not work out
                // spaces from gaps still get them.
                let isLast = number == pieces.count - 1
                var shaped = TextOutliner.shape(isLast ? piece.text : piece.text + " ", fontName: "Helvetica", fontSize: size)
                if !isLast, let space = shaped.glyphs.last { shaped.width -= space.advance / 1000 * size }
                guard shaped.width > 0, width > 0.25 else { continue }
                let stretch = width / shaped.width
                for position in shaped.glyphs.indices {
                    shaped.glyphs[position].x *= stretch
                    shaped.glyphs[position].advance *= stretch
                }
                text.add(shaped, x: left, baseline: baseline, fontSize: size)
            }
        }
        guard !text.isEmpty else { return }
        // Drawn fully transparent. Glyphs that draw nothing at all would be simpler, but
        // PDFKit leaves such glyphs out of the text it reads, and the usual "invisible"
        // text mode does not apply to fonts made of drawn glyphs.
        let state = PDFName("SheafHidden")
        let operators = "/\(state.rawValue) gs\nBT\n0 Tc 0 Tw 100 Tz 0 Ts 0 Tr\n" + text.operators + "ET\n"
        try rewritePage(at: index, interpretation, adding: PageAddition(
            operators: operators, fonts: text.fontResources(in: &self),
            graphicsStates: [state: ["Type": .name("ExtGState"), "ca": 0, "CA": 0]]
        ))
    }

    /// Whether a page has text a reader can select. A scanned page does not.
    public func hasText(onPageAt index: Int) throws -> Bool {
        try interpret(pageAt: index).glyphs.contains { ($0.text ?? "").contains { !$0.isWhitespace } }
    }
}
