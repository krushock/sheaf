import Foundation

extension PDFEditor {
    /// Adds a page that shows a picture.
    ///
    /// The picture is turned upright according to its EXIF orientation and sized from its
    /// resolution, 72 pixels per inch when it does not say. JPEG files are stored as they
    /// are, without recompression.
    ///
    /// - Parameters:
    ///   - data: A JPEG, PNG, HEIC, TIFF, WebP or other picture file the system can read.
    ///   - index: Where the page goes. At the end when `nil`.
    @discardableResult
    public mutating func insertImagePage(_ data: Data, options: ImageDocumentOptions = ImageDocumentOptions(), at index: Int? = nil) throws -> ObjectID {
        let (picture, image) = try addImageObject(data)

        let upright = image.uprightSize
        let margin = max(options.margin, 0)
        var page: PageSize
        var scale = 1.0
        switch options.paper {
        case .fitImage:
            page = PageSize(width: upright.width + 2 * margin, height: upright.height + 2 * margin)
        case .fixed(let size):
            page = size
            if options.turnsPaperToFit, (upright.width > upright.height) != (page.width > page.height) {
                page = PageSize(width: size.height, height: size.width)
            }
            let room = PageSize(width: max(page.width - 2 * margin, 1), height: max(page.height - 2 * margin, 1))
            scale = min(room.width / upright.width, room.height / upright.height)
        }
        let placement = Affine.scale(image.storedSize.width, image.storedSize.height)
            .then(image.uprightTransform)
            .then(.scale(scale, scale))
            .then(.translation((page.width - upright.width * scale) / 2, (page.height - upright.height * scale) / 2))
        let content = add(.stream(PDFStream(data: Data("q \(placement.operands) cm /Im0 Do Q\n".utf8))))
        let id = add([
            "Type": .name("Page"), "MediaBox": PDFRectangle(x: 0, y: 0, width: page.width, height: page.height).object,
            "Resources": ["XObject": ["Im0": .reference(picture)]], "Contents": .reference(content),
        ])
        try insert([id], at: index ?? (try pageCount()))
        return id
    }
}

extension PDFEditor {
    /// Stores a picture file in the document as an image object, with its mask and color
    /// profile if it has them.
    /// - Parameter generatedBy: The tool that made the picture, when a generative model
    ///   did: the picture then carries metadata saying so, which survives the file being
    ///   saved again, since the picture is written once and only referred to after.
    mutating func addImageObject(_ data: Data, generatedBy tool: String? = nil) throws -> (id: ObjectID, image: PDFImage) {
        var image = try ImageReader.read(data)
        if let tool {
            let metadata = PDFStream(dictionary: ["Type": .name("Metadata"), "Subtype": .name("XML")], data: XMP.generatedImage(by: tool))
            image.stream.dictionary["Metadata"] = .reference(add(.stream(metadata)))
        }
        if let mask = image.mask { image.stream.dictionary["SMask"] = .reference(add(.stream(mask))) }
        if let profile = image.profile {
            let stream = PDFStream(
                dictionary: ["N": .integer(image.components), "Alternate": .name(image.components == 3 ? "DeviceRGB" : "DeviceGray"), "Filter": .name("FlateDecode")],
                data: Flate.deflate(profile)
            )
            image.stream.dictionary["ColorSpace"] = [.name("ICCBased"), .reference(add(.stream(stream)))]
        }
        return (add(.stream(image.stream)), image)
    }
}

extension PDFGenerator {
    /// A new document of empty pages.
    public static func blankDocument(pageSize: PageSize, pageCount: Int = 1) throws(SheafError) -> Data {
        MinimalPDF.data(pageBoxes: Array(repeating: PDFRectangle(x: 0, y: 0, width: pageSize.width, height: pageSize.height), count: max(pageCount, 1)))
    }

    /// A one-page document showing a picture at its natural size.
    public static func document(fromImageData data: Data) throws(SheafError) -> Data {
        try document(fromImages: [data])
    }

    /// A document with one page per picture, in the order given.
    public static func document(fromImages images: [Data], options: ImageDocumentOptions = ImageDocumentOptions()) throws(SheafError) -> Data {
        guard !images.isEmpty else { throw .unreadableImage }
        do {
            var editor = PDFEditor.empty()
            for image in images { try editor.insertImagePage(image, options: options) }
            return try editor.rewritten()
        } catch let error as SheafError {
            throw error
        } catch {
            throw .generationFailed
        }
    }
}
