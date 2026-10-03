import SheafKit
import SwiftUI

/// The Format panel: how the selected annotation looks and what it says.
struct InspectorView: View {
    @Bindable var viewer: ViewerModel
    @FocusState private var isCommentFocused: Bool

    var body: some View {
        if let hit = viewer.selectedField {
            FormInspector(viewer: viewer, hit: hit)
                // A different field gets fresh text boxes, not the last one's half-typed text.
                .id(hit.widget.id)
        } else if let annotation = viewer.selectedAnnotation {
            Form {
                style(of: annotation)
                if annotation.kind == .freeText { text(of: annotation) }
                if annotation.kind == .link { link(of: annotation) }
                if annotation.kind != .freeText { comment }
                details(of: annotation)
            }
            .formStyle(.grouped)
            .onChange(of: viewer.commentFocusRequests, initial: true) { old, new in
                if new != old || new > 0, annotation.kind == .note { isCommentFocused = true }
            }
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "cursorarrow.click",
                description: Text(viewer.isFormEditing ? "Select a field to change it, or pick a tool above to add one." : "Select an annotation to change how it looks.")
            )
        }
    }

    // MARK: Sections

    @ViewBuilder private func style(of annotation: Annotation) -> some View {
        let kind = annotation.kind
        let hasColor = kind != .link && kind != .other && !(kind == .stamp && annotation.color == nil)
        let hasFill = [.square, .circle, .freeText].contains(kind)
        let hasLine = [.square, .circle, .line, .ink].contains(kind)
        let hasOpacity = [.highlight, .underline, .strikeOut, .square, .circle, .line, .ink].contains(kind)
        if hasColor || hasFill || hasLine || hasOpacity {
            Section("Style") {
                if hasColor {
                    ColorPicker(kind == .freeText ? "Text color" : "Color", selection: colorBinding(\.color, fallback: .black, String(localized: "Change Color")), supportsOpacity: false)
                }
                if hasFill {
                    Toggle("Fill", isOn: Binding(
                        get: { annotation.fillColor != nil },
                        set: { isOn in
                            viewer.updateSelection(String(localized: "Change Fill")) { $0.fillColor = isOn ? ($0.fillColor ?? .yellow) : nil }
                        }
                    ))
                    if annotation.fillColor != nil {
                        ColorPicker("Fill color", selection: colorBinding(\.fillColor, fallback: .yellow, String(localized: "Change Fill")), supportsOpacity: false)
                    }
                }
                if hasLine {
                    valueSlider(
                        "Line width", value: binding(\.lineWidth, String(localized: "Change Line Width")),
                        in: (kind == .line || kind == .ink ? 0.5 : 0)...16,
                        shown: Text("\(annotation.lineWidth, format: .number.precision(.fractionLength(0...1))) pt")
                    )
                }
                if kind == .line {
                    Picker("Arrowheads", selection: arrowheads(of: annotation)) {
                        Text("None").tag(0)
                        Text("At End").tag(1)
                        Text("At Start").tag(2)
                        Text("Both").tag(3)
                    }
                }
                if hasOpacity {
                    valueSlider(
                        "Opacity", value: binding(\.opacity, String(localized: "Change Opacity")), in: 0.1...1,
                        shown: Text(annotation.opacity, format: .percent.precision(.fractionLength(0)))
                    )
                }
            }
        }
    }

    /// A slider with its name above it and its value beside the name.
    private func valueSlider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>, shown: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                shown.monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { Text(title) }
                .labelsHidden()
        }
    }

    private func text(of annotation: Annotation) -> some View {
        Section("Text") {
            Picker("Font", selection: binding(\.fontName, String(localized: "Change Font"), refitsText: true)) {
                ForEach(Self.fonts(including: annotation.fontName), id: \.name) { font in
                    Text(font.title).tag(font.name)
                }
            }
            valueSlider(
                "Size", value: binding(\.fontSize, String(localized: "Change Text Size"), refitsText: true), in: 6...96,
                shown: Text("\(Int(annotation.fontSize)) pt")
            )
            Picker("Alignment", selection: binding(\.alignment, String(localized: "Change Alignment"))) {
                Label("Left", systemImage: "text.alignleft").tag(Annotation.TextAlignment.left)
                Label("Center", systemImage: "text.aligncenter").tag(Annotation.TextAlignment.center)
                Label("Right", systemImage: "text.alignright").tag(Annotation.TextAlignment.right)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder private func link(of annotation: Annotation) -> some View {
        Section("Link") {
            Picker("Goes to", selection: Binding(
                get: { if case .page = annotation.link { 1 } else { 0 } },
                set: { choice in
                    viewer.updateSelection(String(localized: "Change Link")) { $0.link = choice == 1 ? .page(viewer.currentPageIndex) : .url("https://") }
                }
            )) {
                Text("Web Address").tag(0)
                Text("Page").tag(1)
            }
            switch annotation.link {
            case .page(let index):
                Stepper(value: Binding(
                    get: { index + 1 },
                    set: { page in viewer.updateSelection(String(localized: "Change Link"), coalescing: "link") { $0.link = .page(page - 1) } }
                ), in: 1...max(viewer.pageCount, 1)) {
                    Text("Page \(index + 1)")
                }
            default:
                TextField("Address", text: Binding(
                    get: { if case .url(let url) = annotation.link { url } else { "" } },
                    set: { url in viewer.updateSelection(String(localized: "Change Link"), coalescing: "link") { $0.link = .url(url) } }
                ), prompt: Text(verbatim: "https://example.com"))
                    .labelsHidden()
            }
        }
    }

    private var comment: some View {
        Section("Comment") {
            TextEditor(text: binding(\.contents, String(localized: "Edit Comment")))
                .font(.body)
                .frame(minHeight: 70)
                .focused($isCommentFocused)
                .accessibilityLabel("Comment")
        }
    }

    private func details(of annotation: Annotation) -> some View {
        Section {
            if let author = annotation.author { LabeledContent("Author", value: author) }
            if let modified = annotation.modified {
                LabeledContent("Changed", value: modified.formatted(date: .abbreviated, time: .shortened))
            }
            Button("Delete", role: .destructive) { viewer.deleteSelection() }
        }
    }

    // MARK: Bindings

    /// A binding onto one property of the selected annotation. Each run of changes to the
    /// same property becomes one undo step.
    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<Annotation, Value> & Sendable, _ name: String, refitsText: Bool = false) -> Binding<Value> {
        Binding(
            get: { viewer.selectedAnnotation![keyPath: keyPath] },
            set: { value in
                viewer.updateSelection(name, coalescing: name) {
                    $0[keyPath: keyPath] = value
                    if refitsText { viewer.fitHeight(of: &$0) }
                }
            }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Annotation, PDFColor?> & Sendable, fallback: PDFColor, _ name: String) -> Binding<Color> {
        Binding(
            get: { (viewer.selectedAnnotation?[keyPath: keyPath] ?? fallback).color },
            set: { color in viewer.updateSelection(name, coalescing: name) { $0[keyPath: keyPath] = PDFColor(color) } }
        )
    }

    private func arrowheads(of annotation: Annotation) -> Binding<Int> {
        Binding(
            get: { (annotation.endEnding != .none ? 1 : 0) + (annotation.startEnding != .none ? 2 : 0) },
            set: { value in
                viewer.updateSelection(String(localized: "Change Arrowheads")) {
                    $0.endEnding = value & 1 != 0 ? .openArrow : .none
                    $0.startEnding = value & 2 != 0 ? .openArrow : .none
                }
            }
        )
    }

    /// A short list of fonts that suit notes on a page, plus whatever the text box already uses.
    private static func fonts(including current: String) -> [(name: String, title: String)] {
        var fonts = [
            ("Helvetica", "Helvetica"), ("Helvetica-Bold", "Helvetica Bold"), ("HelveticaNeue", "Helvetica Neue"),
            ("TimesNewRomanPSMT", "Times New Roman"), ("Georgia", "Georgia"), ("Menlo-Regular", "Menlo"),
            ("MarkerFelt-Thin", "Marker Felt"), ("Noteworthy-Light", "Noteworthy"),
        ]
        if !fonts.contains(where: { $0.0 == current }) { fonts.insert((current, current), at: 0) }
        return fonts
    }
}
