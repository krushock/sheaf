import Foundation

/// One field of a fillable form: a text box, a checkbox, a group of radio buttons and so on.
///
/// A field holds one value and shows it in one or more places, its widgets. A group of
/// radio buttons is one field with a widget per button.
public struct FormField: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case text, checkbox, radio, dropdown, list, signature, button
    }

    /// A place on a page where the field is shown and filled in.
    public struct Widget: Sendable, Equatable, Identifiable {
        public var id: ObjectID
        public var pageIndex: Int?
        public var rect: PDFRectangle
        /// For checkboxes and radio buttons, the value the field takes when this one is on.
        public var onState: String?
        /// Whether this checkbox or radio button is the one that is on.
        public var isOn = false
        /// Hidden widgets are neither drawn nor clickable.
        public var isHidden = false
    }

    /// One entry of a dropdown or list.
    public struct Option: Sendable, Equatable, Hashable {
        /// What the field's value becomes.
        public var value: String
        /// What the person sees.
        public var title: String

        public init(value: String, title: String? = nil) {
            self.value = value
            self.title = title ?? value
        }
    }

    /// The object that holds the field.
    public let id: ObjectID
    public internal(set) var kind: Kind
    /// The last part of the field's full name, which is the part that can be changed.
    public var name: String
    /// The name with those of the groups the field is in, separated by periods.
    public internal(set) var fullName: String
    /// A description for people, shown as a tooltip and read by screen readers.
    public var label: String?
    /// What the field holds: its text, the chosen option's value, or for checkboxes and
    /// radio buttons the state that is on, `Off` when none is.
    public internal(set) var value: String
    public var defaultValue: String?
    public var options: [Option] = []

    public var isReadOnly = false
    public var isRequired = false
    public var isMultiline = false
    public var isPassword = false
    /// A dropdown that also takes typed text.
    public var isEditable = false
    /// A text field divided into one box per character.
    public var isComb = false
    public var maxLength: Int?

    /// Zero means the size is chosen to fit the field.
    public var fontSize = 0.0
    public var textColor = PDFColor.black
    public var alignment = Annotation.TextAlignment.left
    public var borderColor: PDFColor?
    public var backgroundColor: PDFColor?
    /// For text fields that hold a date, how it is written, such as `mm/dd/yyyy`.
    public var dateFormat: String?

    public internal(set) var widgets: [Widget]
    /// The objects that hold the field's value. More than one when a file spells one field
    /// out as several objects with the same name.
    var storage: [ObjectID] = []
    /// The font the file names for the field's text.
    var fontResource = "Helv"
    /// A signature field that has been signed.
    public internal(set) var isSigned = false

    /// Whether a person may change the value.
    public var isFillable: Bool {
        !isReadOnly && kind != .button && !(kind == .signature && isSigned)
    }

    /// What the field shows for its value: the chosen option's title for dropdowns and lists.
    public var displayValue: String {
        guard kind == .dropdown || kind == .list else { return value }
        return options.first { $0.value == value }?.title ?? value
    }

    /// The value as a date, for fields with a date format.
    public var dateValue: Date? {
        guard let dateFormat, !value.isEmpty else { return nil }
        return FormDate.formatter(for: dateFormat).date(from: value)
    }
}

/// Reading and writing dates the way forms describe them: `mm/dd/yyyy`, `d mmm yyyy`.
public enum FormDate {
    public static let standardFormat = "mm/dd/yyyy"

    public static func formatter(for format: String) -> DateFormatter {
        // The form's letters, in the order that keeps longer runs from being split.
        let replacements = [
            ("mmmm", "MMMM"), ("mmm", "MMM"), ("mm", "MM"), ("m", "M"), ("dddd", "EEEE"), ("ddd", "EEE"),
            ("HH", "HH"), ("hh", "hh"), ("MM", "mm"), ("ss", "ss"), ("tt", "a"),
        ]
        var result = "", rest = Substring(format)
        scan: while !rest.isEmpty {
            for (from, to) in replacements where rest.hasPrefix(from) {
                result += to
                rest = rest.dropFirst(from.count)
                continue scan
            }
            result.append(rest.removeFirst())
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = result
        return formatter
    }

    public static func string(from date: Date, format: String) -> String {
        formatter(for: format).string(from: date)
    }
}

enum FieldFlags {
    static let readOnly = 1 << 0, required = 1 << 1
    static let multiline = 1 << 12, password = 1 << 13, comb = 1 << 24
    static let noToggleToOff = 1 << 14, radio = 1 << 15, pushButton = 1 << 16
    static let combo = 1 << 17, edit = 1 << 18
}

extension ObjectSource {
    /// The document's form dictionary, and the object that holds it when it is one of its own.
    func acroForm() throws -> (dictionary: PDFDictionary, id: ObjectID?)? {
        let catalog = try catalog()
        guard let dictionary = try value("AcroForm", in: catalog).dictionaryValue else { return nil }
        return (dictionary, catalog["AcroForm"]?.referenceValue)
    }

    /// Whether the document has a form with at least one field.
    public var hasForm: Bool {
        ((try? acroForm()?.dictionary).flatMap { try? value("Fields", in: $0).arrayValue }?.isEmpty) == false
    }

    /// Every field of the document's form, in the order the form lists them.
    public func formFields() throws -> [FormField] {
        let roots = try value("Fields", in: try acroForm()?.dictionary ?? [:]).arrayValue ?? []

        // Which page each widget is on.
        var widgetPages: [ObjectID: Int] = [:]
        var widgetsOnPages: [ObjectID] = []
        for (index, page) in try pageIDs().enumerated() {
            guard let dictionary = try object(page).dictionaryValue else { continue }
            for entry in try value("Annots", in: dictionary).arrayValue ?? [] {
                guard let id = entry.referenceValue, widgetPages[id] == nil else { continue }
                widgetPages[id] = index
                if roots.isEmpty || (try? object(id).dictionaryValue?["Subtype"]?.nameValue) == "Widget" { widgetsOnPages.append(id) }
            }
        }

        var fields: [FormField] = []
        var visited: Set<ObjectID> = []
        /// What a field takes from the groups above it when it does not say itself.
        let inheritable: [PDFName] = ["FT", "Ff", "V", "DV", "DA", "Q", "MaxLen", "Opt"]

        func visit(_ reference: PDFObject, inherited: PDFDictionary, prefix: String, depth: Int) throws {
            guard let id = reference.referenceValue, depth < 32, fields.count < 50_000, visited.insert(id).inserted,
                  let dictionary = try object(id).dictionaryValue
            else { return }
            var merged = inherited
            for key in inheritable {
                if let own = dictionary[key], !own.isNull { merged[key] = own }
            }
            let partial = try value("T", in: dictionary).textValue
            let fullName = [prefix, partial ?? ""].filter { !$0.isEmpty }.joined(separator: ".")
            let kids = try value("Kids", in: dictionary).arrayValue ?? []
            // Kids with a name are fields of their own; kids without are this field's widgets.
            let named = try kids.filter { try resolve($0).dictionaryValue?["T"] != nil }
            if !named.isEmpty {
                for kid in named { try visit(kid, inherited: merged, prefix: fullName, depth: depth + 1) }
                return
            }
            guard let type = try resolve(merged["FT"] ?? .null).nameValue else { return }
            let widgetIDs: [ObjectID] = kids.isEmpty ? [id] : kids.compactMap(\.referenceValue)
            if let field = try read(id: id, type: type, own: dictionary, merged: merged, name: partial ?? "", fullName: fullName, widgetIDs: widgetIDs, pages: widgetPages) {
                fields.append(field)
            }
        }
        for root in roots { try visit(root, inherited: [:], prefix: "", depth: 0) }

        // Some apps put widgets on pages without listing their fields in the form, or
        // without any form at all. Each is followed up to the top of its group and read
        // from there.
        var listed = Set(fields.flatMap { $0.widgets.map(\.id) })
        for widget in widgetsOnPages where !listed.contains(widget) {
            guard let dictionary = try object(widget).dictionaryValue, dictionary["Subtype"]?.nameValue == "Widget" else { continue }
            var top = widget
            var steps = 0
            while let parent = try object(top).dictionaryValue?["Parent"]?.referenceValue, steps < 32, !visited.contains(parent) {
                top = parent
                steps += 1
            }
            let before = fields.count
            try visit(.reference(top), inherited: [:], prefix: "", depth: 0)
            for field in fields[before...] { listed.formUnion(field.widgets.map(\.id)) }
        }

        // Fields with the same full name are one field, however many objects spell it out.
        var merged: [FormField] = []
        var positions: [String: Int] = [:]
        for field in fields {
            if !field.fullName.isEmpty, let position = positions["\(field.kind.rawValue)/\(field.fullName)"] {
                merged[position].widgets += field.widgets
                merged[position].storage += field.storage
            } else {
                positions["\(field.kind.rawValue)/\(field.fullName)"] = merged.count
                merged.append(field)
            }
        }
        return merged
    }

    private func read(
        id: ObjectID, type: PDFName, own: PDFDictionary, merged: PDFDictionary, name: String, fullName: String,
        widgetIDs: [ObjectID], pages: [ObjectID: Int]
    ) throws -> FormField? {
        let flags = try resolve(merged["Ff"] ?? .null).intValue ?? 0
        let kind: FormField.Kind
        switch type {
        case "Tx": kind = .text
        case "Btn": kind = flags & FieldFlags.pushButton != 0 ? .button : flags & FieldFlags.radio != 0 ? .radio : .checkbox
        case "Ch": kind = flags & FieldFlags.combo != 0 ? .dropdown : .list
        case "Sig": kind = .signature
        default: return nil
        }

        func text(_ object: PDFObject?) throws -> String? {
            let resolved = try resolve(object ?? .null)
            if let name = resolved.nameValue { return name.text }
            if let stream = resolved.streamValue { return String(decoding: try decodedData(of: stream), as: UTF8.self) }
            if let first = resolved.arrayValue?.first { return try text(first) }
            return resolved.textValue
        }

        var widgets: [FormField.Widget] = []
        var firstWidget: PDFDictionary?
        for widgetID in widgetIDs {
            guard let dictionary = try object(widgetID).dictionaryValue,
                  let rect = PDFRectangle(try value("Rect", in: dictionary))
            else { continue }
            if firstWidget == nil { firstWidget = dictionary }
            var widget = FormField.Widget(id: widgetID, pageIndex: pages[widgetID], rect: rect)
            widget.isHidden = (try value("F", in: dictionary).intValue ?? 0) & 0b10 != 0
            if kind == .checkbox || kind == .radio {
                // One picture per state. A single picture, which some writers give, has no states.
                var states: PDFDictionary = [:]
                if case .dictionary(let found) = try value("N", in: try value("AP", in: dictionary).dictionaryValue ?? [:]) { states = found }
                widget.onState = states.keys.filter { $0 != "Off" }.sorted().first?.text
                let current = try value("AS", in: dictionary).nameValue?.text
                widget.isOn = current != nil && current != "Off" && current == widget.onState
            }
            widgets.append(widget)
        }
        guard !widgets.isEmpty else { return nil }

        var field = FormField(id: id, kind: kind, name: name, fullName: fullName, value: "", widgets: widgets)
        field.storage = [id]
        field.label = try value("TU", in: own).textValue
        field.value = try text(merged["V"]) ?? ((kind == .checkbox || kind == .radio) ? "Off" : "")
        field.defaultValue = try text(merged["DV"])
        field.isReadOnly = flags & FieldFlags.readOnly != 0
        field.isRequired = flags & FieldFlags.required != 0
        field.isMultiline = kind == .text && flags & FieldFlags.multiline != 0
        field.isPassword = kind == .text && flags & FieldFlags.password != 0
        field.isComb = kind == .text && flags & FieldFlags.comb != 0
        field.isEditable = kind == .dropdown && flags & FieldFlags.edit != 0
        field.maxLength = try resolve(merged["MaxLen"] ?? .null).intValue.flatMap { $0 > 0 ? $0 : nil }
        field.alignment = Annotation.TextAlignment(rawValue: try resolve(merged["Q"] ?? .null).intValue ?? 0) ?? .left
        let signature = try resolve(merged["V"] ?? .null).dictionaryValue
        field.isSigned = kind == .signature && signature != nil

        for entry in try resolve(merged["Opt"] ?? .null).arrayValue ?? [] {
            let resolved = try resolve(entry)
            if let pair = resolved.arrayValue, pair.count >= 2, let value = try text(pair[0]), let title = try text(pair[1]) {
                field.options.append(FormField.Option(value: value, title: title))
            } else if let value = resolved.textValue {
                field.options.append(FormField.Option(value: value))
            }
        }

        // The text style is a snippet of content stream syntax: "/Helv 12 Tf 0 g".
        // Properly a string; some writers make it a name.
        let ownStyle = try resolve(merged["DA"] ?? .null)
        var style = ownStyle.stringValue ?? ownStyle.nameValue.map { name -> Data in
            // PDFKit writes the style as a name, with its spaces escaped a second time.
            var bytes: [UInt8] = [0x2F]
            let raw = name.bytes
            var index = 0
            while index < raw.count {
                if raw[index] == 0x23, index + 2 < raw.count, let value = UInt8(String(decoding: raw[index + 1...index + 2], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    index += 3
                } else {
                    bytes.append(raw[index])
                    index += 1
                }
            }
            return Data(bytes)
        }
        if style == nil, let form = try acroForm() { style = try value("DA", in: form.dictionary).stringValue }
        for operation in ContentStream(data: style ?? Data()).operations {
            switch operation.name {
            case "Tf":
                field.fontSize = operation.operands.last?.doubleValue ?? 0
                if let font = operation.operands.first?.nameValue { field.fontResource = font.text }
            case "g", "rg", "k": field.textColor = PDFColor(.array(operation.operands)) ?? .black
            default: break
            }
        }

        if let look = try firstWidget.map({ try value("MK", in: $0) })?.dictionaryValue {
            field.borderColor = PDFColor(try value("BC", in: look))
            field.backgroundColor = PDFColor(try value("BG", in: look))
        }

        // A date field is a text field with a script that formats what is typed.
        if kind == .text {
            if let stored = try value("SheafDateFormat", in: own).textValue {
                field.dateFormat = stored
            } else {
                var actions = try value("AA", in: own).dictionaryValue
                if actions == nil, let firstWidget { actions = try value("AA", in: firstWidget).dictionaryValue }
                let script = try text(try value("F", in: actions ?? [:]).dictionaryValue?["JS"]) ?? ""
                guard let start = script.range(of: "AFDate_FormatEx(") else { return field }
                let rest = script[start.upperBound...].drop { $0 == " " }
                if let quote = rest.first, quote == "\"" || quote == "'", let end = rest.dropFirst().firstIndex(of: quote) {
                    field.dateFormat = String(rest[rest.index(after: rest.startIndex)..<end])
                }
            }
        }
        return field
    }
}
