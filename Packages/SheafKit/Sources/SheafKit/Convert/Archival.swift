import Foundation

/// Something done, or left undone, while making a document fit for archiving.
public enum ArchivalNote: Sendable, Equatable, Hashable {
    // Done.
    case embeddedFont(String)
    case addedColorProfile
    case addedMetadata
    case removedPassword
    case removedScripts(Int)
    case removedAttachments(Int)
    case madeAnnotationsPrintable(Int)
    case removedFormData
    case recompressedStreams(Int)

    // Left as they are, and not allowed.
    case fontNotEmbedded(String)
    case usesPrintingColors(pages: Int)
    case annotationsWithoutAppearance(Int)
    case unsupportedAnnotations(Int)
}

/// A document made over for archiving, with what was changed and what could not be.
public struct ArchivalResult: Sendable, Equatable {
    public var data: Data
    public var fixed: [ArchivalNote]
    public var remaining: [ArchivalNote]
}

extension PDFEditor {
    /// The document made over to the PDF/A-2b standard for long-term archiving, as far
    /// as this engine can take it.
    ///
    /// PDF/A asks that a file carry everything needed to show it the same way decades
    /// from now: every font inside it, a statement of what its colors mean, metadata
    /// that says what it is, and nothing that depends on the outside world or runs code.
    /// This adds what is missing, takes out what is forbidden, and lists what it could
    /// not put right. It does not prove conformance; a validator does that.
    public func archival() throws -> ArchivalResult {
        var editor = self
        var fixed: [ArchivalNote] = [], remaining: [ArchivalNote] = []

        if trailer["Encrypt"] != nil { fixed.append(.removedPassword) }

        // Scripts and other actions that do things.
        let forbiddenActions: Set<String> = ["JavaScript", "Launch", "Sound", "Movie", "ResetForm", "ImportData", "Hide", "SetOCGState", "Rendition", "Trans", "GoTo3DView", "SubmitForm"]
        var scripts = 0
        func isForbidden(_ action: PDFObject) -> Bool {
            // Looked up in the document as it came: asking the copy being changed while it
            // is being changed is not allowed, and actions are not among what changes.
            guard let dictionary = (try? self.resolve(action))?.dictionaryValue else { return false }
            return forbiddenActions.contains(dictionary["S"]?.nameValue?.text ?? "")
        }
        if let id = editor.catalogID {
            let catalog = try editor.catalog()
            var removed = 0
            if catalog["AA"] != nil { removed += 1 }
            if let open = catalog["OpenAction"], isForbidden(open) { removed += 1 }
            var names = try editor.value("Names", in: catalog).dictionaryValue
            var attachments = 0
            if names?["JavaScript"] != nil {
                names?["JavaScript"] = nil
                removed += 1
            }
            if let files = names?["EmbeddedFiles"] {
                attachments = Self.countLeaves(of: files, in: editor)
                names?["EmbeddedFiles"] = nil
            }
            if removed > 0 || attachments > 0 {
                try editor.update(id) { catalog in
                    catalog["AA"] = nil
                    if let open = catalog["OpenAction"], isForbidden(open) { catalog["OpenAction"] = nil }
                    if let names { catalog["Names"] = names.isEmpty ? nil : .dictionary(names) }
                }
            }
            scripts += removed
            if attachments > 0 { fixed.append(.removedAttachments(attachments)) }
        }

        // The form: no data in a second format, and nothing left for the reader to draw.
        if let form = try editor.acroForm(), form.dictionary["XFA"] != nil || form.dictionary["NeedAppearances"] != nil {
            var dictionary = form.dictionary
            dictionary["XFA"] = nil
            dictionary["NeedAppearances"] = nil
            if let id = form.id {
                editor.set(.dictionary(dictionary), for: id)
            } else if let catalog = editor.catalogID {
                try editor.update(catalog) { $0["AcroForm"] = .dictionary(dictionary) }
            }
            fixed.append(.removedFormData)
        }

        // Pages and their annotations.
        var printable = 0, bare = 0, unsupported = 0
        let unsupportedKinds: Set<String> = ["3D", "Sound", "Screen", "Movie", "FileAttachment"]
        for page in try editor.pageIDs() {
            if try editor.object(page).dictionaryValue?["AA"] != nil {
                try editor.update(page) { $0["AA"] = nil }
                scripts += 1
            }
            for entry in try editor.value("Annots", in: try editor.object(page).dictionaryValue ?? [:]).arrayValue ?? [] {
                guard let id = entry.referenceValue, let annotation = try editor.object(id).dictionaryValue else { continue }
                let kind = annotation["Subtype"]?.nameValue?.text ?? ""
                if unsupportedKinds.contains(kind) { unsupported += 1 }
                let flags = try editor.value("F", in: annotation).intValue ?? 0
                // Printed, and neither hidden nor shown only on screen.
                let wanted = (flags | 4) & ~(1 | 2 | 32 | 256)
                let hasScript = annotation["AA"] != nil || annotation["A"].map(isForbidden) == true
                if wanted != flags || hasScript {
                    try editor.update(id) { dictionary in
                        dictionary["F"] = .integer(wanted)
                        dictionary["AA"] = nil
                        if let action = dictionary["A"], isForbidden(action) { dictionary["A"] = nil }
                    }
                    if wanted != flags { printable += 1 }
                    if hasScript { scripts += 1 }
                }
                let rect = try editor.value("Rect", in: annotation).arrayValue?.compactMap(\.doubleValue) ?? []
                let isEmpty = rect.count == 4 && (rect[0] == rect[2] || rect[1] == rect[3])
                if kind != "Popup", kind != "Link", !isEmpty, try editor.value("AP", in: annotation).dictionaryValue?["N"] == nil { bare += 1 }
            }
        }
        if scripts > 0 { fixed.append(.removedScripts(scripts)) }
        if printable > 0 { fixed.append(.madeAnnotationsPrintable(printable)) }
        if bare > 0 { remaining.append(.annotationsWithoutAppearance(bare)) }
        if unsupported > 0 { remaining.append(.unsupportedAnnotations(unsupported)) }

        // Every object: fonts to embed, old compression to replace, pictures not to smooth.
        var recompressed = 0
        var embedded: Set<String> = [], missing: Set<String> = []
        for number in 1..<editor.nextObjectNumber {
            let id = ObjectID(number)
            guard let object = try? editor.object(id) else { continue }
            if case .stream(let stream) = object {
                let filters = (try? StreamFilters.filters(of: stream.dictionary, resolve: editor.resolve).map(\.name.text)) ?? []
                if filters.contains("LZWDecode") || filters.contains("LZW"), let data = try? editor.decodedData(of: stream), filters.allSatisfy({ !["DCTDecode", "JPXDecode", "CCITTFaxDecode", "JBIG2Decode"].contains($0) }) {
                    var dictionary = stream.dictionary
                    dictionary["Filter"] = .name("FlateDecode")
                    dictionary["DecodeParms"] = nil
                    editor.set(.stream(PDFStream(dictionary: dictionary, data: Flate.deflate(data))), for: id)
                    recompressed += 1
                }
                if stream.dictionary["Subtype"]?.nameValue == "Image", (try? editor.value("Interpolate", in: stream.dictionary).boolValue) == true {
                    try editor.update(id) { $0["Interpolate"] = nil }
                }
                continue
            }
            guard let dictionary = object.dictionaryValue, dictionary["Type"]?.nameValue == "Font" else { continue }
            let subtype = dictionary["Subtype"]?.nameValue?.text ?? ""
            let name = (try? editor.value("BaseFont", in: dictionary).nameValue?.text) ?? ""
            let plain = name.split(separator: "+").last.map(String.init) ?? name
            func hasProgram(_ descriptor: PDFDictionary?) -> Bool {
                guard let descriptor else { return false }
                return ["FontFile", "FontFile2", "FontFile3"].contains { descriptor[PDFName($0)] != nil }
            }
            switch subtype {
            case "Type3":
                continue
            case "Type0":
                let descendant = try editor.resolve(try editor.value("DescendantFonts", in: dictionary).arrayValue?.first ?? .null).dictionaryValue
                if !hasProgram(try descendant.flatMap { try editor.value("FontDescriptor", in: $0).dictionaryValue }) { missing.insert(plain) }
            case "Type1", "TrueType", "MMType1":
                if hasProgram(try editor.value("FontDescriptor", in: dictionary).dictionaryValue) { continue }
                if try editor.embedInstalledFont(in: id, dictionary) {
                    embedded.insert(plain)
                } else {
                    missing.insert(plain)
                }
            default:
                continue
            }
        }
        if recompressed > 0 { fixed.append(.recompressedStreams(recompressed)) }
        for name in embedded.sorted() { fixed.append(.embeddedFont(name)) }
        for name in missing.sorted() { remaining.append(.fontNotEmbedded(name)) }

        // What the colors mean. Colors given as printing inks would need a press profile.
        var inkPages = 0
        for index in 0..<(try editor.pageCount()) {
            guard let interpretation = try? editor.interpret(pageAt: index) else { continue }
            var usesInks = false
            for stream in interpretation.streams {
                if stream.content.operations.contains(where: { operation in
                    operation.name == "k" || operation.name == "K"
                        || ((operation.name == "cs" || operation.name == "CS") && operation.operands.first?.nameValue == "DeviceCMYK")
                }) {
                    usesInks = true
                    break
                }
            }
            if !usesInks {
                usesInks = interpretation.images.contains { image in
                    guard let id = image.object, let dictionary = try? editor.object(id).streamValue?.dictionary else { return false }
                    return (try? editor.resolve(dictionary["ColorSpace"] ?? .null).nameValue) == "DeviceCMYK"
                }
            }
            if usesInks { inkPages += 1 }
        }
        if inkPages > 0 { remaining.append(.usesPrintingColors(pages: inkPages)) }

        if let catalogID = editor.catalogID {
            let catalog = try editor.catalog()
            let intents = try editor.value("OutputIntents", in: catalog).arrayValue ?? []
            let hasIntent = try intents.contains { try editor.resolve($0).dictionaryValue?["S"]?.nameValue == "GTS_PDFA1" }
            if !hasIntent, let profile = FontProgram.sRGBProfile {
                let stream = editor.add(.stream(PDFStream(dictionary: ["N": 3, "Filter": .name("FlateDecode")], data: Flate.deflate(profile))))
                let intent: PDFDictionary = [
                    "Type": .name("OutputIntent"), "S": .name("GTS_PDFA1"),
                    "OutputConditionIdentifier": .string(Data("sRGB IEC61966-2.1".utf8)), "Info": .string(Data("sRGB IEC61966-2.1".utf8)),
                    "RegistryName": .string(Data("http://www.color.org".utf8)), "DestOutputProfile": .reference(stream),
                ]
                try editor.update(catalogID) { $0["OutputIntents"] = .array(intents + [.dictionary(intent)]) }
                fixed.append(.addedColorProfile)
            }

            // Metadata that says the same as the document's information, and names the standard.
            var info = try editor.info()
            if info.producer == nil { info.producer = "Sheaf" }
            if info.creationDate == nil { info.creationDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }
            if info.modificationDate == nil { info.modificationDate = info.creationDate }
            try editor.setInfo(info)
            let existing = try editor.metadataPacket()
            let packet = XMP.updated(existing, with: info, archival: (2, "B"))
            let stream = PDFStream(dictionary: ["Type": .name("Metadata"), "Subtype": .name("XML")], data: packet)
            if let reference = try editor.catalog()["Metadata"]?.referenceValue {
                editor.set(.stream(stream), for: reference)
            } else {
                let reference = editor.add(.stream(stream))
                try editor.update(catalogID) { $0["Metadata"] = .reference(reference) }
            }
            fixed.append(.addedMetadata)
        }

        return ArchivalResult(data: try editor.rewritten(protection: .none), fixed: fixed, remaining: remaining)
    }

    /// How many entries a name tree holds.
    private static func countLeaves(of tree: PDFObject, in editor: PDFEditor, depth: Int = 0) -> Int {
        guard depth < 16, let node = (try? editor.resolve(tree))?.dictionaryValue else { return 0 }
        var count = ((try? editor.value("Names", in: node).arrayValue)?.count ?? 0) / 2
        for kid in (try? editor.value("Kids", in: node).arrayValue) ?? [] { count += countLeaves(of: kid, in: editor, depth: depth + 1) }
        return count
    }

    /// Puts the installed font inside the document for a font that only names it.
    ///
    /// Only done when the very font is installed, since its glyphs then have the widths
    /// the page was set with, and when its characters are numbered in one of the two
    /// standard ways, which a TrueType font inside a PDF has to be.
    ///
    /// - Returns: Whether the font is now in the document.
    private mutating func embedInstalledFont(in id: ObjectID, _ dictionary: PDFDictionary) throws -> Bool {
        let name = try value("BaseFont", in: dictionary).nameValue?.text ?? ""
        guard let installed = FontMatcher.sameInstalledFont(as: name), let tables = FontProgram.trueTypeTables(fontName: installed),
              tables["cmap"] != nil, let font = try? PageFont(dictionary: dictionary, source: self)
        else { return false }

        // The numbering: one of the two standard ones, with any changes the font lists.
        let encoding = try resolve(dictionary["Encoding"] ?? .null)
        let baseName = encoding.nameValue ?? encoding.dictionaryValue?["BaseEncoding"]?.nameValue
        var newEncoding: PDFObject
        switch baseName?.text {
        case "WinAnsiEncoding", "MacRomanEncoding":
            newEncoding = dictionary["Encoding"] ?? .name("WinAnsiEncoding")
        case nil, "StandardEncoding":
            // The same characters, said as changes to the Windows numbering.
            var changed: [Int: String] = [:]
            for code in 0..<256 where !Encodings.standard[code].isEmpty && Encodings.standard[code] != Encodings.winAnsi[code] {
                if let scalar = Encodings.standard[code].unicodeScalars.first { changed[code] = String(format: "uni%04X", scalar.value) }
            }
            var code = 0
            for entry in try encoding.dictionaryValue.map({ try value("Differences", in: $0) })?.arrayValue ?? [] {
                if let start = entry.intValue {
                    code = start
                } else if let glyph = entry.nameValue {
                    if (0..<256).contains(code) { changed[code] = glyph.text }
                    code += 1
                }
            }
            var differences: [PDFObject] = []
            var last = -2
            for code in changed.keys.sorted() {
                if code != last + 1 { differences.append(.integer(code)) }
                differences.append(.name(PDFName(changed[code] ?? ".notdef")))
                last = code
            }
            newEncoding = differences.isEmpty ? .name("WinAnsiEncoding") : ["Type": .name("Encoding"), "BaseEncoding": .name("WinAnsiEncoding"), "Differences": .array(differences)]
        default:
            return false
        }

        // The glyphs the font's codes can draw.
        var glyphs: Set<Int> = []
        for code in 0..<256 {
            guard let text = font.text(of: code), !text.isEmpty else { continue }
            for glyph in TextOutliner.shape(text, fontName: installed, fontSize: 12).glyphs where glyph.fontName == installed {
                glyphs.insert(Int(glyph.index))
            }
        }
        let source = TrueTypeTables(tables: tables)
        guard let program = source.subset(keeping: glyphs, extraTables: ["cmap", "name", "OS/2", "post"]) else { return false }

        var tag = ""
        var seed = id.number &* 7919 &+ glyphs.count
        for _ in 0..<6 {
            tag.append(Character(UnicodeScalar(UInt8(65 + abs(seed) % 26))))
            seed /= 26
        }
        let fontName = PDFName("\(tag)+\(installed)")
        let scale = 1000 / Double(source.unitsPerEm)
        func units(_ value: Int) -> PDFObject { .integer(wholeNumber(Double(value) * scale)) }
        let file = add(.stream(PDFStream(dictionary: ["Filter": .name("FlateDecode"), "Length1": .integer(program.count)], data: Flate.deflate(program))))
        let bounds = source.bounds
        var flags = 32
        if source.isFixedPitch { flags |= 1 }
        if source.italicAngle != 0 { flags |= 64 }
        let descriptor = add([
            "Type": .name("FontDescriptor"), "FontName": .name(fontName), "Flags": .integer(flags),
            "FontBBox": [units(bounds.minX), units(bounds.minY), units(bounds.maxX), units(bounds.maxY)],
            "ItalicAngle": .real(source.italicAngle), "Ascent": units(source.ascent), "Descent": units(source.descent),
            "CapHeight": units(source.capHeight ?? source.ascent), "StemV": 80, "FontFile2": .reference(file),
        ])

        var updated = dictionary
        updated["Subtype"] = .name("TrueType")
        updated["BaseFont"] = .name(fontName)
        updated["Encoding"] = newEncoding
        updated["FontDescriptor"] = .reference(descriptor)
        // Widths for every code, as the font program has them.
        if try value("Widths", in: dictionary).arrayValue == nil {
            updated["FirstChar"] = 32
            updated["LastChar"] = 255
            updated["Widths"] = .array((32...255).map { .integer(wholeNumber(font.width(of: $0))) })
        }
        set(.dictionary(updated), for: id)
        return true
    }
}
