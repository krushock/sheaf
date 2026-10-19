import Foundation

/// Things a document carries that its pages do not show, and that may say more than
/// whoever shares it means to: who made it and with what, attached files, scripts,
/// comments, bookmarks, and data the program that made it left behind.
public enum HiddenInformation: String, Sendable, CaseIterable, Identifiable {
    /// The author, title, programs and dates, in the document information and in XMP.
    case metadata
    /// Files carried inside the document, and the comments that hold files.
    case attachments
    /// JavaScript, and actions that run when the document or a page opens or closes,
    /// that start programs or that send form data.
    case scripts
    /// Comments and markup, with their pop-up notes. Links and form fields stay.
    case comments
    case bookmarks
    /// Data the program that made the document keeps for itself, and stored page thumbnails.
    case privateData

    public var id: Self { self }
}

extension PDFEditor {
    /// Action types that do something besides moving within the document.
    private static let activeActions: Set<PDFName> = ["JavaScript", "Launch", "SubmitForm", "ImportData", "ResetForm", "Rendition", "Sound", "Movie"]

    /// How much of each kind of hidden information the document has. Kinds it has none
    /// of are left out.
    public func hiddenInformation() throws -> [HiddenInformation: Int] {
        var found: [HiddenInformation: Int] = [:]
        func count(_ kind: HiddenInformation, _ number: Int = 1) {
            guard number > 0 else { return }
            found[kind, default: 0] += number
        }
        let catalog = try catalog()

        let info = try trailer["Info"].map(resolve)?.dictionaryValue ?? [:]
        count(.metadata, info.keys.filter { $0 != "Trapped" }.count)
        if catalog["Metadata"] != nil { count(.metadata) }

        let names = try value("Names", in: catalog).dictionaryValue ?? [:]
        count(.attachments, try nameTreeCount(try value("EmbeddedFiles", in: names)))
        count(.scripts, try nameTreeCount(try value("JavaScript", in: names)))
        if try isActive(try value("OpenAction", in: catalog)) { count(.scripts) }
        if catalog["AA"] != nil { count(.scripts) }

        if let outlines = try value("Outlines", in: catalog).dictionaryValue, outlines["First"] != nil {
            count(.bookmarks, max(abs(try value("Count", in: outlines).intValue ?? 1), 1))
        }
        if catalog["PieceInfo"] != nil { count(.privateData) }

        for page in try pageIDs() {
            guard let dictionary = try object(page).dictionaryValue else { continue }
            if dictionary["AA"] != nil { count(.scripts) }
            if dictionary["PieceInfo"] != nil || dictionary["Thumb"] != nil || dictionary[Self.textBoxesKey] != nil { count(.privateData) }
            if dictionary["Metadata"] != nil { count(.metadata) }
            for entry in try value("Annots", in: dictionary).arrayValue ?? [] {
                guard let annotation = try resolve(entry).dictionaryValue else { continue }
                let subtype = annotation["Subtype"]?.nameValue
                if subtype == "FileAttachment" { count(.attachments) }
                if let subtype, !["Link", "Widget", "Popup", "FileAttachment"].contains(subtype) { count(.comments) }
                if annotation["AA"] != nil { count(.scripts) }
                if try isActive(try value("A", in: annotation)) { count(.scripts) }
            }
        }
        if let form = try value("AcroForm", in: catalog).dictionaryValue {
            for field in try allFields(try value("Fields", in: form).arrayValue ?? []) {
                if let actions = try resolve(field).dictionaryValue?["AA"], !actions.isNull { count(.scripts) }
            }
        }
        return found
    }

    /// Takes hidden information of the given kinds out of the document. Saving the
    /// document afterwards leaves out what nothing refers to any more.
    public mutating func removeHiddenInformation(_ kinds: Set<HiddenInformation>) throws {
        guard !kinds.isEmpty, let catalogID else { return }
        let catalog = try catalog()

        if kinds.contains(.metadata) { setTrailer("Info", nil) }
        let opensActively = try isActive(try value("OpenAction", in: catalog))
        try update(catalogID) { catalog in
            if kinds.contains(.metadata) { catalog["Metadata"] = nil }
            if kinds.contains(.bookmarks) {
                catalog["Outlines"] = nil
                if catalog["PageMode"]?.nameValue == "UseOutlines" { catalog["PageMode"] = nil }
            }
            if kinds.contains(.privateData) { catalog["PieceInfo"] = nil }
            if kinds.contains(.scripts) {
                catalog["AA"] = nil
                if opensActively { catalog["OpenAction"] = nil }
            }
        }
        if kinds.contains(.attachments) || kinds.contains(.scripts), let namesEntry = catalog["Names"] {
            var names = try resolve(namesEntry).dictionaryValue ?? [:]
            if kinds.contains(.attachments) { names["EmbeddedFiles"] = nil }
            if kinds.contains(.scripts) { names["JavaScript"] = nil }
            if let reference = namesEntry.referenceValue {
                set(.dictionary(names), for: reference)
            } else {
                try update(catalogID) { $0["Names"] = .dictionary(names) }
            }
        }

        let removesAnnotations = kinds.contains(.comments) || kinds.contains(.attachments)
        for page in try pageIDs() {
            guard let dictionary = try object(page).dictionaryValue else { continue }
            var kept: [PDFObject] = []
            var changed = false
            let entries = try value("Annots", in: dictionary).arrayValue ?? []
            for entry in entries {
                guard var annotation = try resolve(entry).dictionaryValue else { continue }
                let subtype = annotation["Subtype"]?.nameValue
                let isComment = subtype.map { !["Link", "Widget", "FileAttachment"].contains($0) } ?? false
                if (kinds.contains(.comments) && isComment) || (kinds.contains(.attachments) && subtype == "FileAttachment") {
                    changed = true
                    continue
                }
                let runsAction = try isActive(try value("A", in: annotation))
                if kinds.contains(.scripts), annotation["AA"] != nil || runsAction {
                    annotation["AA"] = nil
                    if runsAction { annotation["A"] = nil }
                    if let reference = entry.referenceValue { set(.dictionary(annotation), for: reference) } else { changed = true }
                    kept.append(entry.referenceValue.map { .reference($0) } ?? .dictionary(annotation))
                    continue
                }
                kept.append(entry)
            }
            // A pop-up note goes with the comment it belongs to.
            if removesAnnotations, changed {
                kept = try kept.filter { entry in
                    guard let annotation = try resolve(entry).dictionaryValue, annotation["Subtype"]?.nameValue == "Popup",
                          let parent = annotation["Parent"]?.referenceValue else { return true }
                    return kept.contains { $0.referenceValue == parent }
                }
            }
            try update(page) { page in
                if kinds.contains(.scripts) { page["AA"] = nil }
                if kinds.contains(.privateData) {
                    page["PieceInfo"] = nil
                    page["Thumb"] = nil
                    page[Self.textBoxesKey] = nil
                }
                if kinds.contains(.metadata) { page["Metadata"] = nil }
                if changed || kept.count != entries.count { page["Annots"] = kept.isEmpty ? nil : .array(kept) }
            }
        }

        if kinds.contains(.scripts), let form = try value("AcroForm", in: catalog).dictionaryValue {
            for field in try allFields(try value("Fields", in: form).arrayValue ?? []) {
                guard let reference = field.referenceValue, let dictionary = try object(reference).dictionaryValue, dictionary["AA"] != nil else { continue }
                try update(reference) { $0["AA"] = nil }
            }
        }
    }

    /// Whether an action does something besides moving within the document, following
    /// the actions chained after it.
    private func isActive(_ action: PDFObject) throws -> Bool {
        guard let dictionary = try resolve(action).dictionaryValue else { return false }
        if let type = dictionary["S"]?.nameValue, Self.activeActions.contains(type) { return true }
        let next = try resolve(dictionary["Next"] ?? .null)
        for chained in next.arrayValue ?? (next.isNull ? [] : [next]) where try isActive(chained) { return true }
        return false
    }

    /// How many entries a name tree has.
    private func nameTreeCount(_ node: PDFObject, depth: Int = 0) throws -> Int {
        guard depth < 32, let dictionary = try resolve(node).dictionaryValue else { return 0 }
        var total = (try value("Names", in: dictionary).arrayValue?.count ?? 0) / 2
        for kid in try value("Kids", in: dictionary).arrayValue ?? [] { total += try nameTreeCount(kid, depth: depth + 1) }
        return total
    }

    /// Every field of a form, with the fields inside fields.
    private func allFields(_ fields: [PDFObject], depth: Int = 0) throws -> [PDFObject] {
        guard depth < 32 else { return [] }
        var result: [PDFObject] = []
        for field in fields {
            result.append(field)
            if let kids = try resolve(field).dictionaryValue.map({ try value("Kids", in: $0) })?.arrayValue {
                result += try allFields(kids, depth: depth + 1)
            }
        }
        return result
    }
}
