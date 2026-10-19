import SheafKit
import SwiftUI

/// Find and replace, shown under the toolbar.
struct ReplaceBar: View {
    @Bindable var viewer: ViewerModel
    @FocusState private var focus: Field?

    private enum Field { case find, replace }

    var body: some View {
        Rectangle()
            .fill(.bar)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .overlay { fields.padding(.horizontal, 12) }
            .clipped()
            .onChange(of: viewer.replaceFocusRequests, initial: true) { focus = .find }
    }

    private var fields: some View {
        HStack(spacing: 8) {
            Menu {
                Toggle("Match Case", isOn: $viewer.replaceOptions.isCaseSensitive)
                Toggle("Whole Words", isOn: $viewer.replaceOptions.matchesWholeWords)
                Toggle("Regular Expression", isOn: $viewer.replaceOptions.isRegularExpression)
            } label: {
                Label("Options", systemImage: "magnifyingglass")
            }
            .menuStyle(.borderlessButton)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Search options")

            TextField("Find", text: $viewer.replaceQuery)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, idealWidth: 180, maxWidth: 240)
                .focused($focus, equals: .find)
                .onSubmit { viewer.selectMatch(offset: 1) }

            Text(status)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
                .lineLimit(1)

            ControlGroup {
                Button("Previous", systemImage: "chevron.left") { viewer.selectMatch(offset: -1) }
                Button("Next", systemImage: "chevron.right") { viewer.selectMatch(offset: 1) }
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            .disabled(viewer.textMatches.isEmpty)

            TextField("Replace", text: $viewer.replacement)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, idealWidth: 180, maxWidth: 240)
                .focused($focus, equals: .replace)
                .onSubmit { viewer.replaceCurrentMatch() }

            Button("Replace") { viewer.replaceCurrentMatch() }
                .disabled(viewer.currentMatch?.isReplaceable != true)
            Button("All") { viewer.replaceAllMatches() }
                .disabled(viewer.textMatches.isEmpty)
                .help("Replace every match in the document")

            Spacer(minLength: 0)

            Button("Done") { viewer.isReplaceVisible = false }
                .keyboardShortcut(.cancelAction)
        }
        .disabled(viewer.sheafDocument?.isEditable != true)
    }

    private var status: String {
        if viewer.replaceQuery.isEmpty { return "" }
        if viewer.isFindingText, viewer.textMatches.isEmpty { return String(localized: "Searching…") }
        if viewer.textMatches.isEmpty { return String(localized: "Not found") }
        if let index = viewer.currentMatchIndex { return String(localized: "\(index + 1) of \(viewer.textMatches.count)") }
        return String(localized: "\(viewer.textMatches.count) found")
    }
}
