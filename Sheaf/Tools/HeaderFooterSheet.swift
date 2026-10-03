import SheafKit
import SwiftUI

/// Tools > Header and Footer: page numbers and other lines at the top and bottom of pages.
struct HeaderFooterSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    private enum Slot: Hashable { case headerLeft, headerCenter, headerRight, footerLeft, footerCenter, footerRight }

    @State private var spec: HeaderFooter = {
        var spec = HeaderFooter()
        spec.footer.center = HeaderFooter.pageToken
        return spec
    }()
    @State private var font = ToolFont.helvetica
    @State private var color = Color.black
    @State private var scope = PageScope()
    @State private var preview: CGImage?
    @FocusState private var focus: Slot?
    @State private var lastFocus = Slot.footerCenter

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Header") {
                    row($spec.header, left: .headerLeft, center: .headerCenter, right: .headerRight)
                }
                Section("Footer") {
                    row($spec.footer, left: .footerLeft, center: .footerCenter, right: .footerRight)
                }
                Section {
                    LabeledContent("Insert") {
                        HStack(spacing: 6) {
                            insertButton("Page Number", HeaderFooter.pageToken)
                            insertButton("Page Count", HeaderFooter.pagesToken)
                            insertButton("Date", HeaderFooter.dateToken)
                            insertButton("Name", HeaderFooter.nameToken)
                        }
                        .controlSize(.small)
                    }
                } footer: {
                    Text("Inserted items show in braces and are filled in on each page.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    Picker("Font", selection: $font) {
                        ForEach(ToolFont.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledSlider(title: "Size", value: $spec.fontSize, range: 6...36)
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                    LabeledSlider(title: "From Top and Bottom", value: verticalMargin, range: 9...144)
                    LabeledSlider(title: "From the Sides", value: $spec.sideMargin, range: 9...144)
                    Stepper("Numbering Starts at \(spec.firstNumber)", value: $spec.firstNumber, in: 0...9999)
                }
                Section {
                    PageScopeRows(scope: $scope, pageCount: viewer.pageCount, currentPage: viewer.currentPageIndex)
                }
            }
            .formStyle(.grouped)
            .frame(width: 440)

            Divider()
            PagePreview(image: preview)
                .frame(width: 320)
        }
        .frame(height: 620)
        .onChange(of: focus) { _, slot in
            if let slot { lastFocus = slot }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: apply)
                    .disabled(finished.isEmpty || targets == nil)
            }
        }
        .task(id: PreviewKey(spec: finished, targets: targets)) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let spec = finished, name = viewer.documentName, date = Self.today
            let page = viewer.previewPage(for: targets)
            // The preview is of one page on its own, so its number is given by hand.
            var single = spec
            single.firstNumber = spec.firstNumber + page
            for keyPath in [\HeaderFooter.header, \HeaderFooter.footer] {
                for part in [\HeaderFooter.Row.left, \HeaderFooter.Row.center, \HeaderFooter.Row.right] {
                    single[keyPath: keyPath][keyPath: part] = single[keyPath: keyPath][keyPath: part]
                        .replacingOccurrences(of: HeaderFooter.pagesToken, with: "\(viewer.pageCount + spec.firstNumber - 1)")
                }
            }
            preview = viewer.preview(ofPage: page) { editor, index in
                try editor.addHeaderFooter(single, toPagesAt: [index], documentName: name, date: date)
            }
        }
    }

    private struct PreviewKey: Equatable {
        var spec: HeaderFooter
        var targets: [Int]?
    }

    private static var today: String {
        Date.now.formatted(date: .long, time: .omitted)
    }

    private var verticalMargin: Binding<Double> {
        Binding(get: { spec.topMargin }, set: {
            spec.topMargin = $0
            spec.bottomMargin = $0
        })
    }

    private func row(_ row: Binding<HeaderFooter.Row>, left: Slot, center: Slot, right: Slot) -> some View {
        HStack(spacing: 8) {
            TextField("Left", text: row.left, prompt: Text("Left"))
                .focused($focus, equals: left)
            TextField("Center", text: row.center, prompt: Text("Center"))
                .multilineTextAlignment(.center)
                .focused($focus, equals: center)
            TextField("Right", text: row.right, prompt: Text("Right"))
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: right)
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
    }

    private func insertButton(_ title: LocalizedStringKey, _ token: String) -> some View {
        Button(title) {
            // Into the field last typed in.
            switch lastFocus {
            case .headerLeft: spec.header.left += token
            case .headerCenter: spec.header.center += token
            case .headerRight: spec.header.right += token
            case .footerLeft: spec.footer.left += token
            case .footerCenter: spec.footer.center += token
            case .footerRight: spec.footer.right += token
            }
        }
    }

    private var targets: [Int]? {
        scope.indexes(pageCount: viewer.pageCount, current: viewer.currentPageIndex)
    }

    private var finished: HeaderFooter {
        var result = spec
        result.fontName = font.rawValue
        result.color = PDFColor(color)
        return result
    }

    private func apply() {
        guard let targets else { return }
        let spec = finished, name = viewer.documentName, date = Self.today
        viewer.sheafDocument?.apply(String(localized: "Add Header and Footer")) { editor, effect in
            try editor.addHeaderFooter(spec, toPagesAt: targets, documentName: name, date: date)
            effect.reloadsDisplay = true
            effect.pages = Set(targets)
        }
        dismiss()
    }
}
