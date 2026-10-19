import SheafKit
import SwiftUI

/// Tools > Background: a color behind what pages show, as paper of that color would be.
struct BackgroundSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var color = Color(red: 1, green: 0.97, blue: 0.88)
    @State private var opacity = 100.0
    @State private var scope = PageScope()
    @State private var preview: CGImage?

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section {
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                    LabeledSlider(title: "Opacity", value: $opacity, range: 5...100) { "\(Int($0))%" }
                } footer: {
                    Text("The color goes under everything on the page. Scanned pages are pictures that cover the whole page, so on them it does not show.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    PageScopeRows(scope: $scope, pageCount: viewer.pageCount, currentPage: viewer.currentPageIndex)
                }
            }
            .formStyle(.grouped)
            .frame(width: 340)

            Divider()
            PagePreview(image: preview)
                .frame(width: 320)
        }
        .frame(height: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Background", action: apply)
                    .disabled(targets == nil)
            }
        }
        .task(id: PreviewKey(color: PDFColor(color), opacity: opacity, targets: targets)) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let fill = PDFColor(color), opacity = opacity / 100
            preview = viewer.preview(ofPage: viewer.previewPage(for: targets)) { editor, index in
                try editor.addBackground(fill, opacity: opacity, toPagesAt: [index])
            }
        }
    }

    private struct PreviewKey: Equatable {
        var color: PDFColor
        var opacity: Double
        var targets: [Int]?
    }

    private var targets: [Int]? {
        scope.indexes(pageCount: viewer.pageCount, current: viewer.currentPageIndex)
    }

    private func apply() {
        guard let targets else { return }
        let fill = PDFColor(color), opacity = opacity / 100
        viewer.sheafDocument?.apply(String(localized: "Add Background")) { editor, effect in
            try editor.addBackground(fill, opacity: opacity, toPagesAt: targets)
            effect.reloadsDisplay = true
            effect.pages = Set(targets)
        }
        dismiss()
    }
}
