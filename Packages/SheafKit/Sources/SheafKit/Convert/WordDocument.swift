import Foundation

/// A stretch of text with one look.
struct StyledRun: Equatable {
    var text: String
    var fontName: String
    var fontSize: Double
    var isBold: Bool
    var isItalic: Bool
    var color: PDFColor

    func hasSameLook(as other: StyledRun) -> Bool {
        fontName == other.fontName && abs(fontSize - other.fontSize) < 0.26 && isBold == other.isBold && isItalic == other.isItalic && color == other.color
    }
}

/// A paragraph taken from a page, with what a word processor needs to set it again.
struct StyledParagraph {
    var runs: [StyledRun]
    var alignment: TextBlock.Alignment
    /// From the page's left edge to the paragraph's body, and to its first line.
    var left: Double
    var firstLine: Double
    var top: Double
    var bottom: Double
    var leading: Double
}

extension TextBlock {
    /// The block as paragraphs of runs, each run a stretch of one font, size and color.
    var styledParagraphs: [StyledParagraph] {
        let starts = paragraphStarts
        let indents = indents
        var result: [StyledParagraph] = []
        var runs: [StyledRun] = []
        var top = 0.0, bottom = 0.0
        func flush() {
            // Spaces at the ends of a paragraph carry nothing.
            while runs.last?.text.allSatisfy({ $0 == " " }) == true { runs.removeLast() }
            guard !runs.isEmpty else { return }
            result.append(StyledParagraph(
                runs: runs, alignment: alignment, left: frame.x + indents.rest, firstLine: frame.x + indents.first,
                top: top, bottom: bottom, leading: leading
            ))
            runs = []
        }
        func append(_ text: String, like glyph: PageGlyph) {
            let run = StyledRun(text: text, fontName: glyph.fontName, fontSize: (glyph.fontSize * 2).rounded() / 2, isBold: glyph.isBold, isItalic: glyph.isItalic, color: glyph.color)
            if let last = runs.last, last.hasSameLook(as: run) {
                runs[runs.count - 1].text += text
            } else {
                runs.append(run)
            }
        }
        for (index, line) in lines.enumerated() {
            if starts[index] {
                flush()
                top = line.frame.y + line.frame.height
            } else if let last = lines[index - 1].glyphs.last, last.text != " " {
                // Lines of one paragraph run on, with a space where the line ended.
                append(" ", like: last)
            }
            bottom = line.frame.y
            for glyph in line.glyphs { append(glyph.text, like: glyph) }
        }
        flush()
        return result
    }
}

extension PDFEditor {
    /// A picture as an image file, when it is of a kind that can be handed on as it is
    /// or unpacked simply: JPEGs, and plain gray or color pictures with 8 bits a sample.
    func pictureFile(_ id: ObjectID) throws -> (data: Data, fileExtension: String)? {
        guard let stream = try object(id).streamValue else { return nil }
        let dictionary = stream.dictionary
        guard try value("ImageMask", in: dictionary).boolValue != true,
              let width = try value("Width", in: dictionary).intValue, width > 0,
              let height = try value("Height", in: dictionary).intValue, height > 0,
              let components = try components(ofColorSpace: dictionary["ColorSpace"] ?? .null), components == 1 || components == 3
        else { return nil }
        let filters = try StreamFilters.filters(of: dictionary, resolve: resolve).map(\.name)
        if filters == ["DCTDecode"] || filters == ["DCT"] { return (stream.data, "jpeg") }
        guard try value("BitsPerComponent", in: dictionary).intValue == 8, dictionary["Decode"] == nil,
              filters.allSatisfy({ !StreamFilters.imageFilters.contains($0) }), let samples = try? decodedData(of: stream),
              let png = ImageRecoder.png(samples: samples, width: width, height: height, components: components)
        else { return nil }
        return (png, "png")
    }

    /// The document as a Word file: its text in paragraphs with their fonts, sizes,
    /// colors, alignment and indents, its pictures, a page of the same size for each page.
    ///
    /// The result is for working with the words, not a picture of the pages. Text keeps
    /// its reading order from the top of each page down; columns, tables and exact
    /// positions are not carried over.
    ///
    /// - Parameter progress: Called with the fraction done. Return `false` to stop.
    public func wordDocument(title: String = "", progress: ((Double) -> Bool)? = nil) throws -> Data {
        let count = try pageCount()
        var body = ""
        var media: [(name: String, data: Data)] = []
        var mediaByObject: [ObjectID: Int] = [:]
        var relationships = ""
        var fontFamilies: [String: String] = [:]
        func twips(_ points: Double) -> Int { wholeNumber(points * 20) }
        func family(_ run: StyledRun) -> String {
            let key = "\(run.fontName)/\(run.isBold)/\(run.isItalic)"
            if let known = fontFamilies[key] { return known }
            let installed = FontMatcher.installedName(for: run.fontName, traits: FontMatcher.Traits(isBold: run.isBold, isItalic: run.isItalic))
            let name = FontMatcher.familyName(of: installed)
            fontFamilies[key] = name
            return name
        }

        for index in 0..<count {
            if let progress, !progress(Double(index) / Double(max(count, 1))) { throw CancellationError() }
            let content = try pageContent(at: index)
            let page = content.geometry.displaySize

            // Everything on the page from the top down: paragraphs and pictures.
            enum Piece {
                case paragraph(StyledParagraph)
                case picture(PageImage, relationship: Int)
            }
            var pieces: [(top: Double, left: Double, piece: Piece)] = []
            for block in content.blocks where !block.text.trimmingCharacters(in: .whitespaces).isEmpty {
                for paragraph in block.styledParagraphs { pieces.append((paragraph.top, paragraph.left, .paragraph(paragraph))) }
            }
            for image in content.images {
                guard let id = image.objectID, image.frame.width > 4, image.frame.height > 4 else { continue }
                // A picture that covers the page is a scan or a background; a document of words does not want it.
                if image.frame.width > page.width * 0.95, image.frame.height > page.height * 0.95, !content.blocks.isEmpty { continue }
                var number = mediaByObject[id]
                if number == nil, let file = try pictureFile(id) {
                    media.append(("image\(media.count + 1).\(file.fileExtension)", file.data))
                    number = media.count
                    mediaByObject[id] = number
                    relationships += "<Relationship Id=\"rIdImage\(media.count)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(media[media.count - 1].name)\"/>"
                }
                if let number { pieces.append((image.frame.y + image.frame.height, image.frame.x, .picture(image, relationship: number))) }
            }
            // Top to bottom; things on the same row from left to right.
            pieces.sort { a, b in abs(a.top - b.top) > 3 ? a.top > b.top : a.left < b.left }

            // Margins as the page has them, so indents come out where they were.
            let lefts = content.blocks.map(\.frame.x) + content.images.map(\.frame.x)
            let rights = content.blocks.map { $0.frame.x + $0.frame.width } + content.images.map { $0.frame.x + $0.frame.width }
            let tops = content.blocks.map { $0.frame.y + $0.frame.height } + content.images.map { $0.frame.y + $0.frame.height }
            let bottoms = content.blocks.map(\.frame.y) + content.images.map(\.frame.y)
            let marginLeft = min(max(lefts.min() ?? 72, 18), page.width / 3)
            let marginRight = min(max(page.width - (rights.max() ?? page.width - 72), 18), page.width / 3)
            let marginTop = min(max(page.height - (tops.max() ?? page.height - 72), 18), page.height / 3)
            let marginBottom = min(max(bottoms.min() ?? 72, 18), page.height / 3)

            var previousBottom = page.height - marginTop
            var pageBody = ""
            for (_, _, piece) in pieces {
                switch piece {
                case .paragraph(let paragraph):
                    let size = paragraph.runs.first?.fontSize ?? 12
                    // The gap above, less what the line's own height already leaves.
                    let before = max(previousBottom - paragraph.top - max(paragraph.leading - size, 0), 0)
                    previousBottom = min(paragraph.bottom, previousBottom)
                    let alignment = switch paragraph.alignment {
                    case .left: "left"
                    case .center: "center"
                    case .right: "right"
                    case .justified: "both"
                    }
                    let left = max(paragraph.left - marginLeft, 0)
                    let first = paragraph.firstLine - paragraph.left
                    var properties = "<w:spacing w:before=\"\(twips(min(before, 200)))\" w:after=\"0\" w:line=\"\(twips(max(paragraph.leading, size)))\" w:lineRule=\"atLeast\"/>"
                    if paragraph.alignment == .left || paragraph.alignment == .justified {
                        properties += "<w:ind w:left=\"\(twips(left))\"" + (first >= 0 ? " w:firstLine=\"\(twips(first))\"" : " w:hanging=\"\(twips(-first))\"") + "/>"
                    }
                    properties += "<w:jc w:val=\"\(alignment)\"/>"
                    var text = ""
                    for run in paragraph.runs {
                        let name = xmlEscaped(family(run))
                        var look = "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\" w:cs=\"\(name)\" w:eastAsia=\"\(name)\"/>"
                        if run.isBold { look += "<w:b/>" }
                        if run.isItalic { look += "<w:i/>" }
                        if run.color != .black {
                            look += String(format: "<w:color w:val=\"%02X%02X%02X\"/>", wholeNumber(run.color.red * 255), wholeNumber(run.color.green * 255), wholeNumber(run.color.blue * 255))
                        }
                        let halfPoints = max(wholeNumber(run.fontSize * 2), 2)
                        look += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
                        text += "<w:r><w:rPr>\(look)</w:rPr><w:t xml:space=\"preserve\">\(xmlEscaped(run.text))</w:t></w:r>"
                    }
                    pageBody += "<w:p><w:pPr>\(properties)</w:pPr>\(text)</w:p>"

                case .picture(let image, let relationship):
                    // English Metric Units: 12,700 to the point. Never wider than the text area.
                    let available = page.width - marginLeft - marginRight
                    let scale = min(1, available / image.frame.width)
                    let width = wholeNumber(image.frame.width * scale * 12_700), height = wholeNumber(image.frame.height * scale * 12_700)
                    let before = max(previousBottom - (image.frame.y + image.frame.height), 0)
                    previousBottom = min(image.frame.y, previousBottom)
                    let number = index * 1000 + relationship
                    pageBody += """
                    <w:p><w:pPr><w:spacing w:before="\(twips(min(before, 200)))" w:after="0"/><w:ind w:left="\(twips(max(image.frame.x - marginLeft, 0) * scale))"/></w:pPr><w:r><w:drawing>\
                    <wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(number)" name="Picture \(number)"/>\
                    <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
                    <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(number)" name="Picture \(number)"/><pic:cNvPicPr/></pic:nvPicPr>\
                    <pic:blipFill><a:blip r:embed="rIdImage\(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                    <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
                    </a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                    """
                }
            }

            let section = "<w:sectPr><w:pgSz w:w=\"\(twips(page.width))\" w:h=\"\(twips(page.height))\"\(page.width > page.height ? " w:orient=\"landscape\"" : "")/>"
                + "<w:pgMar w:top=\"\(twips(marginTop))\" w:right=\"\(twips(marginRight))\" w:bottom=\"\(twips(marginBottom))\" w:left=\"\(twips(marginLeft))\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/></w:sectPr>"
            if index + 1 < count {
                // A section ends inside the last paragraph of the page; the next starts a new page.
                body += pageBody + "<w:p><w:pPr>\(section)</w:pPr></w:p>"
            } else {
                body += pageBody + section
            }
        }
        if let progress, !progress(1) { throw CancellationError() }

        let namespaces = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var archive = ZipArchive()
        var types = "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        if media.contains(where: { $0.name.hasSuffix("jpeg") }) { types += "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>" }
        if media.contains(where: { $0.name.hasSuffix("png") }) { types += "<Default Extension=\"png\" ContentType=\"image/png\"/>" }
        archive.add("[Content_Types].xml", header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\(types)"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>")
        archive.add("_rels/.rels", header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>")
        archive.add("docProps/core.xml", header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
            + "<dc:title>\(xmlEscaped(title))</dc:title></cp:coreProperties>")
        archive.add("word/document.xml", header + "<w:document \(namespaces)><w:body>\(body)</w:body></w:document>")
        archive.add("word/styles.xml", header + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr>"
            + "<w:rFonts w:ascii=\"Helvetica\" w:hAnsi=\"Helvetica\" w:cs=\"Helvetica\"/><w:sz w:val=\"24\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style></w:styles>")
        archive.add("word/_rels/document.xml.rels", header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\(relationships)</Relationships>")
        for file in media { archive.add("word/media/\(file.name)", file.data, compresses: false) }
        return archive.data()
    }
}
