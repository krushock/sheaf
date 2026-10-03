import Foundation

/// The document information dictionary: title, author and so on.
public struct DocumentInfo: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: String?
    /// The app the document was first made in.
    public var creator: String?
    /// The software that produced the PDF.
    public var producer: String?
    public var creationDate: Date?
    public var modificationDate: Date?

    public init(
        title: String? = nil, author: String? = nil, subject: String? = nil, keywords: String? = nil,
        creator: String? = nil, producer: String? = nil, creationDate: Date? = nil, modificationDate: Date? = nil
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
        self.creator = creator
        self.producer = producer
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

extension ObjectSource {
    /// The document's title, author and so on. Read from the information dictionary, and
    /// for anything that leaves out, from the document's XMP metadata.
    public func info() throws -> DocumentInfo {
        let dictionary = try resolve(trailer["Info"] ?? .null).dictionaryValue ?? [:]
        func text(_ key: PDFName) throws -> String? {
            try resolve(dictionary[key] ?? .null).textValue
        }
        var info = DocumentInfo(
            title: try text("Title"), author: try text("Author"), subject: try text("Subject"),
            keywords: try text("Keywords"), creator: try text("Creator"), producer: try text("Producer"),
            creationDate: try text("CreationDate").flatMap(PDFDate.decode),
            modificationDate: try text("ModDate").flatMap(PDFDate.decode)
        )
        if let packet = try? metadataPacket() {
            let extra = XMP.read(packet)
            info.title = info.title ?? extra.title
            info.author = info.author ?? extra.author
            info.subject = info.subject ?? extra.subject
            info.keywords = info.keywords ?? extra.keywords
            info.creator = info.creator ?? extra.creator
            info.producer = info.producer ?? extra.producer
            info.creationDate = info.creationDate ?? extra.creationDate
            info.modificationDate = info.modificationDate ?? extra.modificationDate
        }
        return info
    }

    /// The document's XMP metadata as XML text, or `nil` when it has none.
    func metadataPacket() throws -> Data? {
        guard let stream = try value("Metadata", in: try catalog()).streamValue else { return nil }
        return try decodedData(of: stream)
    }
}

extension PDFEditor {
    /// Replaces the information dictionary's standard entries. Entries set to `nil` are
    /// removed; any other entries the dictionary holds are kept.
    ///
    /// When the document also carries XMP metadata, that is updated to say the same, with
    /// whatever else it holds left in place.
    public mutating func setInfo(_ info: DocumentInfo) throws {
        var dictionary = try resolve(trailer["Info"] ?? .null).dictionaryValue ?? [:]
        func set(_ key: PDFName, _ value: String?) {
            dictionary[key] = value.map { .string(PDFText.encode($0)) }
        }
        set("Title", info.title)
        set("Author", info.author)
        set("Subject", info.subject)
        set("Keywords", info.keywords)
        set("Creator", info.creator)
        set("Producer", info.producer)
        set("CreationDate", info.creationDate.map(PDFDate.encode))
        set("ModDate", info.modificationDate.map(PDFDate.encode))

        if let existing = trailer["Info"]?.referenceValue, !(try object(existing)).isNull {
            self.set(.dictionary(dictionary), for: existing)
        } else {
            setTrailer("Info", .reference(add(.dictionary(dictionary))))
        }

        let catalog = try catalog()
        if let reference = catalog["Metadata"]?.referenceValue, let stream = try object(reference).streamValue {
            let packet = XMP.updated(try? decodedData(of: stream), with: info)
            // Stored as plain text, as the format asks, so other tools can find it.
            var streamDictionary = stream.dictionary
            for key in ["Filter", "DecodeParms", "Length"] as [PDFName] { streamDictionary[key] = nil }
            streamDictionary["Type"] = .name("Metadata")
            streamDictionary["Subtype"] = .name("XML")
            self.set(.stream(PDFStream(dictionary: streamDictionary, data: packet)), for: reference)
        }
    }
}
