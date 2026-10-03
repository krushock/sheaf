import SheafKit
import SwiftUI

/// The row of annotation tools shown under the toolbar while marking up.
struct MarkupBar: View {
    @Bindable var viewer: ViewerModel
    @State private var lastTextMark = MarkupTool.highlight
    @State private var lastShape = MarkupTool.rectangle
    @State private var asksForStampText = false
    @State private var customStampText = ""

    var body: some View {
        // The tools are an overlay on a bar of fixed height. Laid out directly, the row of
        // menus reports a minimum width far larger than it needs, and the split view then
        // grows past the window instead of letting the bar give way.
        Rectangle()
            .fill(.bar)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { tools }
            .clipped()
            .alert("Custom Stamp", isPresented: $asksForStampText) {
                TextField("Text", text: $customStampText)
                Button("Add") { place(stampText: customStampText, color: .red) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The text is shown in capitals inside a frame.")
            }
    }

    private var tools: some View {
        HStack(spacing: 4) {
            toolButton(.select)
            separator
            toolGroup(MarkupTool.textMarks, last: $lastTextMark) {
                // With text already selected, the button marks it at once, as in Preview.
                if viewer.pdfView.currentSelection?.string?.isEmpty == false, let kind = lastTextMark.textMarkupKind {
                    viewer.applyTextMarkup(kind)
                    return true
                }
                return false
            }
            toolButton(.note)
            toolButton(.text)
            toolGroup(MarkupTool.shapes, last: $lastShape) { false }
            toolButton(.draw)
            stampMenu
            Button {
                viewer.isSignaturePickerPresented.toggle()
            } label: {
                Label("Sign", systemImage: "signature")
            }
            .help("Sign")
            .popover(isPresented: $viewer.isSignaturePickerPresented, arrowEdge: .bottom) {
                SignaturePicker(viewer: viewer)
            }
            toolButton(.link)
            separator
            StyleControls(viewer: viewer)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .fixedSize()
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    private func toolButton(_ tool: MarkupTool) -> some View {
        Button {
            viewer.tool = viewer.tool == tool ? .select : tool
        } label: {
            Label(tool.title, systemImage: tool.systemImage)
                .frame(width: 26, height: 22)
        }
        .background(viewer.tool == tool ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .help(tool.title)
        .accessibilityAddTraits(viewer.tool == tool ? .isSelected : [])
    }

    /// A button for the most recently used tool of a family, with a menu for the others.
    private func toolGroup(_ tools: [MarkupTool], last: Binding<MarkupTool>, handledByAction: @escaping () -> Bool) -> some View {
        let current = last.wrappedValue
        return Menu {
            ForEach(tools) { tool in
                Button {
                    last.wrappedValue = tool
                    viewer.tool = tool
                } label: {
                    Label(tool.title, systemImage: tool.systemImage)
                }
            }
        } label: {
            Label(current.title, systemImage: current.systemImage)
        } primaryAction: {
            if !handledByAction() { viewer.tool = viewer.tool == current ? .select : current }
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(tools.contains(viewer.tool) ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .help(current.title)
    }

    private var stampMenu: some View {
        Menu {
            ForEach(StandardStamp.allCases) { stamp in
                Button(stamp.title) { place(stampText: stamp.text, color: stamp.color) }
            }
            Divider()
            Button("Custom…") {
                customStampText = ""
                asksForStampText = true
            }
        } label: {
            Label("Stamp", systemImage: "seal")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Stamp")
    }

    private func place(stampText text: String, color: PDFColor) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Longer words get a wider stamp, so the letters stay about the same size.
        let aspect = max(3.2, Double(trimmed.count) * 0.46)
        viewer.placeStamp(.text(trimmed), width: aspect * 44, aspectRatio: aspect, color: color, name: String(localized: "Add Stamp"))
    }
}

/// Color, line width and text size, for the selected annotation or for the next one a tool makes.
struct StyleControls: View {
    @Bindable var viewer: ViewerModel

    private var kind: Annotation.Kind? {
        if let annotation = viewer.selectedAnnotation { return annotation.kind }
        switch viewer.tool {
        case .select: return nil
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        case .note: return .note
        case .text: return .freeText
        case .rectangle: return .square
        case .ellipse: return .circle
        case .line, .arrow: return .line
        case .draw: return .ink
        case .link: return .link
        }
    }

    var body: some View {
        if let kind, kind != .link, kind != .other {
            ColorPicker("Color", selection: color, supportsOpacity: false)
                .labelsHidden()
                .help("Color")
            if [.square, .circle, .line, .ink].contains(kind) {
                Menu {
                    Picker("Line Width", selection: lineWidth) {
                        ForEach([1.0, 2, 3, 5, 8, 12], id: \.self) { width in
                            Text("\(Int(width)) pt").tag(width)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Line Width", systemImage: "lineweight")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Line Width")
            }
            if kind == .freeText {
                Menu {
                    Picker("Text Size", selection: fontSize) {
                        ForEach([10.0, 12, 14, 18, 24, 36, 48], id: \.self) { size in
                            Text("\(Int(size)) pt").tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Text Size", systemImage: "textformat.size")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Text Size")
            }
        }
    }

    private var toolStyle: MarkupStyle { viewer.style(for: viewer.tool) }

    private var color: Binding<Color> {
        Binding(
            get: { (viewer.selectedAnnotation?.color ?? toolStyle.color).color },
            set: { newValue in
                let color = PDFColor(newValue)
                if viewer.selectedAnnotation != nil {
                    viewer.updateSelection(String(localized: "Change Color"), coalescing: "color") { $0.color = color }
                } else {
                    viewer.styles[viewer.tool, default: .standard(for: viewer.tool)].color = color
                }
            }
        )
    }

    private var lineWidth: Binding<Double> {
        Binding(
            get: { viewer.selectedAnnotation?.lineWidth ?? toolStyle.lineWidth },
            set: { width in
                if viewer.selectedAnnotation != nil {
                    viewer.updateSelection(String(localized: "Change Line Width")) { $0.lineWidth = width }
                } else {
                    viewer.styles[viewer.tool, default: .standard(for: viewer.tool)].lineWidth = width
                }
            }
        )
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { viewer.selectedAnnotation?.fontSize ?? toolStyle.fontSize },
            set: { size in
                if viewer.selectedAnnotation != nil {
                    viewer.updateSelection(String(localized: "Change Text Size")) {
                        $0.fontSize = size
                        viewer.fitHeight(of: &$0)
                    }
                } else {
                    viewer.styles[viewer.tool, default: .standard(for: viewer.tool)].fontSize = size
                }
            }
        )
    }
}
