import SheafKit
import SwiftUI

/// The table of contents. Entries are the document's bookmarks, and can be renamed or removed.
struct OutlineList: View {
    let viewer: ViewerModel
    @State private var selection: [Int]?
    @State private var renaming: OutlineRow?
    @State private var newTitle = ""

    var body: some View {
        let rows = Self.rows(of: viewer.outline, under: [])
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No Table of Contents", systemImage: "list.bullet.indent")
            } description: {
                Text("Bookmarks you add appear here.")
            } actions: {
                Button("Add Bookmark") { viewer.addBookmark() }
                    .disabled(viewer.sheafDocument?.isEditable != true)
            }
        } else {
            List(rows, children: \.children, selection: $selection) { row in
                Text(row.item.title)
                    .lineLimit(2)
                    .contextMenu {
                        Button("Rename…") {
                            newTitle = row.item.title
                            renaming = row
                        }
                        Button("Delete", role: .destructive) { viewer.deleteBookmark(at: row.id) }
                    }
            }
            .onChange(of: selection) { _, path in
                if let path, let row = Self.find(path, in: rows) { viewer.go(to: row.item) }
            }
            .alert("Rename Bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Rename") {
                    if let renaming, !newTitle.isEmpty { viewer.renameBookmark(at: renaming.id, to: newTitle) }
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    /// An entry, identified by its position so that the list keeps its place when the
    /// outline is read again after an edit.
    struct OutlineRow: Identifiable {
        let id: [Int]
        let item: OutlineItem
        let children: [OutlineRow]?
    }

    private static func rows(of items: [OutlineItem], under path: [Int]) -> [OutlineRow] {
        items.enumerated().map { index, item in
            let own = path + [index]
            let children = rows(of: item.children, under: own)
            return OutlineRow(id: own, item: item, children: children.isEmpty ? nil : children)
        }
    }

    private static func find(_ path: [Int], in rows: [OutlineRow]) -> OutlineRow? {
        for row in rows {
            if row.id == path { return row }
            if path.starts(with: row.id), let found = find(path, in: row.children ?? []) { return found }
        }
        return nil
    }
}
