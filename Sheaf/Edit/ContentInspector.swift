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
                    LabeledContent("Style") {
                        ControlGroup {
                            Toggle("Bold", systemImage: "bold", isOn: style(bold: true))
                                .help("Bold")
                            Toggle("Italic", systemImage: "italic", isOn: style(bold: false))
                                .help("Italic")
                        }
                        .labelStyle(.iconOnly)
                        .fixedSize()
                    }
                }
                Section("Paragraph") {
                    LabeledContent("Alignment") {
                        Picker("Alignment", selection: alignment) {
                            ForEach(Self.alignments, id: \.self) { alignment in
                                Label(Self.title(alignment), systemImage: Self.symbol(alignment)).tag(alignment)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if block.lines.count > 1 {
                        spacingRow("Line Spacing", value: leading, range: lineSpacingRange)
                        spacingRow("Before Paragraph", value: paragraphGap, range: 0...max(lineSpacingRange.upperBound - block.leading, 0.5))
                    }
                }
                Section("Arrange") {
                    ArrangeControls(viewer: viewer)
                }
                Section {
                    ActionRow("Edit Text", systemImage: "character.cursor.ibeam") { viewer.beginEditing(block, pageIndex: pageIndex) }
                    ActionRow("Duplicate", systemImage: "plus.square.on.square") { viewer.duplicateContentSelection() }
                    ActionRow("Delete", systemImage: "trash", role: .destructive) { viewer.deleteContentSelection() }
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

    private static let alignments: [TextBlock.Alignment] = [.left, .center, .right, .justified]

    private static func title(_ alignment: TextBlock.Alignment) -> String {
        switch alignment {
        case .left: String(localized: "Align Left")
        case .center: String(localized: "Center")
        case .right: String(localized: "Align Right")
        case .justified: String(localized: "Justify")
        }
    }

    private static func symbol(_ alignment: TextBlock.Alignment) -> String {
        switch alignment {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        }
    }

    /// How the block's lines sit. A single line says nothing by itself, so it is read
    /// against the page's column, the box Center and Align Right put it in.
    private var shownAlignment: TextBlock.Alignment {
        guard block.lines.count == 1, let column = viewer.content(ofPage: pageIndex)?.column else { return block.alignment }
        let right = block.frame.x + block.frame.width
        if block.frame.x > column.left + 1, abs(block.frame.x + block.frame.width / 2 - (column.left + column.right) / 2) < 1.5 { return .center }
        if block.frame.x > column.left + 1, abs(right - column.right) < 1.5 { return .right }
        return .left
    }

    private var alignment: Binding<TextBlock.Alignment> {
        Binding(
            get: { shownAlignment },
            set: { alignment in
                guard alignment != shownAlignment else { return }
                viewer.restyleSelectedBlock(String(localized: "Change Alignment"), TextRestyle(alignment: alignment))
            }
        )
    }

    /// Whether most of the block's letters are bold, or italic.
    private func isStyled(bold: Bool) -> Bool {
        let glyphs = block.lines.flatMap(\.glyphs).filter { !$0.text.allSatisfy(\.isWhitespace) }
        return glyphs.filter { bold ? $0.isBold : $0.isItalic }.count * 2 > glyphs.count
    }

    private func style(bold: Bool) -> Binding<Bool> {
        Binding(
            get: { isStyled(bold: bold) },
            set: { on in
                viewer.restyleSelectedBlock(
                    bold ? String(localized: "Change to Bold") : String(localized: "Change to Italic"),
                    bold ? TextRestyle(isBold: on) : TextRestyle(isItalic: on)
                )
            }
        )
    }

    /// Lines further apart than this no longer read as one paragraph, on the page or to Sheaf.
    private var lineSpacingRange: ClosedRange<Double> {
        let size = block.fontSize
        return (size * 0.8).rounded()...max((size * 1.7).rounded(.down), (size * 0.8).rounded() + 1)
    }

    private var leading: Binding<Double> {
        Binding(
            get: { (block.leading * 2).rounded() / 2 },
            set: { value in
                let value = min(max(value, lineSpacingRange.lowerBound), lineSpacingRange.upperBound)
                guard abs(value - block.leading) > 0.05 else { return }
                viewer.restyleSelectedBlock(String(localized: "Change Line Spacing"), coalescing: "line-spacing", TextRestyle(leading: value))
            }
        )
    }

    private var paragraphGap: Binding<Double> {
        Binding(
            get: { (block.paragraphGap * 2).rounded() / 2 },
            set: { value in
                let value = max(value, 0)
                guard abs(value - block.paragraphGap) > 0.05 else { return }
                viewer.restyleSelectedBlock(String(localized: "Change Paragraph Spacing"), coalescing: "paragraph-spacing", TextRestyle(paragraphGap: value))
            }
        )
    }

    private func spacingRow(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper(title, value: value, in: range, step: 0.5)
                    .labelsHidden()
                Text("pt").foregroundStyle(.secondary)
            }
        }
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
                    PictureAdjustmentControls(viewer: viewer)
                    description
                    Section {
                        ActionRow("Duplicate", systemImage: "plus.square.on.square") { viewer.duplicateContentSelection() }
                        ActionRow("Delete", systemImage: "trash", role: .destructive) { viewer.deleteContentSelection() }
                    }
                } else {
                    description
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
            ActionRow("Done", systemImage: "checkmark") { viewer.endMaskEditing(commit: true) }
            ActionRow("Reset Mask", systemImage: "arrow.counterclockwise") { viewer.resetMask() }
            ActionRow("Cancel", systemImage: "xmark") { viewer.endMaskEditing(commit: false) }
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
                ActionRow("Replace…", systemImage: "photo.on.rectangle") { viewer.chooseReplacementPicture() }
                ActionRow("Edit Mask", systemImage: "crop") { viewer.beginMaskEditing() }
                if image.shownPart != nil {
                    ActionRow("Reset Mask", systemImage: "arrow.counterclockwise") { viewer.resetMask() }
                }
                ActionRow("Remove Background", systemImage: "person.and.background.dotted", isWorking: viewer.isRemovingBackground) { viewer.removeBackgroundOfSelectedPicture() }
                    .disabled(viewer.isRemovingBackground)
                working("Auto Crop", systemImage: "viewfinder", while: .cropping) { viewer.autoCropSelectedPicture() }
                    .help("Mask the picture down to the part that matters")
                if viewer.offersSuperResolution {
                    ActionRow("Super Resolution", systemImage: "arrow.up.left.and.arrow.down.right", isWorking: viewer.pictureWork == .enlarging) { viewer.enlargeSelectedPicture() }
                        .disabled(viewer.pictureWork != nil)
                        .help("Give the picture four times the pixels, sharper, in the same place")
                    if case .downloading(let fraction) = viewer.pictureWork {
                        ProgressView(value: fraction)
                    }
                }
            }
        }
    }

    /// What Apple Intelligence says the picture shows, once asked.
    @ViewBuilder private var description: some View {
        if viewer.canDescribePictures {
            Section("Description") {
                if let description = viewer.selectedPictureDescription {
                    Text(description)
                        .textSelection(.enabled)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 14) {
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(description, forType: .string)
                        }
                        .help("Copy the description")
                        Button("Add as Note", systemImage: "note.text.badge.plus") { viewer.addNote(with: description, heading: String(localized: "Picture description by Apple Intelligence")) }
                            .help("Put the description on this page as a note")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                }
                working(viewer.selectedPictureDescription == nil ? "Describe" : "Describe Again", systemImage: "text.below.photo", while: .describing) { viewer.describeSelectedPicture() }
                    .help("Have Apple Intelligence say what the picture shows")
            }
        }
    }

    /// A button for something that takes a moment, with a spinner beside it while it runs.
    private func working(_ title: LocalizedStringKey, systemImage: String, while work: PictureWork, action: @escaping () -> Void) -> some View {
        ActionRow(title, systemImage: systemImage, isWorking: viewer.pictureWork == work, action: action)
            .disabled(viewer.pictureWork != nil)
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
            LabeledContent("Rotate") {
                HStack(spacing: 6) {
                    RotationKnob(angle: image.placement.rotation) { viewer.setSelectedPictureAngle($0) }
                    measure("Angle", .angle)
                    Text(verbatim: "°").foregroundStyle(.secondary)
                    ControlGroup {
                        Button("Rotate Left", systemImage: "rotate.left") { viewer.rotateSelectedPicture(by: 90) }
                            .help("Rotate Left")
                        Button("Rotate Right", systemImage: "rotate.right") { viewer.rotateSelectedPicture(by: -90) }
                            .help("Rotate Right")
                    }
                    .labelStyle(.iconOnly)
                    .fixedSize()
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
