import PDFKit
import SheafKit
import SwiftUI

extension ViewerModel {
    /// The pages, out of some, that have no text to select: scans and photos.
    func pagesWithoutText(among indexes: [Int]) -> [Int] {
        guard let editor = sheafDocument?.editor else { return [] }
        return indexes.filter { (try? editor.hasText(onPageAt: $0)) == false }
    }

    /// Reads the text in pictures of pages and lays it over them, invisibly, so it can be
    /// searched, selected and copied.
    ///
    /// - Parameter progress: Called with the fraction done. Returns `false` to stop.
    /// - Returns: How many pages text was found on.
    func recognizeText(onPages indexes: [Int], progress: (Double) -> Bool) async -> Int {
        guard let sheafDocument, let document else { return 0 }
        var found: [Int: [RecognizedText]] = [:]
        for (position, index) in indexes.enumerated() {
            guard progress(Double(position) / Double(max(indexes.count, 1))) else { return 0 }
            guard let page = document.page(at: index) else { continue }
            // About 200 pixels per inch on a letter page, which is what the recognizer likes.
            let bounds = page.bounds(for: .cropBox)
            let scale = min(2400 / max(bounds.width, bounds.height, 1), 4)
            let turned = page.rotation % 180 != 0
            let size = CGSize(width: (turned ? bounds.height : bounds.width) * scale, height: (turned ? bounds.width : bounds.height) * scale)
            guard let image = page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let lines = await Task.detached(priority: .userInitiated) { TextRecognizer.recognize(in: image) }.value
            if !lines.isEmpty { found[index] = lines }
        }
        guard !found.isEmpty, progress(1) else { return 0 }
        let done = sheafDocument.apply(String(localized: "Recognize Text")) { editor, effect in
            for (index, lines) in found.sorted(by: { $0.key < $1.key }) {
                try editor.addTextLayer(lines, toPageAt: index)
                effect.pages.insert(index)
            }
            effect.reloadsDisplay = true
            return true
        } ?? false
        if done { show(sheafDocument) }
        return done ? found.count : 0
    }
}

/// Tools > Recognize Text.
struct RecognizeSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case choosing
        case working(Double)
        case done(Int)
    }

    @State private var scope = PageScope()
    @State private var phase = Phase.choosing
    @State private var stop = StopFlag()

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .choosing: choices
            case .working(let progress):
                ProgressView(value: progress) { Text("Reading the pages…") }
                    .padding(28)
            case .done(let count):
                message(
                    count > 0 ? "Text Recognized on \(count) Pages" : "No Text Was Found",
                    systemImage: count > 0 ? "text.viewfinder" : "questionmark.circle",
                    count > 0 ? "The text can now be searched, selected and copied. The pages look the same as before." : "The pages do not seem to show any writing."
                )
            }
        }
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                switch phase {
                case .choosing: Button("Cancel") { dismiss() }
                case .working: Button("Stop") { stop.set() }
                case .done: EmptyView()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                switch phase {
                case .choosing: Button("Recognize", action: start).disabled(targets.isEmpty)
                case .working: Button("Recognize") {}.disabled(true)
                case .done: Button("Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(phase != .choosing)
    }

    /// The pages in the chosen range that have no text yet.
    private var targets: [Int] {
        guard let chosen = scope.indexes(pageCount: viewer.pageCount, current: viewer.currentPageIndex) else { return [] }
        return viewer.pagesWithoutText(among: chosen)
    }

    private var choices: some View {
        Form {
            Section {
                PageScopeRows(scope: $scope, pageCount: viewer.pageCount, currentPage: viewer.currentPageIndex)
            } header: {
                Text("Recognize Text in Scanned Pages")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: LocalizedStringKey {
        let count = targets.count
        if count == 0 { return "Every page chosen already has text that can be selected, so there is nothing to recognize." }
        return "\(count) pages have no text to select. Their writing is read on this Mac and laid over them invisibly, so the pages look the same but can be searched and copied from."
    }

    private func message(_ title: LocalizedStringKey, systemImage: String, _ detail: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
            Text(title).font(.title3.bold())
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func start() {
        let pages = targets
        let stop = StopFlag()
        self.stop = stop
        phase = .working(0)
        Task {
            let count = await viewer.recognizeText(onPages: pages) { value in
                phase = .working(value)
                return !stop.isSet
            }
            if stop.isSet { dismiss() } else { phase = .done(count) }
        }
    }
}
