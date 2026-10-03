import Foundation

/// The XML form of a document's title, author and dates, which newer PDFs carry next to,
/// or instead of, the information dictionary.
enum XMP {
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let dc = "http://purl.org/dc/elements/1.1/"
    private static let pdf = "http://ns.adobe.com/pdf/1.3/"
    private static let xmp = "http://ns.adobe.com/xap/1.0/"

    private enum Shape: Sendable { case plain, alternatives, list }

    /// The properties that mirror the information dictionary.
    private static let properties: [(prefix: String, uri: String, name: String, shape: Shape, value: @Sendable (DocumentInfo) -> String?)] = [
        ("dc", dc, "title", .alternatives, { $0.title }),
        ("dc", dc, "creator", .list, { $0.author }),
        ("dc", dc, "description", .alternatives, { $0.subject }),
        ("pdf", pdf, "Keywords", .plain, { $0.keywords }),
        ("pdf", pdf, "Producer", .plain, { $0.producer }),
        ("xmp", xmp, "CreatorTool", .plain, { $0.creator }),
        ("xmp", xmp, "CreateDate", .plain, { $0.creationDate.map(format) }),
        ("xmp", xmp, "ModifyDate", .plain, { $0.modificationDate.map(format) }),
        ("xmp", xmp, "MetadataDate", .plain, { $0.modificationDate.map(format) }),
    ]

    private static func format(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .colon))
    }

    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = try? Date(trimmed, strategy: .iso8601) { return date }
        if let date = try? Date(trimmed, strategy: .iso8601.time(includingFractionalSeconds: true)) { return date }
        // Dates without a time zone, or without a time at all.
        for layout in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = layout
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func uri(of node: XMLNode) -> String? {
        if let uri = node.uri { return uri }
        guard let name = node.name, let owner = (node as? XMLElement) ?? (node.parent as? XMLElement) else { return nil }
        return owner.resolveNamespace(forName: name)?.stringValue
    }

    private static func descriptions(in document: XMLDocument) -> [XMLElement] {
        ((try? document.nodes(forXPath: "//*[local-name()='Description']")) ?? []).compactMap { $0 as? XMLElement }
    }

    // MARK: Reading

    /// What a packet says about the document. Fields it does not mention are `nil`.
    static func read(_ packet: Data) -> DocumentInfo {
        var info = DocumentInfo()
        guard let document = try? XMLDocument(data: packet) else { return info }
        var values: [String: String] = [:]
        for description in descriptions(in: document) {
            for property in properties {
                let key = "\(property.uri)\(property.name)"
                guard values[key] == nil else { continue }
                if let attribute = description.attributes?.first(where: { $0.localName == property.name && uri(of: $0) == property.uri }),
                   let text = attribute.stringValue, !text.isEmpty {
                    values[key] = text
                } else if let element = description.elements(forLocalName: property.name, uri: property.uri).first {
                    // Alternatives and lists hold their text in `rdf:li` items.
                    let items = ((try? element.nodes(forXPath: ".//*[local-name()='li']")) ?? []).compactMap(\.stringValue)
                    let text = items.isEmpty ? element.stringValue ?? "" : (property.shape == .list ? items.joined(separator: ", ") : items[0])
                    if !text.isEmpty { values[key] = text }
                }
            }
        }
        info.title = values[dc + "title"]
        info.author = values[dc + "creator"]
        info.subject = values[dc + "description"]
        info.keywords = values[pdf + "Keywords"]
        info.producer = values[pdf + "Producer"]
        info.creator = values[xmp + "CreatorTool"]
        info.creationDate = values[xmp + "CreateDate"].flatMap(parseDate)
        info.modificationDate = values[xmp + "ModifyDate"].flatMap(parseDate)
        return info
    }

    // MARK: Writing

    /// A packet saying what `info` says. Everything else an existing packet holds is kept.
    static func updated(_ existing: Data?, with info: DocumentInfo) -> Data {
        let document = existing.flatMap { try? XMLDocument(data: $0) }.flatMap { descriptions(in: $0).isEmpty ? nil : $0 } ?? fresh()
        let all = descriptions(in: document)
        for description in all {
            for property in properties {
                for attribute in description.attributes ?? [] where attribute.localName == property.name && uri(of: attribute) == property.uri {
                    if let name = attribute.name { description.removeAttribute(forName: name) }
                }
                for element in description.elements(forLocalName: property.name, uri: property.uri) {
                    element.detach()
                }
            }
        }
        guard let target = all.first else { return existing ?? Data() }
        for property in properties {
            guard let text = property.value(info), !text.isEmpty else { continue }
            if target.resolvePrefix(forNamespaceURI: property.uri) != property.prefix {
                target.addNamespace(XMLNode.namespace(withName: property.prefix, stringValue: property.uri) as! XMLNode)
            }
            let element = XMLElement(name: "\(property.prefix):\(property.name)", uri: property.uri)
            switch property.shape {
            case .plain:
                element.stringValue = text
            case .alternatives, .list:
                let prefix = target.resolvePrefix(forNamespaceURI: rdf) ?? "rdf"
                let container = XMLElement(name: "\(prefix):\(property.shape == .list ? "Seq" : "Alt")", uri: rdf)
                let item = XMLElement(name: "\(prefix):li", uri: rdf)
                item.stringValue = text
                if property.shape == .alternatives {
                    item.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
                }
                container.addChild(item)
                element.addChild(container)
            }
            target.addChild(element)
        }

        guard let root = document.rootElement() else { return existing ?? Data() }
        var packet = Data("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n".utf8)
        packet.append(Data(root.xmlString(options: [.nodePrettyPrint]).utf8))
        packet.append(Data("\n<?xpacket end=\"w\"?>".utf8))
        return packet
    }

    private static func fresh() -> XMLDocument {
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(rdf)"><rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>
        """
        // The text above is well formed.
        return try! XMLDocument(xmlString: text)
    }
}
