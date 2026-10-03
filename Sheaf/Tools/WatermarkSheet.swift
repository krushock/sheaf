import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// Tools > Watermark: text or a picture across pages, with a preview.
struct WatermarkSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String { case text, image }

    @State private var kind = Kind.text
    @State private var text = String(localized: "Confidential")
    @State private var font = ToolFont.helveticaBold
    @State private var fontSize = 72.0
    @State private var color = Color.gray
    @State private var image: StampImage?
    @State private var imageName = ""
    @State private var imageScale = 50.0
    @State private var opacity = 30.0
    @State private var rotation = 45.0
    @State private var position = Watermark.Position.center
    @State private var isTiled = false
    @State private var isBehind = false
    @State private var scope = PageScope()
    @State private var preview: CGImage?
    @State private var isChoosingImage = false
    @State private var imageFailed = false

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Picker("Watermark", selection: $kind) {
                    Text("Text").tag(Kind.text)
                    Text("Image").tag(Kind.image)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if kind == .text {
                    Section {
                        TextField("Text", text: $text, axis: .vertical)
                            .lineLimit(1...3)
                        Picker("Font", selection: $font) {
                            ForEach(ToolFont.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledSlider(title: "Size", value: $fontSize, range: 12...240)
                        ColorPicker("Color", selection: $color, supportsOpacity: false)
                    }
                } else {
                    Section {
                        LabeledContent("Image") {
                            HStack {
                                Text(imageName.isEmpty ? String(localized: "None") : imageName)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Choose…") { isChoosingImage = true }
                            }
                        }
                        LabeledSlider(title: "Width", value: $imageScale, range: 5...100) { "\(Int($0))%" }
                    }
                }

                Section {
                    LabeledSlider(title: "Opacity", value: $opacity, range: 5...100) { "\(Int($0))%" }
                    LabeledSlider(title: "Angle", value: $rotation, range: -90...90) { "\(Int($0))°" }
                    Toggle("Repeat Across the Page", isOn: $isTiled)
                    if !isTiled {
                        LabeledContent("Position") { PositionGrid(position: $position) }
                    }
                    Picker("Layer", selection: $isBehind) {
                        Text("Over the Page").tag(false)
                        Text("Under the Page").tag(true)
                    }
                }

                Section {
                    PageScopeRows(scope: $scope, pageCount: viewer.pageCount, currentPage: viewer.currentPageIndex)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)

            Divider()
            PagePreview(image: preview)
                .frame(width: 320)
        }
        .frame(height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Watermark", action: apply)
                    .disabled(watermark == nil || targets == nil)
            }
        }
        .task(id: PreviewKey(watermark: watermark, targets: targets)) {
            // Wait for a pause in a drag of a slider before drawing again.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let mark = watermark
            preview = viewer.preview(ofPage: viewer.previewPage(for: targets)) { editor, index in
                if let mark { try editor.addWatermark(mark, toPagesAt: [index]) }
            }
        }
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let decoded = try? StampImage(encodedImageData: data, maxPixelSize: 2400) {
                image = decoded
                imageName = url.lastPathComponent
            } else {
                imageFailed = true
            }
        }
        .alert("The picture could not be read.", isPresented: $imageFailed) {}
    }

    private struct PreviewKey: Equatable {
        var watermark: Watermark?
        var targets: [Int]?
    }

    private var targets: [Int]? {
        scope.indexes(pageCount: viewer.pageCount, current: viewer.currentPageIndex)
    }

    /// The watermark as set up, or `nil` while there is nothing to draw.
    private var watermark: Watermark? {
        var mark: Watermark
        switch kind {
        case .text:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            mark = Watermark(content: .text(text))
        case .image:
            guard let image else { return nil }
            mark = Watermark(content: .image(image))
        }
        mark.fontName = font.rawValue
        mark.fontSize = fontSize
        mark.color = PDFColor(color)
        mark.imageScale = imageScale / 100
        mark.opacity = opacity / 100
        mark.rotation = rotation
        mark.position = position
        mark.isTiled = isTiled
        mark.isBehindContent = isBehind
        return mark
    }

    private func apply() {
        guard let watermark, let targets else { return }
        viewer.sheafDocument?.apply(String(localized: "Add Watermark")) { editor, effect in
            try editor.addWatermark(watermark, toPagesAt: targets)
            effect.reloadsDisplay = true
            effect.pages = Set(targets)
        }
        dismiss()
    }
}

/// Nine dots for nine places on a page.
struct PositionGrid: View {
    @Binding var position: Watermark.Position

    private static let rows: [[Watermark.Position]] = [
        [.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight],
    ]

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { place in
                        Button {
                            position = place
                        } label: {
                            Image(systemName: position == place ? "circle.fill" : "circle")
                                .imageScale(.small)
                                .foregroundStyle(position == place ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                .frame(width: 18, height: 18)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.title(place))
                        .accessibilityAddTraits(position == place ? .isSelected : [])
                    }
                }
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }

    private static func title(_ position: Watermark.Position) -> String {
        switch position {
        case .topLeft: String(localized: "Top Left")
        case .top: String(localized: "Top")
        case .topRight: String(localized: "Top Right")
        case .left: String(localized: "Left")
        case .center: String(localized: "Center")
        case .right: String(localized: "Right")
        case .bottomLeft: String(localized: "Bottom Left")
        case .bottom: String(localized: "Bottom")
        case .bottomRight: String(localized: "Bottom Right")
        }
    }
}
