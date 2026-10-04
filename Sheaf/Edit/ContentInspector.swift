import AppKit
import SheafKit
import SwiftUI

/// The Format panel for a block of the page's own text.
struct TextBlockInspector: View {
    let viewer: ViewerModel
    let block: TextBlock
    let pageIndex: Int

    var body: some View {
        Form {
            if block.isEditable {
                Section("Text") {
                    Picker("Font", selection: font) {
                        Text(original).tag("")
                        Divider()
                        ForEach(ToolFont.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    LabeledContent("Size") {
                        HStack(spacing: 6) {
                            TextField("Size", value: size, format: .number.precision(.fractionLength(0...1)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                            Stepper("Size", value: size, in: 4...144, step: 1)
                                .labelsHidden()
                            Text("pt").foregroundStyle(.secondary)
                        }
                    }
                    ColorPicker("Color", selection: color, supportsOpacity: false)
                }
                Section("Arrange") {
                    ArrangeControls(viewer: viewer)
                }
                Section {
                    Button("Edit Text") { viewer.beginEditing(block, pageIndex: pageIndex) }
                    Button("Duplicate") { viewer.duplicateContentSelection() }
                    Button("Delete", role: .destructive) { viewer.deleteContentSelection() }
                } footer: {
                    Text("Double-click the text to type in it. What you type uses the document's own font where it has the letters, and the closest installed font where it does not.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Section {
                    LabeledContent("Font", value: original)
                    LabeledContent("Size", value: "\(block.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                } footer: {
                    Text("This text can be read and copied but not changed here. It is turned, drawn as part of a repeated element, or set in a font whose letters cannot be told apart reliably.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The document's name for the font, without the tag a partly included font carries.
    private var original: String {
        let name = block.fontName.split(separator: "+").last.map(String.init) ?? block.fontName
        return name.isEmpty ? String(localized: "Original Font") : name
    }

    private var font: Binding<String> {
        Binding(
            get: { "" },
            set: { name in
                guard !name.isEmpty else { return }
                viewer.restyleSelectedBlock(String(localized: "Change Font"), TextRestyle(fontName: name))
            }
        )
    }

    private var size: Binding<Double> {
        Binding(
            get: { (block.fontSize * 10).rounded() / 10 },
            set: { size in
                let size = min(max(size, 4), 144)
                guard abs(size - block.fontSize) > 0.05 else { return }
                viewer.restyleSelectedBlock(String(localized: "Change Text Size"), coalescing: "text-size", TextRestyle(fontSize: size))
            }
        )
    }

    private var color: Binding<Color> {
        Binding(
            get: { block.color.color },
            set: { color in
                let color = PDFColor(color)
                guard color != block.color else { return }
                viewer.restyleSelectedBlock(String(localized: "Change Color"), coalescing: "text-color", TextRestyle(color: color))
            }
        )
    }
}

/// The stacking order and lining up of the selected text or picture: the Back, Front,
/// Backward and Forward buttons and the Align menu of Pages' Arrange panel.
struct ArrangeControls: View {
    let viewer: ViewerModel

    var body: some View {
        let moves = viewer.stackingMoves
        LabeledContent("Order") {
            ControlGroup {
                ForEach([StackingMove.toBack, .backward, .forward, .toFront], id: \.self) { move in
                    Button(move.title, systemImage: move.systemImage) { viewer.restackSelection(move) }
                        .disabled(!moves.contains(move))
                        .help(move.title)
                }
            }
            .labelStyle(.iconOnly)
            .fixedSize()
        }
        LabeledContent("Align") {
            Menu("On Page") {
                ForEach(PageAlignment.allCases) { alignment in
                    if alignment == .top { Divider() }
                    Button(alignment.title, systemImage: alignment.systemImage) { viewer.alignSelection(alignment) }
                }
            }
            .fixedSize()
        }
    }
}

/// The Format panel for a picture on a page.
struct PictureInspector: View {
    let viewer: ViewerModel
    let image: PageImage
    let pageIndex: Int
    /// Whether changing one side of a picture changes the other to match.
    @AppStorage(Preferences.pictureKeepsProportions) private var keepsProportions = true
    /// The slider's place while it is dragged. The picture changes when it is let go.
    @State private var opacity = 1.0

    var body: some View {
        Form {
            if viewer.maskEdit != nil {
                mask
            } else {
                picture
                if image.isEditable {
                    arrange
                    Section {
                        Button("Duplicate") { viewer.duplicateContentSelection() }
                        Button("Delete", role: .destructive) { viewer.deleteContentSelection() }
                    }
                } else {
                    Section {
                    } footer: {
                        Text("This picture is slanted or is part of a repeated element, so it cannot be changed here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: image.opacity, initial: true) { opacity = image.opacity }
    }

    /// Shown while the mask is being changed.
    @ViewBuilder private var mask: some View {
        Section {
            Button("Done") { viewer.endMaskEditing(commit: true) }
            Button("Reset Mask") { viewer.resetMask() }
            Button("Cancel") { viewer.endMaskEditing(commit: false) }
        } header: {
            Text("Mask")
        } footer: {
            Text("Drag the handles to choose the part of the picture that shows, or drag inside to move it over the picture. The whole picture stays in the document.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var picture: some View {
        Section("Picture") {
            if image.pixelWidth > 0, image.pixelHeight > 0 {
                LabeledContent("Pixels", value: "\(image.pixelWidth) × \(image.pixelHeight)")
                LabeledContent("Resolution", value: "\(resolution) ppi")
            }
            if image.isEditable {
                // The slider gets a row of its own, as in Pages: the word is long in some languages.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text(opacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $opacity, in: 0...1) { isEditing in
                        if !isEditing { viewer.setSelectedPictureOpacity((opacity * 100).rounded() / 100) }
                    }
                    .accessibilityLabel("Opacity")
                }
            }
        }
        if image.isEditable {
            Section {
                Button("Replace…") { viewer.chooseReplacementPicture() }
                Button("Edit Mask") { viewer.beginMaskEditing() }
                if image.shownPart != nil {
                    Button("Reset Mask") { viewer.resetMask() }
                }
                HStack {
                    Button("Remove Background") { viewer.removeBackgroundOfSelectedPicture() }
                        .disabled(viewer.isRemovingBackground)
                    if viewer.isRemovingBackground {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder private var arrange: some View {
        Section("Arrange") {
            ArrangeControls(viewer: viewer)
            LabeledContent("Size") {
                HStack(spacing: 6) {
                    measure("Width", .width)
                    Text("×").foregroundStyle(.secondary)
                    measure("Height", .height)
                    Text("pt").foregroundStyle(.secondary)
                }
            }
            Toggle("Constrain proportions", isOn: $keepsProportions)
            LabeledContent("Position") {
                HStack(spacing: 6) {
                    measure("X", .x)
                    measure("Y", .y)
                    Text("pt").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Angle") {
                HStack(spacing: 6) {
                    measure("Angle", .angle)
                    Text(verbatim: "°").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Flip") {
                ControlGroup {
                    Button("Flip Horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { viewer.flipSelectedPicture(horizontally: true) }
                        .help("Flip Horizontally")
                    Button("Flip Vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { viewer.flipSelectedPicture(horizontally: false) }
                        .help("Flip Vertically")
                }
                .labelStyle(.iconOnly)
                .fixedSize()
            }
        }
    }

    /// How finely the picture is shown at its size on the page.
    private var resolution: Int {
        // Of the whole picture, not just the part a mask lets show.
        let width = image.isEditable ? image.unmaskedPlacement.width : image.frame.width
        guard width > 0 else { return 0 }
        return Int((Double(image.pixelWidth) / (width / 72)).rounded())
    }

    private enum Measure {
        case width, height, x, y, angle
    }

    /// One number of where the picture sits. Changing the width or height keeps the
    /// proportions when asked to. The size is the picture's own, along its sides; the position is that
    /// of the box around it, measured from the top left of the page as people expect.
    private func measure(_ title: LocalizedStringKey, _ measure: Measure) -> some View {
        let pageHeight = viewer.content(ofPage: pageIndex)?.geometry.displaySize.height ?? 0
        func shown(_ placement: ImagePlacement) -> Double {
            switch measure {
            case .width: placement.width.rounded()
            case .height: placement.height.rounded()
            case .x: placement.frame.x.rounded()
            case .y: (pageHeight - placement.frame.y - placement.frame.height).rounded()
            case .angle: (placement.rotation * 10).rounded() / 10
            }
        }
        return TextField(title, value: Binding(
            get: { shown(image.placement) },
            set: { entered in
                var placement = image.placement
                let old = shown(placement)
                guard entered != old, entered.isFinite else { return }
                switch measure {
                case .width:
                    guard placement.width > 0 else { return }
                    if keepsProportions { placement.height *= max(entered, 4) / placement.width }
                    placement.width = max(entered, 4)
                case .height:
                    guard placement.height > 0 else { return }
                    if keepsProportions { placement.width *= max(entered, 4) / placement.height }
                    placement.height = max(entered, 4)
                case .x: placement.center.x += entered - old
                case .y: placement.center.y -= entered - old
                case .angle:
                    placement.rotation = entered.truncatingRemainder(dividingBy: 360)
                    if placement.rotation < 0 { placement.rotation += 360 }
                }
                let id = image.id
                viewer.changeContent(String(localized: "Change Picture"), pageIndex: pageIndex, following: placement.frame) {
                    try $0.setImagePlacement(placement, ofImage: id, onPageAt: pageIndex)
                }
            }
        ), format: .number.precision(.fractionLength(measure == .angle ? 0...1 : 0...0)))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            .accessibilityLabel(title)
    }
}

/// The Format panel while the text tool is out: how new text will look.
struct NewTextInspector: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        Form {
            Section("New Text") {
                Picker("Font", selection: $viewer.newTextStyle.fontName) {
                    ForEach(ToolFont.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Size") {
                    HStack(spacing: 6) {
                        TextField("Size", value: $viewer.newTextStyle.fontSize, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                        Stepper("Size", value: $viewer.newTextStyle.fontSize, in: 4...144, step: 1)
                            .labelsHidden()
                        Text("pt").foregroundStyle(.secondary)
                    }
                }
                ColorPicker("Color", selection: Binding(
                    get: { viewer.newTextStyle.color.color },
                    set: { viewer.newTextStyle.color = PDFColor($0) }
                ), supportsOpacity: false)
            }
        }
        .formStyle(.grouped)
    }
}
