import SheafKit
import SwiftUI

/// The row of page tools shown above the grid of pages.
struct OrganizerBar: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        // An overlay on a bar of fixed height, for the same reason as the markup bar.
        Rectangle()
            .fill(.bar)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { tools }
            .overlay(alignment: .trailing) {
                Button("Done") { viewer.isOrganizing = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.trailing, 12)
            }
            .clipped()
    }

    private var tools: some View {
        let targets = viewer.targetPageIndexes
        return HStack(spacing: 4) {
            Menu {
                BlankPageMenu("Blank Page", viewer: viewer)
                Button("Pages from File…") { viewer.chooseFilesToInsert() }
                Button("Pages from Scanner…") { viewer.activeSheet = .scanner }
            } label: {
                Label("Insert", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Insert pages")

            Divider().frame(height: 18).padding(.horizontal, 4)

            Group {
                button("Rotate Left", "rotate.left") { viewer.rotatePages(targets, by: -90) }
                button("Rotate Right", "rotate.right") { viewer.rotatePages(targets, by: 90) }
                button("Duplicate", "plus.square.on.square") { viewer.duplicatePages(targets) }
                Menu {
                    Button("Down the Middle") { viewer.splitPagesInHalf(targets, direction: .vertical) }
                    Button("Across the Middle") { viewer.splitPagesInHalf(targets, direction: .horizontal) }
                } label: {
                    Label("Split in Half", systemImage: "rectangle.split.2x1")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Cut each selected page into two pages")
                button("Open as New Document", "arrow.up.forward.square") { viewer.extractPages(targets) }
            }
            .disabled(targets.isEmpty)

            button("Delete", "trash") { viewer.deletePages(targets) }
                .disabled(!viewer.canDeleteTargetPages)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .fixedSize()
        .disabled(!viewer.canEditPages)
    }

    private func button(_ title: LocalizedStringKey, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(width: 26, height: 22)
        }
        .help(title)
    }
}

/// The strip under the grid: what is selected, and how large the pages are drawn.
struct OrganizerStatusBar: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        HStack {
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Slider(value: $viewer.organizerPageSize, in: 90...320)
                .controlSize(.small)
                .frame(width: 120)
                .accessibilityLabel("Page size")
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.bar)
    }

    private var status: String {
        let picked = viewer.targetPageIndexes
        if picked.isEmpty { return String(localized: "\(viewer.pageCount) pages") }
        return String(localized: "\(picked.count) of \(viewer.pageCount) selected: \(PageRanges.description(of: picked))")
    }
}
