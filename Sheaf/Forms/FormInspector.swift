import SheafKit
import SwiftUI

/// The Format panel for a form field: its name, what it accepts and how it looks.
struct FormInspector: View {
    @Bindable var viewer: ViewerModel
    let hit: FieldHit

    private var field: FormField { hit.field }

    private static let dateFormats = ["mm/dd/yyyy", "dd/mm/yyyy", "dd.mm.yyyy", "yyyy-mm-dd", "d mmm yyyy", "mmmm d, yyyy"]
    private static let fontSizes: [Double] = [0, 8, 9, 10, 11, 12, 14, 18, 24]

    var body: some View {
        Form {
            Section(kindTitle) {
                CommittedTextField("Name", text: field.name) { name in
                    viewer.updateSelectedField(String(localized: "Rename Field")) { $0.name = name }
                }
                CommittedTextField("Label", text: field.label ?? "", prompt: "Shown as a tooltip") { label in
                    viewer.updateSelectedField(String(localized: "Change Label")) { $0.label = label.isEmpty ? nil : label }
                }
                if field.fullName != field.name {
                    LabeledContent("Full Name", value: field.fullName)
                }
            }

            switch field.kind {
            case .text: text
            case .dropdown, .list: options
            case .checkbox:
                Section {
                    Toggle("Checked", isOn: Binding(get: { hit.widget.isOn }, set: { _ in viewer.toggle(hit) }))
                }
            case .radio:
                Section {
                    LabeledContent("Buttons in Group", value: "\(field.widgets.count)")
                    LabeledContent("This Button's Value", value: hit.widget.onState ?? "")
                } footer: {
                    Text("With a radio button selected, the Radio Button tool adds another to its group.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .signature, .button:
                EmptyView()
            }

            Section {
                Toggle("Required", isOn: binding(\.isRequired, String(localized: "Change Required")))
                Toggle("Read Only", isOn: binding(\.isReadOnly, String(localized: "Change Read Only")))
            }

            Section("Look") {
                if field.kind == .text || field.kind == .dropdown || field.kind == .list {
                    Picker("Text Size", selection: binding(\.fontSize, String(localized: "Change Text Size"))) {
                        ForEach(Self.fontSizes + (Self.fontSizes.contains(field.fontSize) ? [] : [field.fontSize]), id: \.self) { size in
                            Text(size == 0 ? String(localized: "Automatic") : "\(size.formatted()) pt").tag(size)
                        }
                    }
                    Picker("Alignment", selection: binding(\.alignment, String(localized: "Change Alignment"))) {
                        Label("Left", systemImage: "text.alignleft").tag(Annotation.TextAlignment.left)
                        Label("Center", systemImage: "text.aligncenter").tag(Annotation.TextAlignment.center)
                        Label("Right", systemImage: "text.alignright").tag(Annotation.TextAlignment.right)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                }
                if field.kind != .signature {
                    ColorPicker(field.kind == .checkbox || field.kind == .radio ? "Mark Color" : "Text Color", selection: Binding(
                        get: { field.textColor.color },
                        set: { color in viewer.updateSelectedField(String(localized: "Change Color"), coalescing: "color") { $0.textColor = PDFColor(color) } }
                    ), supportsOpacity: false)
                }
                optionalColor("Border", \.borderColor, fallback: PDFColor(red: 0.5, green: 0.5, blue: 0.55))
                optionalColor("Background", \.backgroundColor, fallback: .white)
            }

            Section {
                Button("Delete Field", role: .destructive) { viewer.deleteSelection() }
            }
        }
        .formStyle(.grouped)
    }

    private var kindTitle: LocalizedStringKey {
        switch field.kind {
        case .text: field.dateFormat == nil ? "Text Field" : "Date Field"
        case .checkbox: "Checkbox"
        case .radio: "Radio Button"
        case .dropdown: "Dropdown"
        case .list: "List"
        case .signature: "Signature Field"
        case .button: "Button"
        }
    }

    // MARK: Sections

    @ViewBuilder private var text: some View {
        Section {
            Toggle("Date", isOn: Binding(
                get: { field.dateFormat != nil },
                set: { isOn in
                    viewer.updateSelectedField(String(localized: "Change Field Type")) { $0.dateFormat = isOn ? FormDate.standardFormat : nil }
                }
            ))
            if let format = field.dateFormat {
                Picker("Format", selection: binding(\.dateFormat, String(localized: "Change Date Format"))) {
                    ForEach(Self.dateFormats + (Self.dateFormats.contains(format) ? [] : [format]), id: \.self) { format in
                        Text(FormDate.string(from: .now, format: format)).tag(String?.some(format))
                    }
                }
            } else {
                Toggle("Several Lines", isOn: binding(\.isMultiline, String(localized: "Change Lines")))
                Toggle("Hide Typing", isOn: binding(\.isPassword, String(localized: "Change Hide Typing")))
                CommittedTextField("Longest Entry", text: field.maxLength.map(String.init) ?? "", prompt: "No limit") { text in
                    let limit = Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
                    viewer.updateSelectedField(String(localized: "Change Limit")) { $0.maxLength = limit }
                }
            }
            CommittedTextField("Starts With", text: field.value, prompt: "Empty") { viewer.setDefaultValue($0) }
        }
    }

    @ViewBuilder private var options: some View {
        Section("Options") {
            ForEach(Array(field.options.enumerated()), id: \.offset) { index, option in
                HStack {
                    CommittedTextField("Option \(index + 1)", text: option.title, hidesLabel: true) { title in
                        viewer.updateSelectedField(String(localized: "Change Option")) {
                            guard $0.options.indices.contains(index), !title.isEmpty else { return }
                            $0.options[index] = FormField.Option(value: title)
                        }
                    }
                    Button {
                        viewer.updateSelectedField(String(localized: "Remove Option")) {
                            if $0.options.indices.contains(index) { $0.options.remove(at: index) }
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(field.options.count < 2)
                    .help("Remove this option")
                }
            }
            Button("Add Option") {
                viewer.updateSelectedField(String(localized: "Add Option")) { field in
                    var number = field.options.count + 1
                    while field.options.contains(where: { $0.value == String(localized: "Option \(number)") }) { number += 1 }
                    field.options.append(FormField.Option(value: String(localized: "Option \(number)")))
                }
            }
            if field.kind == .dropdown {
                Toggle("Also Takes Typed Text", isOn: binding(\.isEditable, String(localized: "Change Typing")))
            }
        }
    }

    private func optionalColor(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<FormField, PDFColor?> & Sendable, fallback: PDFColor) -> some View {
        HStack {
            Toggle(title, isOn: Binding(
                get: { field[keyPath: keyPath] != nil },
                set: { isOn in viewer.updateSelectedField(String(localized: "Change Look")) { $0[keyPath: keyPath] = isOn ? fallback : nil } }
            ))
            if field[keyPath: keyPath] != nil {
                ColorPicker(title, selection: Binding(
                    get: { (field[keyPath: keyPath] ?? fallback).color },
                    set: { color in viewer.updateSelectedField(String(localized: "Change Look"), coalescing: "look") { $0[keyPath: keyPath] = PDFColor(color) } }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<FormField, Value> & Sendable, _ name: String) -> Binding<Value> {
        Binding(
            get: { field[keyPath: keyPath] },
            set: { value in viewer.updateSelectedField(name) { $0[keyPath: keyPath] = value } }
        )
    }
}

/// A text field that reports its text when the person is done with it, by pressing Return
/// or moving on, and not at every keystroke.
struct CommittedTextField: View {
    let title: LocalizedStringKey
    let text: String
    var prompt: LocalizedStringKey?
    var hidesLabel = false
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(_ title: LocalizedStringKey, text: String, prompt: LocalizedStringKey? = nil, hidesLabel: Bool = false, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.text = text
        self.prompt = prompt
        self.hidesLabel = hidesLabel
        self.onCommit = onCommit
    }

    var body: some View {
        Group {
            if hidesLabel {
                TextField(title, text: $draft, prompt: prompt.map { Text($0) }).labelsHidden()
            } else {
                TextField(title, text: $draft, prompt: prompt.map { Text($0) })
            }
        }
        .focused($isFocused)
        .onAppear { draft = text }
        .onChange(of: text) { draft = text }
        .onSubmit(commit)
        .onChange(of: isFocused) { if !isFocused { commit() } }
    }

    private func commit() {
        if draft != text { onCommit(draft) }
    }
}
