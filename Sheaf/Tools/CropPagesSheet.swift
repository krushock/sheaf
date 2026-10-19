import PDFKit
import SheafKit
import SwiftUI

/// Tools > Crop Pages: trims pages by distances from their edges, as Acrobat's Crop Pages
/// does. What is cut away is only hidden, and Show Whole Pages brings it back.
struct CropPagesSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var margins = Margins()
    @State private var scope = PageScope()
    @State private var preview: CGImage?
    @State private var foundNothing = false

    struct Margins: Equatable {
        var top = 0.0, left = 0.0, bottom = 0.0, right = 0.0

        var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section {
                    marginRow("Top", value: $margins.top)
                    marginRow("Bottom", value: $margins.bottom)
                    marginRow("Left", value: $margins.left)
                    marginRow("Right", value: $margins.right)
                } header: {
                    Text("Cut Away from the Edges")
                }
                Section {
                    ActionRow("Remove White Margins", systemImage: "crop") { fitToContent() }
                    ActionRow("Show Whole Pages", systemImage: "arrow.up.left.and.arrow.down.right") { showWholePages() }
                } footer: {
                    Text(foundNothing
                        ? "This page has nothing on it to crop to."
                        : "Cropping hides the edges of pages without deleting anything. Show Whole Pages brings back what was cut away.")
                        .font(.callout)
                        .foregroundStyle(foundNothing ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    PageScopeRows(scope: $scope, pageCount: viewer.pageCount, currentPage: viewer.currentPageIndex)
                }
            }
            .formStyle(.grouped)
            .frame(width: 360)

            Divider()
            PagePreview(image: preview)
                .frame(width: 320)
        }
        .frame(height: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Crop", action: apply)
                    .disabled(margins.isZero || targets == nil)
            }
        }
        .task(id: PreviewKey(margins: margins, targets: targets)) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let margins = margins
            preview = viewer.preview(ofPage: viewer.previewPage(for: targets)) { editor, index in
                guard !margins.isZero else { return }
                try editor.cropPage(at: index, top: margins.top, left: margins.left, bottom: margins.bottom, right: margins.right)
            }
        }
    }

    private struct PreviewKey: Equatable {
        var margins: Margins
        var targets: [Int]?
    }

    private var targets: [Int]? {
        scope.indexes(pageCount: viewer.pageCount, current: viewer.currentPageIndex)
    }

    private func marginRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Stepper(title, value: value, in: 0...2000, step: 6)
                    .labelsHidden()
                Text("pt").foregroundStyle(.secondary)
            }
        }
    }

    /// Margins that cut away the white around what the page shown in the preview has
    /// on it, leaving a little room.
    private func fitToContent() {
        let index = viewer.previewPage(for: targets)
        guard let page = viewer.document?.page(at: index), let found = Self.whiteMargins(of: page) else {
            foundNothing = true
            return
        }
        foundNothing = false
        let room = 6.0
        margins = Margins(top: max(found.top - room, 0), left: max(found.left - room, 0), bottom: max(found.bottom - room, 0), right: max(found.right - room, 0))
    }

    /// How far in from each edge of a page, as displayed, its drawing starts. `nil` for
    /// a blank page.
    static func whiteMargins(of page: PDFPage) -> Margins? {
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width >= 1, size.height >= 1,
              let image = page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Rows from the top, as the bitmap stores them.
        var minX = width, maxX = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where data[row * width + column] < 235 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        guard maxX >= minX, maxRow >= minRow else { return nil }
        let scaleX = size.width / Double(width), scaleY = size.height / Double(height)
        return Margins(
            top: Double(minRow) * scaleY, left: Double(minX) * scaleX,
            bottom: Double(height - 1 - maxRow) * scaleY, right: Double(width - 1 - maxX) * scaleX
        )
    }

    private func apply() {
        guard let targets else { return }
        let margins = margins
        viewer.sheafDocument?.apply(String(localized: "Crop Pages")) { editor, effect in
            for index in targets {
                let size = try editor.geometry(ofPageAt: index).displaySize
                // A page too small for the margins is left as it is.
                guard size.width - margins.left - margins.right >= 1, size.height - margins.top - margins.bottom >= 1 else { continue }
                try editor.cropPage(at: index, top: margins.top, left: margins.left, bottom: margins.bottom, right: margins.right)
                effect.pages.insert(index)
            }
            effect.reloadsDisplay = true
        }
        dismiss()
    }

    private func showWholePages() {
        guard let targets else { return }
        viewer.sheafDocument?.apply(String(localized: "Show Whole Pages")) { editor, effect in
            for index in targets { try editor.setCropBox(nil, forPageAt: index) }
            effect.pages = Set(targets)
            effect.reloadsDisplay = true
        }
        dismiss()
    }
}
