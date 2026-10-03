import Foundation

extension Annotation {
    /// How the annotation looks, or `nil` for kinds that show nothing.
    public func appearance() -> Appearance? {
        AppearanceBuilder.make(for: self)
    }
}

extension PDFEditor {
    private func pageID(at index: Int) throws -> ObjectID {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        return pages[index]
    }

    public func annotations(onPageAt index: Int) throws -> [Annotation] {
        try annotations(forPage: try pageID(at: index))
    }

    private func annotationReferences(of page: ObjectID) throws -> [PDFObject] {
        try value("Annots", in: try object(page).dictionaryValue ?? [:]).arrayValue ?? []
    }

    /// Puts a new annotation on a page, on top of the ones already there.
    @discardableResult
    public mutating func addAnnotation(_ annotation: Annotation, toPageAt index: Int) throws -> ObjectID {
        let page = try pageID(at: index)
        let id = reserve()
        let dictionary = try makeDictionary(for: annotation, from: [:], page: page)
        set(.dictionary(dictionary), for: id)
        let references = try annotationReferences(of: page) + [.reference(id)]
        try update(page) { $0["Annots"] = .array(references) }
        return id
    }

    /// Saves changes to an annotation that is already in the document. Anything about it
    /// that this engine does not model is kept.
    public mutating func updateAnnotation(_ annotation: Annotation, onPageAt index: Int) throws {
        let page = try pageID(at: index)
        guard let id = annotation.objectID, let existing = try object(id).dictionaryValue else {
            throw SheafError.malformed("the annotation is not part of the document")
        }
        set(.dictionary(try makeDictionary(for: annotation, from: existing, page: page)), for: id)
    }

    /// Takes an annotation off a page, along with its pop-up window and any replies to it.
    public mutating func removeAnnotation(_ id: ObjectID, fromPageAt index: Int) throws {
        let page = try pageID(at: index)
        let references = try annotationReferences(of: page)
        let doomed = try dependents(of: [id], among: references, includingReplies: true)
        let remaining = references.filter { $0.referenceValue.map { !doomed.contains($0) } ?? true }
        try update(page) { $0["Annots"] = remaining.isEmpty ? nil : .array(remaining) }
    }

    /// The annotations plus what cannot exist without them: their pop-up windows and,
    /// when asked, the replies to them.
    private func dependents(of ids: Set<ObjectID>, among references: [PDFObject], includingReplies: Bool) throws -> Set<ObjectID> {
        var result = ids
        // Replies can have replies, so keep looking until nothing new turns up.
        var grew = true
        while grew {
            grew = false
            for reference in references {
                guard let candidate = reference.referenceValue, !result.contains(candidate),
                      let dictionary = try object(candidate).dictionaryValue
                else { continue }
                let isPopupOfOne = dictionary["Subtype"]?.nameValue == "Popup"
                    && (dictionary["Parent"]?.referenceValue).map(result.contains) == true
                let isReplyToOne = includingReplies && (dictionary["IRT"]?.referenceValue).map(result.contains) == true
                if isPopupOfOne || isReplyToOne {
                    result.insert(candidate)
                    grew = true
                }
            }
        }
        for id in ids {
            if let popup = try object(id).dictionaryValue?["Popup"]?.referenceValue { result.insert(popup) }
        }
        // Some writers leave pop-ups pointing at a parent that is not on the page at all.
        // Once the page's list is being rewritten anyway, those go too.
        let present = Set(references.compactMap(\.referenceValue)).subtracting(result)
        for reference in references {
            guard let candidate = reference.referenceValue, !result.contains(candidate),
                  let dictionary = try object(candidate).dictionaryValue, dictionary["Subtype"]?.nameValue == "Popup",
                  let parent = dictionary["Parent"]?.referenceValue, !present.contains(parent)
            else { continue }
            result.insert(candidate)
        }
        return result
    }

    // MARK: Dictionaries

    private mutating func makeDictionary(for annotation: Annotation, from existing: PDFDictionary, page: ObjectID) throws -> PDFDictionary {
        var dictionary = existing
        dictionary["Type"] = .name("Annot")
        dictionary["P"] = .reference(page)
        func text(_ value: String?) -> PDFObject? {
            guard let value, !value.isEmpty else { return nil }
            return .string(PDFText.encode(value))
        }
        dictionary["Contents"] = text(annotation.contents)
        dictionary["T"] = text(annotation.author)
        dictionary["M"] = text(annotation.modified.map(PDFDate.encode))
        dictionary["IRT"] = annotation.replyTo.map(PDFObject.reference)
        if annotation.replyTo != nil { dictionary["RT"] = .name("R") }

        guard annotation.kind != .other else {
            dictionary["Rect"] = annotation.rect.object
            return dictionary
        }
        dictionary["Subtype"] = .name(annotation.subtype)
        dictionary["Rect"] = AppearanceBuilder.bounds(for: annotation).object
        // Print with the page; a note's icon also keeps its size when the page is zoomed or turned.
        dictionary["F"] = annotation.kind == .note ? 28 : 4
        dictionary["CA"] = annotation.opacity < 1 ? .real(annotation.opacity) : nil

        // A text box's own color entry is its background; its text color is in the style string.
        let isTextBox = annotation.kind == .freeText
        dictionary["C"] = (isTextBox ? annotation.fillColor : annotation.color)?.object
        dictionary["IC"] = [.square, .circle, .line].contains(annotation.kind) ? annotation.fillColor?.object : nil

        switch annotation.kind {
        case .square, .circle, .line, .ink:
            dictionary["BS"] = ["W": .real(annotation.lineWidth)]
        case .freeText:
            dictionary["BS"] = ["W": 0]
            let color = annotation.color ?? .black
            let style = "\(Serializer.format(color.red)) \(Serializer.format(color.green)) \(Serializer.format(color.blue)) rg /Helv \(Serializer.format(annotation.fontSize)) Tf"
            dictionary["DA"] = .string(Data(style.utf8))
            dictionary["Q"] = .integer(annotation.alignment.rawValue)
            // The standard style string can only name a built-in font, so the real one goes here.
            dictionary["SheafFont"] = .string(PDFText.encode(annotation.fontName))
        case .link:
            dictionary["Border"] = [0, 0, 0]
            dictionary["H"] = .name("I")
            dictionary["A"] = nil
            dictionary["Dest"] = nil
            switch annotation.link {
            case .url(let url):
                dictionary["A"] = ["S": .name("URI"), "URI": .string(Data(url.utf8))]
            case .page(let index):
                let pages = try pageIDs()
                guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
                dictionary["Dest"] = [.reference(pages[index]), .name("Fit")]
            case nil:
                break
            }
        default:
            break
        }

        dictionary["QuadPoints"] = annotation.quads.isEmpty ? nil : .array(annotation.quads.flatMap { quad -> [PDFObject] in
            // Top left, top right, bottom left, bottom right: the order readers expect in practice.
            let (left, right, bottom, top) = (quad.x, quad.x + quad.width, quad.y, quad.y + quad.height)
            return [left, top, right, top, left, bottom, right, bottom].map { .real($0) }
        })
        dictionary["InkList"] = annotation.kind == .ink
            ? .array(annotation.paths.map { .array($0.flatMap { [.real($0.x), .real($0.y)] }) }) : nil
        if annotation.kind == .line, let start = annotation.lineStart, let end = annotation.lineEnd {
            dictionary["L"] = [.real(start.x), .real(start.y), .real(end.x), .real(end.y)]
            func name(_ ending: Annotation.LineEnding) -> PDFObject {
                .name(ending == .openArrow ? "OpenArrow" : ending == .closedArrow ? "ClosedArrow" : "None")
            }
            dictionary["LE"] = [name(annotation.startEnding), name(annotation.endEnding)]
        }

        if let appearance = annotation.appearance() {
            dictionary["AP"] = ["N": .reference(addFormXObject(for: appearance))]
        } else if !(annotation.kind == .stamp && annotation.stamp == nil) {
            // A stamp read from a file keeps the look it came with. Everything else that
            // draws nothing must not keep a stale picture of its old self.
            dictionary["AP"] = nil
        }
        return dictionary
    }

    private mutating func addFormXObject(for appearance: Appearance) -> ObjectID {
        var resources: PDFDictionary = [:]
        if !appearance.graphicsStates.isEmpty {
            resources["ExtGState"] = .dictionary(appearance.graphicsStates.mapValues(PDFObject.dictionary))
        }
        var xObjects: PDFDictionary = [:]
        for name in appearance.images.keys.sorted() {
            var (image, mask) = Appearance.imageObjects(for: appearance.images[name]!)
            if let mask { image.dictionary["SMask"] = .reference(add(.stream(mask))) }
            xObjects[name] = .reference(add(.stream(image)))
        }
        if !xObjects.isEmpty { resources["XObject"] = .dictionary(xObjects) }
        return add(.stream(PDFStream(
            dictionary: [
                "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": appearance.bounds.object,
                "Resources": .dictionary(resources), "Filter": .name("FlateDecode"),
            ],
            data: Flate.deflate(appearance.content)
        )))
    }

    // MARK: Stored appearances

    /// A one-page PDF showing an annotation exactly as the document stores it, with the
    /// page the size of the annotation's frame. `nil` when the annotation has no stored look.
    ///
    /// This is how an app can draw annotations whose look cannot be rebuilt from a
    /// description, such as a signature that was placed earlier.
    public func storedAppearancePreview(of id: ObjectID) throws -> Data? {
        guard let dictionary = try object(id).dictionaryValue, let form = try normalAppearance(of: dictionary),
              let rect = PDFRectangle(try value("Rect", in: dictionary)), rect.width > 0, rect.height > 0,
              let placement = try placement(ofForm: form, in: PDFRectangle(x: 0, y: 0, width: rect.width, height: rect.height))
        else { return nil }

        var target = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: rect.width, height: rect.height)])))
        var copier = ObjectCopier(source: self, sourcePages: Set(try pageIDs()))
        let copied = try copier.copy(.reference(form), into: &target)
        try copier.finish(into: &target)
        let content = target.add(.stream(PDFStream(data: Data("q \(placement) cm /Fm0 Do Q".utf8))))
        let page = try target.pageIDs()[0]
        try target.update(page) { dictionary in
            dictionary["Resources"] = ["XObject": ["Fm0": copied]]
            dictionary["Contents"] = .reference(content)
        }
        return try target.rewritten()
    }

    /// A one-page PDF holding a single annotation, on an empty page shaped like the page it
    /// is on. `nil` when the annotation is not an object of its own.
    ///
    /// This is how an app using PDFKit can show an annotation exactly as a reader will see
    /// it once the document is saved: PDFKit reads the annotation from these bytes.
    public func annotationDocument(for id: ObjectID, onPageAt index: Int) throws -> Data? {
        let pages = try pageIDs()
        guard pages.indices.contains(index), var dictionary = try object(id).dictionaryValue else { return nil }
        let page = pages[index]
        let media = try pageBox(at: index, cropped: false)
        var target = PDFEditor(try PDFFile(data: MinimalPDF.data(version: base.version, pageBoxes: [media])))
        let newPage = try target.pageIDs()[0]

        // A form widget takes what it inherits from its field with it, so it is complete alone.
        if dictionary["Subtype"]?.nameValue == "Widget" {
            var names: [String] = []
            var current: ObjectID? = id
            var steps = 0
            while let node = current, let fields = try object(node).dictionaryValue, steps < 32 {
                for key in ["FT", "Ff", "V", "DV", "DA", "Q", "MaxLen", "Opt"] as [PDFName] where dictionary[key] == nil {
                    dictionary[key] = fields[key]
                }
                if let name = try value("T", in: fields).textValue { names.insert(name, at: 0) }
                current = fields["Parent"]?.referenceValue
                steps += 1
            }
            dictionary["T"] = names.isEmpty ? nil : .string(PDFText.encode(names.joined(separator: ".")))
            dictionary["Parent"] = nil
            dictionary["Kids"] = nil
        }
        // Replies and pop-up windows point at annotations that stay behind.
        dictionary["IRT"] = nil
        dictionary["Popup"] = nil

        var copier = ObjectCopier(source: self, sourcePages: Set(pages))
        copier.mapping[page] = newPage
        let copied = try copier.copy(.dictionary(dictionary), into: &target)
        try copier.finish(into: &target)
        let annotation = target.add(copied)
        if dictionary["Subtype"]?.nameValue == "Widget", let catalog = target.catalogID {
            // A form of its own, so PDFKit treats the widget as it does those in a whole document.
            var form: PDFDictionary = ["Fields": [.reference(annotation)]]
            if let source = try acroForm()?.dictionary {
                for key in ["DA", "DR", "NeedAppearances"] as [PDFName] {
                    if let entry = source[key] { form[key] = try copier.copy(entry, into: &target) }
                }
                try copier.finish(into: &target)
            }
            try target.update(catalog) { $0["AcroForm"] = .dictionary(form) }
        }
        let crop = try pageBox(at: index), rotation = try pageRotation(at: index)
        try target.update(newPage) { dictionary in
            dictionary["Annots"] = [.reference(annotation)]
            dictionary["CropBox"] = crop == media ? nil : crop.object
            dictionary["Rotate"] = rotation == 0 ? nil : .integer(rotation)
        }
        return try target.rewritten()
    }

    /// The matrix, as text, that stretches a form's box onto a rectangle, the way a viewer
    /// places an annotation's appearance in its frame.
    private func placement(ofForm form: ObjectID, in rect: PDFRectangle) throws -> String? {
        guard let stream = try object(form).streamValue,
              let box = PDFRectangle(try value("BBox", in: stream.dictionary)), box.width > 0, box.height > 0
        else { return nil }
        let matrix = try value("Matrix", in: stream.dictionary).arrayValue?.compactMap(\.doubleValue) ?? [1, 0, 0, 1, 0, 0]
        let m = matrix.count == 6 ? matrix : [1, 0, 0, 1, 0, 0]
        let corners = [(box.x, box.y), (box.x + box.width, box.y), (box.x, box.y + box.height), (box.x + box.width, box.y + box.height)]
            .map { PDFPoint(x: m[0] * $0.0 + m[2] * $0.1 + m[4], y: m[1] * $0.0 + m[3] * $0.1 + m[5]) }
        guard let placed = PDFRectangle(enclosing: corners), placed.width > 0, placed.height > 0 else { return nil }
        let scaleX = rect.width / placed.width, scaleY = rect.height / placed.height
        return [scaleX, 0, 0, scaleY, rect.x - placed.x * scaleX, rect.y - placed.y * scaleY].map(Serializer.format).joined(separator: " ")
    }

    // MARK: Flattening

    /// Makes annotations part of the page itself, so they can no longer be moved or removed.
    /// Links and form fields are left alone.
    ///
    /// - Parameter ids: Which annotations to flatten. All that can be, when `nil`.
    /// - Returns: How many were flattened.
    @discardableResult
    public mutating func flattenAnnotations(onPageAt index: Int, only ids: Set<ObjectID>? = nil) throws -> Int {
        try flattenAnnotations(onPageAt: index, only: ids, includingWidgets: false)
    }

    /// - Parameter includingWidgets: Also flattens form widgets, which are otherwise left alone.
    mutating func flattenAnnotations(onPageAt index: Int, only ids: Set<ObjectID>?, includingWidgets: Bool) throws -> Int {
        let page = try pageID(at: index)
        guard let pageDictionary = try object(page).dictionaryValue else { throw SheafError.malformed("page is not a dictionary") }
        let references = try annotationReferences(of: page)
        let models = try annotations(forPage: page)

        var resources = try inherited("Resources", forPage: page).map(resolve)?.dictionaryValue ?? [:]
        var xObjects = try value("XObject", in: resources).dictionaryValue ?? [:]
        var drawing = Data()
        var flattened: Set<ObjectID> = []

        for (reference, model) in zip(references, models) {
            guard let id = reference.referenceValue, ids?.contains(id) ?? true,
                  ![.link, .other].contains(model.kind) || model.subtype == "FileAttachment" || (includingWidgets && model.subtype == "Widget"),
                  let dictionary = try object(id).dictionaryValue
            else { continue }
            // Hidden annotations are not drawn, so there is nothing to make permanent.
            if (dictionary["F"]?.intValue ?? 0) & 2 != 0 { continue }

            var form = try normalAppearance(of: dictionary)
            if form == nil, let appearance = model.appearance() { form = addFormXObject(for: appearance) }
            guard let form, let rect = PDFRectangle(try value("Rect", in: dictionary)),
                  let placement = try placement(ofForm: form, in: rect)
            else { continue }

            var name = PDFName("SheafFm\(xObjects.count + 1)")
            var suffix = xObjects.count + 1
            while xObjects[name] != nil {
                suffix += 1
                name = PDFName("SheafFm\(suffix)")
            }
            xObjects[name] = .reference(form)
            drawing.append(contentsOf: "q \(placement) cm /\(name.rawValue) Do Q\n".utf8)
            flattened.insert(id)
        }
        guard !drawing.isEmpty else { return 0 }
        let removed = try dependents(of: flattened, among: references, includingReplies: false)

        // The page's own drawing is wrapped so that whatever state it leaves behind
        // cannot affect what is drawn after it.
        let opening = add(.stream(PDFStream(data: Data("q\n".utf8))))
        let closing = add(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode")], data: Flate.deflate(Data("\nQ\n".utf8) + drawing))))
        let original = try value("Contents", in: pageDictionary)
        let parts: [PDFObject] = original.arrayValue ?? (pageDictionary["Contents"].map { [$0] } ?? [])
        resources["XObject"] = .dictionary(xObjects)
        let remaining = references.filter { $0.referenceValue.map { !removed.contains($0) } ?? true }
        try update(page) { dictionary in
            dictionary["Contents"] = .array([.reference(opening)] + parts + [.reference(closing)])
            // A copy of the resources for this page alone; other pages may share the original.
            dictionary["Resources"] = .dictionary(resources)
            dictionary["Annots"] = remaining.isEmpty ? nil : .array(remaining)
        }
        return flattened.count
    }

    /// The form object that draws an annotation in its normal state.
    private func normalAppearance(of annotation: PDFDictionary) throws -> ObjectID? {
        guard let appearances = try value("AP", in: annotation).dictionaryValue, let normal = appearances["N"] else { return nil }
        if try resolve(normal).streamValue != nil { return normal.referenceValue }
        // Several states, such as a checkbox's on and off: use the current one.
        guard let states = try resolve(normal).dictionaryValue, let state = annotation["AS"]?.nameValue else { return nil }
        return states[state]?.referenceValue
    }
}
