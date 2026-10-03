import PDFKit
import SwiftUI

struct SearchResultsList: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        if viewer.searchResults.isEmpty {
            if viewer.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: viewer.searchText)
            }
        } else {
            List(selection: $viewer.selectedSearchResultID) {
                Section {
                    ForEach(viewer.searchResults) { result in
                        SearchResultRow(result: result)
                    }
                } header: {
                    Text("\(viewer.searchResults.count) results")
                }
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Page \(result.pageIndex + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
            snippet
                .lineLimit(2)
        }
        .padding(.vertical, 1)
    }

    /// The match in bold with a few words of context on each side.
    private var snippet: Text {
        let match = result.selection.string ?? ""
        func context(extend: (PDFSelection) -> Void) -> String {
            guard let copy = result.selection.copy() as? PDFSelection else { return match }
            extend(copy)
            return (copy.string ?? match).split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        let leading = context { $0.extend(atStart: 18) }
        let trailing = context { $0.extend(atEnd: 60) }
        var before = leading.hasSuffix(match) ? String(leading.dropLast(match.count)) : ""
        // Start at a word boundary, and keep the match within the first line.
        if let space = before.firstIndex(of: " ") { before = String(before[before.index(after: space)...]) }
        let after = trailing.hasPrefix(match) ? String(trailing.dropFirst(match.count)) : ""
        var emphasized = AttributedString(match)
        emphasized.inlinePresentationIntent = .stronglyEmphasized
        return Text(AttributedString(before) + emphasized + AttributedString(after))
    }
}
