import Foundation

/// A field to add to a form.
public struct NewField: Sendable, Equatable {
    public var kind: FormField.Kind
    /// The field's name. A number is added if another field has it. Radio buttons that
    /// share a name form one group.
    public var name: String
    public var rect: PDFRectangle
    public var options: [FormField.Option] = []
    /// Makes a text field a date field.
    public var dateFormat: String?
    public var isMultiline = false
    public var hasBorder = true

    public init(kind: FormField.Kind, name: String, rect: PDFRectangle) {
        self.kind = kind
        self.name = name
        self.rect = rect
    }
}

extension PDFEditor {
    private static let widgetMarker: PDFName = "SheafBuilt"
    private static let defaultStyle = "/Helv 0 Tf 0 g"

    private func pageID(at index: Int) throws -> ObjectID {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        return pages[index]
    }

    /// The field with this identifier.
    public func formField(_ id: ObjectID) throws -> FormField {
        guard let field = try formFields().first(where: { $0.id == id }) else {
            throw SheafError.malformed("the field is not part of the document's form")
        }
        return field
    }

    /// The field a widget belongs to.
    public func formField(forWidget widget: ObjectID) throws -> FormField? {
        try formFields().first { $0.widgets.contains { $0.id == widget } }
    }

    private mutating func updateForm(_ change: (inout PDFDictionary) throws -> Void) throws {
        guard let catalogID else { throw SheafError.malformed("document has no catalog") }
        if let form = try acroForm(), let id = form.id {
            try update(id, change)
        } else {
            var dictionary = try acroForm()?.dictionary ?? [:]
            try change(&dictionary)
            try update(catalogID) { $0["AcroForm"] = .dictionary(dictionary) }
        }
    }

    // MARK: Filling

    /// Fills in a field.
    ///
    /// - Parameter value: The text for a text field; an option's value or title for a
    ///   dropdown or list; for a checkbox or radio group the state to turn on, or `Off`.
    public mutating func setFieldValue(_ id: ObjectID, to value: String) throws {
        var field = try formField(id)
        var value = value
        let stored: PDFObject?
        switch field.kind {
        case .text:
            if let limit = field.maxLength { value = String(value.prefix(limit)) }
            if !field.isMultiline { value = value.replacingOccurrences(of: "\n", with: " ") }
            stored = value.isEmpty ? nil : .string(PDFText.encode(value))
        case .dropdown, .list:
            if let option = field.options.first(where: { $0.value == value }) ?? field.options.first(where: { $0.title == value }) {
                value = option.value
            } else if !(field.isEditable || value.isEmpty) {
                throw SheafError.unsupported("a value that is not one of the field's options")
            }
            stored = value.isEmpty ? nil : .string(PDFText.encode(value))
        case .checkbox, .radio:
            try adopt(&field)
            guard value == "Off" || field.widgets.contains(where: { $0.onState == value }) else {
                throw SheafError.unsupported("a state the field does not have")
            }
            stored = .name(PDFName(bytes: Array(value.utf8)))
        case .signature, .button:
            throw SheafError.unsupported("filling a \(field.kind.rawValue) field")
        }
        try adopt(&field)
        for holder in field.storage {
            try update(holder) { dictionary in
                dictionary["V"] = stored
                // Formatted text and the list's own record of the choice would contradict the new value.
                dictionary["RV"] = nil
                dictionary["I"] = nil
            }
        }
        field.value = value
        for index in field.widgets.indices { field.widgets[index].isOn = field.widgets[index].onState == value && value != "Off" }
        try refreshAppearance(of: field)
        // A second description of the form in XML, which some apps would trust over this one.
        if try acroForm()?.dictionary["XFA"] != nil { try updateForm { $0["XFA"] = nil } }
    }

    /// Turns a checkbox or radio button on or off, by the widget that was clicked.
    public mutating func setButton(_ widget: ObjectID, on isOn: Bool) throws {
        guard var field = try formField(forWidget: widget), field.kind == .checkbox || field.kind == .radio else {
            throw SheafError.unsupported("a widget that is not a checkbox or radio button")
        }
        try adopt(&field)
        guard let state = field.widgets.first(where: { $0.id == widget })?.onState else { return }
        try setFieldValue(field.id, to: isOn ? state : "Off")
    }

    /// Brings a loosely written field up to what the rest of the engine, and other apps,
    /// expect: listed in the document's form, and with a picture for each state of its buttons.
    private mutating func adopt(_ field: inout FormField) throws {
        let form = try acroForm()
        var listed = try value("Fields", in: form?.dictionary ?? [:]).arrayValue ?? []
        // The top of the group each holder is in.
        var missing: [PDFObject] = []
        for holder in field.storage {
            var top = holder
            var steps = 0
            while let parent = try object(top).dictionaryValue?["Parent"]?.referenceValue, steps < 32 {
                top = parent
                steps += 1
            }
            if !listed.contains(.reference(top)), !missing.contains(.reference(top)) { missing.append(.reference(top)) }
        }
        if form == nil || !missing.isEmpty {
            listed += missing
            let needsBasics = form == nil
            try updateForm { dictionary in
                dictionary["Fields"] = .array(listed)
                if needsBasics {
                    dictionary["DA"] = .string(Data(Self.defaultStyle.utf8))
                    dictionary["DR"] = ["Font": .dictionary(Self.standardFormFonts)]
                }
            }
        }
        guard field.kind == .checkbox || field.kind == .radio, field.widgets.contains(where: { $0.onState == nil }) else { return }
        // Buttons with one fixed picture cannot show on and off; they get pictures of ours.
        var number = 1
        for index in field.widgets.indices where field.widgets[index].onState == nil {
            var state = field.kind == .checkbox && field.widgets.count == 1 ? "Yes" : "Choice\(number)"
            while field.widgets.contains(where: { $0.onState == state }) {
                number += 1
                state = "Choice\(number)"
            }
            field.widgets[index].onState = state
            try update(field.widgets[index].id) { $0[Self.widgetMarker] = true }
        }
        if field.borderColor == nil { field.borderColor = PDFColor(red: 0.5, green: 0.5, blue: 0.55) }
        for holder in field.storage { try update(holder) { $0["V"] = .name("Off") } }
        field.value = "Off"
        try refreshAppearance(of: field)
    }

    private static let standardFormFonts: PDFDictionary = [
        "Helv": ["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding")],
        "ZaDb": ["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("ZapfDingbats")],
    ]

    /// Puts every field back to its default value, or empties it when it has none.
    public mutating func resetForm() throws {
        for field in try formFields() where field.kind != .signature && field.kind != .button {
            let fallback = field.kind == .checkbox || field.kind == .radio ? "Off" : ""
            let target = field.defaultValue ?? fallback
            guard field.value != target else { continue }
            do {
                try setFieldValue(field.id, to: target)
            } catch SheafError.unsupported {
                try setFieldValue(field.id, to: fallback)
            }
        }
    }

    // MARK: Appearance

    private func fontName(for field: FormField) throws -> String {
        if let known = FieldAppearance.standardFonts[field.fontResource] { return known }
        // The form's own font list says what the short name stands for.
        let resources = try value("DR", in: try acroForm()?.dictionary ?? [:]).dictionaryValue ?? [:]
        let fonts = try value("Font", in: resources).dictionaryValue ?? [:]
        let font = try resolve(fonts[PDFName(bytes: Array(field.fontResource.utf8))] ?? .null).dictionaryValue
        // Without an entry in the list, the short name may itself be a font's name.
        guard let base = try font.map({ try value("BaseFont", in: $0) })?.nameValue?.text else { return field.fontResource }
        // Subsets are named "ABCDEF+RealName".
        return base.split(separator: "+").last.map(String.init) ?? "Helvetica"
    }

    /// Redraws a field's widgets for its current value and properties.
    mutating func refreshAppearance(of field: FormField) throws {
        let fontName = try fontName(for: field)
        for widget in field.widgets {
            guard let dictionary = try object(widget.id).dictionaryValue else { continue }
            let isOurs = dictionary[Self.widgetMarker] != nil
            let style = try value("BS", in: dictionary).dictionaryValue
            let borderWidth = field.borderColor == nil ? 0 : (style?["W"]?.doubleValue ?? 1)
            // A widget may be turned on its page; its picture is then drawn upright and turned.
            let turn = ((try value("R", in: try value("MK", in: dictionary).dictionaryValue ?? [:]).intValue ?? 0) % 360 + 360) % 360
            let sideways = turn == 90 || turn == 270
            let size = sideways ? PageSize(width: widget.rect.height, height: widget.rect.width) : PageSize(width: widget.rect.width, height: widget.rect.height)
            let matrix: PDFObject? = switch turn {
            case 90: [0, 1, -1, 0, .real(widget.rect.width), 0]
            case 180: [-1, 0, 0, -1, .real(widget.rect.width), .real(widget.rect.height)]
            case 270: [0, -1, 1, 0, 0, .real(widget.rect.height)]
            default: nil
            }
            func form(_ content: Data, fonts: PDFDictionary = [:]) -> PDFObject {
                var formDictionary: PDFDictionary = [
                    "Type": .name("XObject"), "Subtype": .name("Form"), "Filter": .name("FlateDecode"),
                    "Resources": fonts.isEmpty ? [:] : ["Font": .dictionary(fonts)],
                    "BBox": PDFRectangle(x: 0, y: 0, width: size.width, height: size.height).object,
                ]
                formDictionary["Matrix"] = matrix
                return .reference(add(.stream(PDFStream(dictionary: formDictionary, data: Flate.deflate(content)))))
            }

            switch field.kind {
            case .text, .dropdown, .list:
                let shown = field.kind == .text ? field.value : field.displayValue
                let drawing = FieldAppearance.text(field, value: field.kind == .list ? field.value : shown, size: size, borderWidth: borderWidth, fontName: fontName)
                let fonts = drawing.text.fontResources(in: &self)
                let look = form(drawing.content, fonts: fonts)
                try update(widget.id) { $0["AP"] = ["N": look] }
            case .checkbox, .radio:
                let state = widget.onState ?? "Yes"
                let current = PDFObject.name(widget.isOn ? PDFName(bytes: Array(state.utf8)) : "Off")
                // Buttons that came with the file keep the pictures they came with.
                guard isOurs else {
                    try update(widget.id) { $0["AS"] = current }
                    continue
                }
                let draw = field.kind == .radio ? FieldAppearance.radio : FieldAppearance.checkbox
                let on = form(draw(field, true, size, borderWidth)), off = form(draw(field, false, size, borderWidth))
                try update(widget.id) { dictionary in
                    dictionary["AP"] = ["N": [PDFName(bytes: Array(state.utf8)): on, "Off": off]]
                    dictionary["AS"] = current
                }
            case .signature:
                guard isOurs, !field.isSigned else { continue }
                let look = form(FieldAppearance.signature(field, size: size, borderWidth: borderWidth))
                try update(widget.id) { $0["AP"] = ["N": look] }
            case .button:
                continue
            }
        }
    }

    // MARK: Building

    /// Adds a field to the document's form, starting the form if there is none.
    ///
    /// - Returns: The new widget. Its field is `formField(forWidget:)`.
    @discardableResult
    public mutating func addField(_ new: NewField, toPageAt index: Int) throws -> ObjectID {
        let page = try pageID(at: index)
        let existing = try formFields()
        if try acroForm() == nil {
            try updateForm { form in
                form["Fields"] = []
                form["DA"] = .string(Data(Self.defaultStyle.utf8))
                form["DR"] = ["Font": .dictionary(Self.standardFormFonts)]
            }
        }

        var widget: PDFDictionary = [
            "Type": .name("Annot"), "Subtype": .name("Widget"), "Rect": new.rect.object, "P": .reference(page), "F": 4,
            Self.widgetMarker: true,
        ]
        if new.hasBorder {
            widget["MK"] = ["BC": [.real(0.5), .real(0.5), .real(0.55)]]
            widget["BS"] = ["W": 1, "S": .name("S")]
        }
        let widgetID = reserve()

        // Another radio button with the same name joins that group.
        if new.kind == .radio, let group = existing.first(where: { $0.kind == .radio && $0.fullName == new.name }) {
            var number = group.widgets.count + 1
            while group.widgets.contains(where: { $0.onState == "Choice\(number)" }) { number += 1 }
            widget["Parent"] = .reference(group.id)
            widget["AS"] = .name("Off")
            set(.dictionary(widget), for: widgetID)
            try update(group.id) { dictionary in
                dictionary["Kids"] = .array((dictionary["Kids"]?.arrayValue ?? []) + [.reference(widgetID)])
            }
            try appendAnnotation(widgetID, to: page)
            var field = try formField(group.id)
            if let position = field.widgets.firstIndex(where: { $0.id == widgetID }) { field.widgets[position].onState = "Choice\(number)" }
            field.borderColor = new.hasBorder ? PDFColor(red: 0.5, green: 0.5, blue: 0.55) : nil
            try refreshAppearance(of: field)
            return widgetID
        }

        var name = new.name.isEmpty ? new.kind.rawValue.capitalized : new.name
        // Periods separate the levels of a name, so a name of its own cannot hold one.
        name = name.replacingOccurrences(of: ".", with: " ")
        let taken = Set(existing.map(\.fullName))
        if taken.contains(name) {
            var number = 2
            while taken.contains("\(name) \(number)") { number += 1 }
            name = "\(name) \(number)"
        }

        var field: PDFDictionary = ["T": .string(PDFText.encode(name)), "DA": .string(Data(Self.defaultStyle.utf8))]
        var flags = 0
        switch new.kind {
        case .text:
            field["FT"] = .name("Tx")
            if new.isMultiline { flags |= FieldFlags.multiline }
            if let format = new.dateFormat { Self.setDateFormat(format, in: &field) }
        case .checkbox:
            field["FT"] = .name("Btn")
            field["V"] = .name("Off")
            widget["MK"] = .dictionary((widget["MK"]?.dictionaryValue ?? [:]).merging(["CA": .string(Data("4".utf8))]) { $1 })
        case .radio:
            field["FT"] = .name("Btn")
            field["V"] = .name("Off")
            flags |= FieldFlags.radio | FieldFlags.noToggleToOff
            widget["MK"] = .dictionary((widget["MK"]?.dictionaryValue ?? [:]).merging(["CA": .string(Data("l".utf8))]) { $1 })
        case .dropdown, .list:
            field["FT"] = .name("Ch")
            if new.kind == .dropdown { flags |= FieldFlags.combo }
            field["Opt"] = Self.optionsObject(new.options)
        case .signature:
            field["FT"] = .name("Sig")
        case .button:
            throw SheafError.unsupported("adding a push button")
        }
        if flags != 0 { field["Ff"] = .integer(flags) }

        let fieldID: ObjectID
        if new.kind == .radio {
            // A group is a field of its own, with each button a widget under it.
            fieldID = reserve()
            field["Kids"] = [.reference(widgetID)]
            widget["Parent"] = .reference(fieldID)
            set(.dictionary(field), for: fieldID)
            set(.dictionary(widget), for: widgetID)
        } else {
            // One object is both the field and its only widget.
            fieldID = widgetID
            set(.dictionary(field.merging(widget) { $1 }), for: widgetID)
        }
        let listed = try value("Fields", in: try acroForm()?.dictionary ?? [:]).arrayValue ?? []
        try updateForm { $0["Fields"] = .array(listed + [.reference(fieldID)]) }
        try appendAnnotation(widgetID, to: page)

        var made = try formField(fieldID)
        if new.kind == .checkbox { made.widgets[0].onState = "Yes" }
        if new.kind == .radio { made.widgets[0].onState = "Choice1" }
        try refreshAppearance(of: made)
        return widgetID
    }

    private mutating func appendAnnotation(_ id: ObjectID, to page: ObjectID) throws {
        let references = try value("Annots", in: try object(page).dictionaryValue ?? [:]).arrayValue ?? []
        try update(page) { $0["Annots"] = .array(references + [.reference(id)]) }
    }

    private static func optionsObject(_ options: [FormField.Option]) -> PDFObject {
        .array(options.map { option in
            let value = PDFObject.string(PDFText.encode(option.value))
            return option.title == option.value ? value : [value, .string(PDFText.encode(option.title))]
        })
    }

    /// Records a date format the way Acrobat does, with the scripts that apply it there.
    private static func setDateFormat(_ format: String?, in field: inout PDFDictionary) {
        guard let format, !format.isEmpty else {
            field["SheafDateFormat"] = nil
            field["AA"] = nil
            return
        }
        let quoted = format.replacingOccurrences(of: "\"", with: "")
        func script(_ function: String) -> PDFObject {
            ["S": .name("JavaScript"), "JS": .string(Data("\(function)(\"\(quoted)\");".utf8))]
        }
        field["SheafDateFormat"] = .string(PDFText.encode(format))
        field["AA"] = ["F": script("AFDate_FormatEx"), "K": script("AFDate_KeystrokeEx")]
    }

    /// Saves changes to a field's properties: its name, label, options, limits and look.
    /// The value is changed with `setFieldValue`.
    public mutating func updateField(_ field: FormField) throws {
        let before = try formField(field.id)
        var changed = field
        var name = field.name.replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = before.name }
        changed.name = name

        for holder in before.storage {
          try update(holder) { dictionary in
            dictionary["T"] = .string(PDFText.encode(name))
            dictionary["TU"] = field.label.flatMap { $0.isEmpty ? nil : .string(PDFText.encode($0)) }
            var flags = dictionary["Ff"]?.intValue ?? 0
            func set(_ bit: Int, _ isOn: Bool) { flags = isOn ? flags | bit : flags & ~bit }
            set(FieldFlags.readOnly, field.isReadOnly)
            set(FieldFlags.required, field.isRequired)
            if field.kind == .text {
                set(FieldFlags.multiline, field.isMultiline)
                set(FieldFlags.password, field.isPassword)
                set(FieldFlags.comb, field.isComb)
                dictionary["MaxLen"] = field.maxLength.map(PDFObject.integer)
                if field.dateFormat != before.dateFormat { Self.setDateFormat(field.dateFormat, in: &dictionary) }
            }
            if field.kind == .dropdown {
                set(FieldFlags.edit, field.isEditable)
            }
            if field.kind == .dropdown || field.kind == .list { dictionary["Opt"] = Self.optionsObject(field.options) }
            dictionary["Ff"] = flags == 0 ? nil : .integer(flags)
            dictionary["Q"] = field.alignment == .left ? nil : .integer(field.alignment.rawValue)
            let color = field.textColor
            let style = "/\(before.fontResource) \(Serializer.format(field.fontSize)) Tf \(Serializer.format(color.red)) \(Serializer.format(color.green)) \(Serializer.format(color.blue)) rg"
            dictionary["DA"] = .string(Data(style.utf8))
            if field.kind != .checkbox, field.kind != .radio {
                dictionary["DV"] = field.defaultValue.flatMap { $0.isEmpty ? nil : .string(PDFText.encode($0)) }
            }
          }
        }
        for widget in field.widgets {
            try update(widget.id) { dictionary in
                var look = dictionary["MK"]?.dictionaryValue ?? [:]
                look["BC"] = field.borderColor?.object
                look["BG"] = field.backgroundColor?.object
                dictionary["MK"] = look.isEmpty ? nil : .dictionary(look)
                if field.borderColor != nil, dictionary["BS"] == nil { dictionary["BS"] = ["W": 1, "S": .name("S")] }
            }
        }
        // A value that is no longer one of the options, or is now too long, is brought in line.
        changed.value = before.value
        changed.storage = before.storage
        changed.fontResource = before.fontResource
        if field.kind == .dropdown || field.kind == .list, !field.isEditable, !before.value.isEmpty,
           !field.options.contains(where: { $0.value == before.value }) {
            for holder in before.storage { try update(holder) { $0["V"] = nil } }
            changed.value = ""
        }
        if field.kind == .text, let limit = field.maxLength, before.value.count > limit {
            try setFieldValue(field.id, to: String(before.value.prefix(limit)))
            return
        }
        changed.widgets = try formField(field.id).widgets
        try refreshAppearance(of: changed)
    }

    /// Moves or resizes one of a field's widgets.
    public mutating func setWidgetRect(_ widget: ObjectID, to rect: PDFRectangle) throws {
        guard var field = try formField(forWidget: widget), let index = field.widgets.firstIndex(where: { $0.id == widget }) else {
            throw SheafError.malformed("the widget is not part of the document's form")
        }
        try update(widget) { $0["Rect"] = rect.object }
        field.widgets[index].rect = rect
        // Only the moved widget needs redrawing.
        field.widgets = [field.widgets[index]]
        try refreshAppearance(of: field)
    }

    /// Takes a widget off its page. A field left with no widgets is removed from the form.
    public mutating func removeWidget(_ widget: ObjectID) throws {
        guard let field = try formField(forWidget: widget) else {
            throw SheafError.malformed("the widget is not part of the document's form")
        }
        for page in try pageIDs() {
            guard let dictionary = try object(page).dictionaryValue,
                  let references = try value("Annots", in: dictionary).arrayValue, references.contains(.reference(widget))
            else { continue }
            let remaining = references.filter { $0 != .reference(widget) }
            try update(page) { $0["Annots"] = remaining.isEmpty ? nil : .array(remaining) }
        }
        if field.widgets.count > 1, field.id != widget {
            try update(field.id) { dictionary in
                dictionary["Kids"] = .array((dictionary["Kids"]?.arrayValue ?? []).filter { $0 != .reference(widget) })
            }
            if field.widgets.first(where: { $0.id == widget })?.isOn == true { try update(field.id) { $0["V"] = .name("Off") } }
            return
        }
        // The field goes too: out of the form's list, or out of the group it is in.
        let fieldDictionary = try object(field.id).dictionaryValue ?? [:]
        if let parent = fieldDictionary["Parent"]?.referenceValue, parent != field.id {
            try update(parent) { dictionary in
                dictionary["Kids"] = .array((dictionary["Kids"]?.arrayValue ?? []).filter { $0 != .reference(field.id) })
            }
        }
        let listed = try value("Fields", in: try acroForm()?.dictionary ?? [:]).arrayValue ?? []
        try updateForm { $0["Fields"] = .array(listed.filter { $0 != .reference(field.id) }) }
    }

    // MARK: Flattening

    /// Makes the form part of the pages: every field shows its value as plain drawing and
    /// can no longer be filled in.
    ///
    /// - Returns: How many widgets were flattened.
    @discardableResult
    public mutating func flattenForm() throws -> Int {
        let fields = try formFields()
        var byPage: [Int: Set<ObjectID>] = [:]
        for widget in fields.flatMap(\.widgets) {
            if let page = widget.pageIndex { byPage[page, default: []].insert(widget.id) }
        }
        var count = 0
        for (index, widgets) in byPage.sorted(by: { $0.key < $1.key }) {
            count += try flattenAnnotations(onPageAt: index, only: widgets, includingWidgets: true)
            // Widgets with nothing to show, such as empty signature fields, are just removed.
            let page = try pageID(at: index)
            let references = try value("Annots", in: try object(page).dictionaryValue ?? [:]).arrayValue ?? []
            let remaining = references.filter { $0.referenceValue.map { !widgets.contains($0) } ?? true }
            if remaining.count != references.count {
                try update(page) { $0["Annots"] = remaining.isEmpty ? nil : .array(remaining) }
            }
        }
        if let catalogID { try update(catalogID) { $0["AcroForm"] = nil } }
        return count
    }
}
