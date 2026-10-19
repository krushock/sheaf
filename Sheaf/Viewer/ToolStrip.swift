import AppKit
import SheafKit
import SwiftUI

/// What is in hand: the tool chosen on the strip at the side of the pages. Each belongs to
/// one of the viewer's ways of working (marking up, changing the page's own text and
/// pictures, building a form), which taking it switches to.
enum ToolHand: Hashable {
    case pointer, edit, highlight, draw, shape, textBox, note, sign, link, redact, form
}

extension ViewerModel {
    var hand: ToolHand {
        if isFormEditing { return .form }
        if isContentEditing { return editTool == .redact ? .redact : .edit }
        guard isMarkupVisible else { return .pointer }
        switch tool {
        case .select: return isSignPanelShown ? .sign : .pointer
        case .highlight, .underline, .strikeOut: return .highlight
        case .draw: return .draw
        case .rectangle, .ellipse, .line, .arrow: return .shape
        case .text: return .textBox
        case .note: return .note
        case .link: return .link
        }
    }

    /// Takes a tool up. Taken again while in hand, it shows or hides its options.
    func take(_ wanted: ToolHand) {
        if hand == wanted, wanted != .pointer {
            withAnimation(.easeOut(duration: 0.15)) { isInspectorVisible.toggle() }
            return
        }
        isSignPanelShown = wanted == .sign
        switch wanted {
        case .pointer, .sign:
            isFormEditing = false
            isContentEditing = false
            isMarkupVisible = true
            tool = .select
        case .edit:
            isContentEditing = true
            editTool = .select
        case .redact:
            isContentEditing = true
            editTool = .redact
        case .form:
            isFormEditing = true
        case .highlight:
            isMarkupVisible = true
            // With text already selected, it is marked at once, as the bar of Preview does.
            if pdfView.currentSelection?.string?.isEmpty == false, let kind = lastTextMarkTool.textMarkupKind {
                tool = lastTextMarkTool
                applyTextMarkup(kind)
            } else {
                tool = lastTextMarkTool
            }
        case .draw: isMarkupVisible = true; tool = .draw
        case .shape: isMarkupVisible = true; tool = lastShapeTool
        case .textBox: isMarkupVisible = true; tool = .text
        case .note: isMarkupVisible = true; tool = .note
        case .link: isMarkupVisible = true; tool = .link
        }
        if wanted != .pointer { withAnimation(.easeOut(duration: 0.15)) { isInspectorVisible = true } }
    }

    /// Puts one of the standard stamps, or one with words of the person's own, on the page.
    func placeTextStamp(_ text: String, color: PDFColor) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let aspect = max(3.2, Double(trimmed.count) * 0.46)
        placeStamp(.text(trimmed), width: aspect * 44, aspectRatio: aspect, color: color, name: String(localized: "Add Stamp"))
    }

    /// Whether the panel beside the strip shows what is selected rather than the tool's options.
    var panelShowsSelection: Bool {
        selectedField != nil || contentSelection != nil || selectedAnnotation != nil || (isContentEditing && editTool == .text)
    }
}

/// The strip of tools down the side of the pages, and beside it the options of the tool in
/// hand or of what is selected, as Inkpage lays them out.
struct ToolStrip: View {
    @Bindable var viewer: ViewerModel
    /// How high the panel may be, so that in a low window its options scroll.
    let room: Double

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if viewer.toolsOnLeft { strip }
            if viewer.isInspectorVisible {
                panel
                    .transition(.opacity.combined(with: .move(edge: viewer.toolsOnLeft ? .leading : .trailing)))
            }
            if !viewer.toolsOnLeft { strip }
        }
        .environment(\.toolsOnLeft, viewer.toolsOnLeft)
        .animation(.easeOut(duration: 0.15), value: viewer.isInspectorVisible)
    }

    // MARK: The strip

    private var strip: some View {
        let hand = viewer.hand
        return VStack(spacing: 4) {
            grip
            button(viewer.isInspectorVisible != viewer.toolsOnLeft ? "chevron.right" : "chevron.left",
                   viewer.isInspectorVisible ? String(localized: "Hide Options") : String(localized: "Show Options"), active: false) {
                withAnimation(.easeOut(duration: 0.15)) { viewer.isInspectorVisible.toggle() }
            }
            button("cursorarrow", String(localized: "Select: text, and the notes and drawings on the page"), active: hand == .pointer) { viewer.take(.pointer) }
            button("character.cursor.ibeam", String(localized: "Edit the page's own text and pictures"), active: hand == .edit) { viewer.take(.edit) }
            separator
            button(viewer.lastTextMarkTool.systemImage, viewer.lastTextMarkTool.name, active: hand == .highlight) { viewer.take(.highlight) }
                .overlay(alignment: .bottomTrailing) { dot(viewer.style(for: viewer.lastTextMarkTool).color) }
            button("scribble", String(localized: "Draw"), active: hand == .draw) { viewer.take(.draw) }
                .overlay(alignment: .bottomTrailing) { dot(viewer.style(for: .draw).color) }
            button(viewer.lastShapeTool.systemImage, viewer.lastShapeTool.name, active: hand == .shape) { viewer.take(.shape) }
            button("character.textbox", String(localized: "Text Box"), active: hand == .textBox) { viewer.take(.textBox) }
            button("note.text", String(localized: "Note"), active: hand == .note) { viewer.take(.note) }
            button("signature", String(localized: "Sign and Stamp"), active: hand == .sign) { viewer.take(.sign) }
            button("link", String(localized: "Link"), active: hand == .link) { viewer.take(.link) }
            separator
            button("rectangle.fill", String(localized: "Redact: remove text and pictures for good"), active: hand == .redact) { viewer.take(.redact) }
            button("rectangle.and.pencil.and.ellipsis", String(localized: "Form fields"), active: hand == .form) { viewer.take(.form) }
            separator
            let undo = viewer.sheafDocument?.undoManager
            // Read so that the buttons are looked at again after each change.
            let _ = viewer.sheafDocument?.revision
            button("arrow.uturn.backward", String(localized: "Undo (⌘Z)"), active: false) { undo?.undo() }
                .disabled(undo?.canUndo != true)
            button("arrow.uturn.forward", String(localized: "Redo (⇧⌘Z)"), active: false) { undo?.redo() }
                .disabled(undo?.canRedo != true)
            insertMenu
        }
        .padding(6)
        .disabled(viewer.sheafDocument?.isEditable != true)
        .floatingGlass()
    }

    private var separator: some View {
        Divider().frame(width: 22).padding(.vertical, 3)
    }

    /// The grip at the head of the strip: dragged across the window, it takes the tools to the other side.
    private var grip: some View {
        Image(systemName: "circle.grid.2x2.fill")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 16)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
                if drag.translation.width < -120 { withAnimation { viewer.toolsOnLeft = true } }
                else if drag.translation.width > 120 { withAnimation { viewer.toolsOnLeft = false } }
            })
            .accessibilityElement()
            .accessibilityLabel(viewer.toolsOnLeft ? "Move Tools to the Right" : "Move Tools to the Left")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation { viewer.toolsOnLeft.toggle() } }
            .contextMenu {
                Button(viewer.toolsOnLeft ? "Move Tools to the Right" : "Move Tools to the Left") { withAnimation { viewer.toolsOnLeft.toggle() } }
            }
            .named(String(localized: "Drag across to move the tools to the other side"))
    }

    private var insertMenu: some View {
        Menu {
            Button("Picture…", systemImage: "photo") { viewer.choosePictureToAdd() }
            if viewer.offersImagePlayground {
                Button("Image Playground…", systemImage: "apple.image.playground") { viewer.openImagePlayground() }
            }
            Button("Text", systemImage: "textformat") {
                viewer.take(.edit)
                viewer.editTool = .text
            }
            Divider()
            Button("Blank Page", systemImage: "doc") { viewer.insertBlankPage(at: viewer.currentPageIndex + 1) }
            Button("Pages from File…", systemImage: "doc.badge.plus") { viewer.chooseFilesToInsert() }
            Button("Pages from Scanner…", systemImage: "scanner") { viewer.activeSheet = .scanner }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 34)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(radius: 12)
        .named(String(localized: "Insert a picture, text or pages"))
    }

    /// The colour a tool is set to, at the corner of its button.
    private func dot(_ color: PDFColor) -> some View {
        Circle().fill(color.color).frame(width: 8, height: 8)
            .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.5) }
            .padding(5)
            .allowsHitTesting(false)
    }

    private func button(_ symbol: String, _ help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 34)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 12)
        .named(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: The panel

    private var panel: some View {
        Group {
            if viewer.panelShowsSelection {
                // What is selected: the settings the Format panel had, grouped as before.
                // As high as its settings; in a low window they scroll.
                ViewThatFits(in: .vertical) {
                    InspectorView(viewer: viewer)
                        .scrollContentBackground(.hidden)
                        .fixedSize(horizontal: false, vertical: true)
                    InspectorView(viewer: viewer)
                        .scrollContentBackground(.hidden)
                }
                .frame(maxHeight: max(room, 220))
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .vertical) {
                    options.padding(16)
                    ScrollView(.vertical) { options.padding(16) }
                }
                .frame(maxHeight: max(room, 220))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 280)
        .floatingPanelGlass()
        #if DEBUG
        // For the scripted checks: how large the panel came out.
        .background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                if UserDefaults.standard.object(forKey: "SnapshotWindows") != nil { print("PANEL size \(size)") }
            }
        })
        #endif
    }

    @ViewBuilder private var options: some View {
        switch viewer.hand {
        case .pointer: PointerOptions(viewer: viewer)
        case .edit: EditOptions(viewer: viewer)
        case .highlight: TextMarkOptions(viewer: viewer)
        case .draw: LineOptions(viewer: viewer, tool: .draw, title: "Draw")
        case .shape: ShapeOptions(viewer: viewer)
        case .textBox: TextBoxOptions(viewer: viewer)
        case .note: NoteOptions(viewer: viewer)
        case .sign: SignOptions(viewer: viewer)
        case .link: Hint(title: "Link", text: "Drag over text or an area of the page to make a link, then choose where it goes.")
        case .redact: RedactOptions(viewer: viewer)
        case .form: FormOptions(viewer: viewer)
        }
    }
}

// MARK: - The options of each tool

/// A short explanation, for tools with nothing to set.
private struct Hint: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeading(title)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The style a markup tool sets next, read and changed in one place.
private extension ViewerModel {
    func styleBinding<Value>(_ tool: MarkupTool, _ keyPath: WritableKeyPath<MarkupStyle, Value>) -> Binding<Value> {
        Binding(
            get: { self.style(for: tool)[keyPath: keyPath] },
            set: { self.styles[tool, default: .standard(for: tool)][keyPath: keyPath] = $0 }
        )
    }
}

private struct PointerOptions: View {
    let viewer: ViewerModel

    var body: some View {
        Hint(title: "Select", text: "Drag over text to select it. Click a note, a drawing or a stamp to select it, then move it, resize it or change it here.")
    }
}

private struct EditOptions: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeading("Edit", systemImage: "character.cursor.ibeam")
            Text("Double-click text on the page to type in it. Click text or a picture to select it, then drag it, or change it here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                wide("Add Text", "textformat") { viewer.editTool = .text }
                wide("Add Picture…", "photo") { viewer.choosePictureToAdd() }
                if viewer.offersImagePlayground {
                    wide("Image Playground…", "apple.image.playground") { viewer.openImagePlayground() }
                }
                wide("Find and Replace", "text.magnifyingglass") { viewer.showReplace() }
            }
        }
    }

    private func wide(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 9))
        .hoverHighlight()
    }
}

/// A choice of a few, as icon buttons in a row: the one in force filled.
private struct IconChoice<Value: Hashable>: View {
    let choices: [(value: Value, title: String, symbol: String)]
    let chosen: Value
    let pick: (Value) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(choices, id: \.value) { choice in
                Button { pick(choice.value) } label: {
                    Image(systemName: choice.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .foregroundStyle(chosen == choice.value ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(chosen == choice.value ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverHighlight(radius: 10)
                .named(choice.title, above: true)
                .accessibilityAddTraits(chosen == choice.value ? .isSelected : [])
            }
        }
    }
}

private struct TextMarkOptions: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        let tool = viewer.lastTextMarkTool
        VStack(alignment: .leading, spacing: 14) {
            PanelHeading("Mark Text")
            IconChoice(choices: MarkupTool.textMarks.map { ($0, $0.name, $0.systemImage) }, chosen: tool) { picked in
                viewer.lastTextMarkTool = picked
                viewer.tool = picked
            }
            ColorSwatches(colors: tool == .highlight ? PDFColor.markers : PDFColor.swatches, chosen: viewer.style(for: tool).color) {
                viewer.styles[tool, default: .standard(for: tool)].color = $0
            }
            Text("Select text, and it is marked as you let go.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Colour, thickness and opacity, for drawing and for shapes.
private struct LineOptions: View {
    @Bindable var viewer: ViewerModel
    let tool: MarkupTool
    let title: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeading(title)
            ColorSwatches(colors: PDFColor.swatches, chosen: viewer.style(for: tool).color) {
                viewer.styles[tool, default: .standard(for: tool)].color = $0
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Thickness").font(.callout).foregroundStyle(.secondary)
                LevelSlider(value: viewer.styleBinding(tool, \.lineWidth), range: 1...20, label: String(localized: "Thickness"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Opacity").font(.callout).foregroundStyle(.secondary)
                LevelSlider(value: Binding(get: { viewer.style(for: tool).opacity * 100 }, set: { viewer.styles[tool, default: .standard(for: tool)].opacity = $0 / 100 }),
                            range: 10...100, step: 10, label: String(localized: "Opacity"))
            }
        }
    }
}

private struct ShapeOptions: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        let tool = viewer.lastShapeTool
        VStack(alignment: .leading, spacing: 14) {
            IconChoice(choices: MarkupTool.shapes.map { ($0, $0.name, $0.systemImage) }, chosen: tool) { picked in
                viewer.lastShapeTool = picked
                viewer.tool = picked
            }
            LineOptions(viewer: viewer, tool: tool, title: tool.title)
            if tool == .rectangle || tool == .ellipse {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fill").font(.callout).foregroundStyle(.secondary)
                    // With "none" first, one colour fewer keeps the rows even.
                    ColorSwatches(colors: Array(PDFColor.swatches.dropLast(1)), chosen: viewer.style(for: tool).fillColor, none: {
                        viewer.styles[tool, default: .standard(for: tool)].fillColor = nil
                    }) { viewer.styles[tool, default: .standard(for: tool)].fillColor = $0 }
                }
            }
        }
    }
}

private struct TextBoxOptions: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeading("Text Box")
            ColorSwatches(colors: PDFColor.swatches, chosen: viewer.style(for: .text).color) {
                viewer.styles[.text, default: .standard(for: .text)].color = $0
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Size").font(.callout).foregroundStyle(.secondary)
                LevelSlider(value: viewer.styleBinding(.text, \.fontSize), range: 6...72, label: String(localized: "Text Size"))
            }
            Text("Click on the page where the text goes, or drag to make a box.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NoteOptions: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeading("Note")
            ColorSwatches(colors: PDFColor.markers, chosen: viewer.style(for: .note).color) {
                viewer.styles[.note, default: .standard(for: .note)].color = $0
            }
            Text("Click on the page where the note goes, then type.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SignOptions: View {
    @Bindable var viewer: ViewerModel
    @State private var asksForStampText = false
    @State private var customStampText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeading("Signatures", systemImage: "signature")
            SignaturePicker(viewer: viewer)
                .padding(-12)
            PanelHeading("Stamps", systemImage: "seal")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(StandardStamp.allCases) { stamp in
                    Button { viewer.placeTextStamp(stamp.text, color: stamp.color) } label: {
                        Text(stamp.title)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(stamp.color.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(stamp.color.color.opacity(0.8), lineWidth: 1.5) }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(radius: 6)
                }
            }
            Button("Custom Stamp…") {
                customStampText = ""
                asksForStampText = true
            }
            .buttonStyle(.link)
        }
        .alert("Custom Stamp", isPresented: $asksForStampText) {
            TextField("Text", text: $customStampText)
            Button("Add") { viewer.placeTextStamp(customStampText, color: .red) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The text is shown in capitals inside a frame.")
        }
    }
}

private struct RedactOptions: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeading("Redact", systemImage: "rectangle.fill")
            Text("Drag over what to remove. Nothing is removed until you apply the marks.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Menu {
                ForEach(RedactionPattern.allCases) { pattern in
                    Button(pattern.title) { viewer.markForRedaction(pattern) }
                }
                Divider()
                Button("Search Results") { viewer.markMatchesForRedaction() }
                    .disabled(viewer.textMatches.isEmpty)
            } label: {
                Label("Find and Mark", systemImage: "wand.and.stars")
            }
            .fixedSize()
            if viewer.isFindingText { ProgressView().controlSize(.small) }
            if viewer.redactionMarkCount > 0 {
                Toggle("Preview Redactions", isOn: $viewer.previewsRedactions)
                HStack {
                    Button("Remove Marks") { viewer.removeRedactionMarks() }
                    Spacer()
                    Button("Apply \(viewer.redactionMarkCount)…") { viewer.isApplyRedactionsConfirmationPresented = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct FormOptions: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeading("Form Fields", systemImage: "rectangle.and.pencil.and.ellipsis")
            Text("Choose a kind of field and drag on the page where it goes. Click a field to change it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(FormTool.allCases) { tool in
                    Button { viewer.formTool = viewer.formTool == tool ? nil : tool } label: {
                        Label(tool.title, systemImage: tool.systemImage)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .foregroundStyle(viewer.formTool == tool ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(viewer.formTool == tool ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 9))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
            }
            Button("Detect Fields", systemImage: "wand.and.stars") { viewer.detectFields() }
                .help("Make fields from the boxes and lines drawn on this page")
        }
    }
}

/// The zoom, floating at the foot of the tools: larger, the zoom, smaller.
struct ZoomCapsule: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        VStack(spacing: 2) {
            step("plus", String(localized: "Zoom In")) { viewer.zoomIn() }
                .disabled(!viewer.canZoomIn)
            Menu {
                ForEach(ViewerModel.zoomSteps, id: \.self) { percent in
                    Button { viewer.setZoom(percent: percent) } label: { Text(Double(percent) / 100, format: .percent) }
                }
                Divider()
                Button("Fit Width") { viewer.zoomToFit() }
                Button("Fit Page") { viewer.zoomToFitPage() }
            } label: {
                Text(Double(viewer.zoomPercent) / 100, format: .percent)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight()
            .named(String(localized: "Zoom"))
            step("minus", String(localized: "Zoom Out")) { viewer.zoomOut() }
                .disabled(!viewer.canZoomOut)
        }
        .padding(6)
        .floatingGlass()
    }

    private func step(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 12)
        .named(help)
    }
}
