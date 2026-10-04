import SheafKit
import SwiftUI

/// The row of editing tools shown under the toolbar while changing what pages draw.
struct EditBar: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        // An overlay on a bar of fixed height, for the same reason as the markup bar.
        Rectangle()
            .fill(.bar)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { tools }
            .overlay(alignment: .trailing) {
                Button("Done") { viewer.isContentEditing = false }
                    .padding(.trailing, 12)
            }
            .clipped()
    }

    private var tools: some View {
        HStack(spacing: 4) {
            toolButton(.select)
            toolButton(.text)
            Button {
                viewer.choosePictureToAdd()
            } label: {
                Label("Picture", systemImage: "photo").frame(width: 26, height: 22)
            }
            .help("Add a picture to the page")

            separator

            Button {
                viewer.showReplace()
            } label: {
                Label("Find and Replace", systemImage: "text.magnifyingglass").frame(width: 26, height: 22)
            }
            .help("Find and replace text")

            separator

            toolButton(.redact)
            Menu {
                ForEach(RedactionPattern.allCases) { pattern in
                    Button(pattern.title) { viewer.markForRedaction(pattern) }
                }
                Divider()
                Button("Search Results") { viewer.markMatchesForRedaction() }
                    .disabled(viewer.textMatches.isEmpty)
            } label: {
                Label("Find to Redact", systemImage: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Mark every place a kind of text is found")

            if viewer.redactionMarkCount > 0 {
                Toggle(isOn: $viewer.previewsRedactions) {
                    Label("Preview", systemImage: "eye").frame(width: 26, height: 22)
                }
                .toggleStyle(.button)
                .help("Show the marks as they will look once applied")

                Button("Apply \(viewer.redactionMarkCount)…") { viewer.isApplyRedactionsConfirmationPresented = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .labelStyle(.titleOnly)
                    .help("Remove what is under the marks for good")
            }

            if viewer.isFindingText {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 6)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .fixedSize()
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    private func toolButton(_ tool: EditTool) -> some View {
        Button {
            viewer.editTool = viewer.editTool == tool ? .select : tool
        } label: {
            Label(tool.title, systemImage: tool.systemImage).frame(width: 26, height: 22)
        }
        .background(viewer.editTool == tool ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .help(tool.help)
        .accessibilityAddTraits(viewer.editTool == tool ? .isSelected : [])
    }
}

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
