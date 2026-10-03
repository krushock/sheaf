import PDFKit
import SheafKit
import SwiftUI

/// Highlights, notes, drawings and their replies, page by page.
struct AnnotationList: View {
    @Bindable var viewer: ViewerModel
    @State private var replyingTo: AnnotationSelection?
    @State private var replyText = ""

    var body: some View {
        let groups = groups
        if groups.isEmpty {
            ContentUnavailableView(
                "No Highlights or Notes",
                systemImage: "highlighter",
                description: Text("Highlights, notes and drawings in this document appear here.")
            )
        } else {
            List(selection: selection) {
                ForEach(groups) { group in
                    Section("Page \(group.pageIndex + 1)") {
                        ForEach(group.entries) { entry in
                            AnnotationRow(entry: entry, markedText: markedText(for: entry))
                                .tag(entry.selection)
                                .contextMenu {
                                    Button("Reply…") {
                                        replyText = ""
                                        replyingTo = entry.selection
                                    }
                                    Button("Delete", role: .destructive) { viewer.delete(entry.selection) }
                                }
                        }
                    }
                }
            }
            .alert("Reply", isPresented: Binding(get: { replyingTo != nil }, set: { if !$0 { replyingTo = nil } })) {
                TextField("Reply", text: $replyText)
                Button("Add") {
                    if let replyingTo, !replyText.isEmpty { viewer.addReply(replyText, to: replyingTo) }
                    replyingTo = nil
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { replyingTo = nil }
            }
        }
    }

    private var selection: Binding<AnnotationSelection?> {
        Binding(get: { viewer.selection }, set: { viewer.select($0, reveal: true) })
    }

    /// One row: an annotation, or a reply shown under the one it answers.
    struct Entry: Identifiable {
        let annotation: Annotation
        let pageIndex: Int
        let depth: Int
        var id: AnnotationSelection { selection }
        var selection: AnnotationSelection { AnnotationSelection(pageIndex: pageIndex, id: annotation.id) }
    }

    /// The annotations of one page. The identity must not collide with the rows' own.
    struct PageGroup: Identifiable {
        let pageIndex: Int
        let entries: [Entry]
        var id: String { "page-\(pageIndex)" }
    }

    private var groups: [PageGroup] {
        guard let document = viewer.sheafDocument, let editor = document.editor else { return [] }
        _ = document.revision
        return (0..<viewer.pageCount).compactMap { pageIndex in
            guard let annotations = try? editor.annotations(onPageAt: pageIndex) else { return nil }
            // Links, form fields and pop-up windows are not comments.
            let listed = annotations.filter { $0.kind != .other && $0.kind != .link && $0.objectID != nil }
            guard !listed.isEmpty else { return nil }
            var entries: [Entry] = []
            func append(_ annotation: Annotation, depth: Int) {
                guard depth < 8 else { return }
                entries.append(Entry(annotation: annotation, pageIndex: pageIndex, depth: depth))
                for reply in listed where reply.replyTo == annotation.objectID { append(reply, depth: depth + 1) }
            }
            for annotation in listed where annotation.replyTo == nil { append(annotation, depth: 0) }
            return PageGroup(pageIndex: pageIndex, entries: entries)
        }
    }

    /// The text a highlight, underline or strikethrough covers.
    private func markedText(for entry: Entry) -> String? {
        guard entry.annotation.isTextMarkup, let page = viewer.document?.page(at: entry.pageIndex) else { return nil }
        let pieces = entry.annotation.quads.compactMap { page.selection(for: $0.cgRect)?.string }
        let text = pieces.joined(separator: " ").split(whereSeparator: \.isNewline).joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

private struct AnnotationRow: View {
    let entry: AnnotationList.Entry
    let markedText: String?

    var body: some View {
        let annotation = entry.annotation
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if let markedText {
                    Text(markedText).lineLimit(3)
                }
                if !annotation.contents.isEmpty {
                    Text(annotation.contents)
                        .lineLimit(4)
                        .foregroundStyle(markedText == nil ? .primary : .secondary)
                }
                if markedText == nil, annotation.contents.isEmpty {
                    Text(title).foregroundStyle(.secondary)
                }
                if entry.depth > 0, let author = annotation.author {
                    Text(author).font(.caption).foregroundStyle(.tertiary)
                }
            }
        } icon: {
            Image(systemName: entry.depth > 0 ? "arrowshape.turn.up.left" : symbol)
                .foregroundStyle(entry.depth > 0 ? Color.secondary : (annotation.color ?? .black).color)
        }
        .padding(.leading, CGFloat(entry.depth) * 14)
        .accessibilityLabel(Text(title))
        .accessibilityValue([markedText, annotation.contents].compactMap { $0 }.joined(separator: ", "))
    }

    private var symbol: String {
        switch entry.annotation.kind {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "note.text"
        case .freeText: "character.textbox"
        case .ink: "scribble"
        case .square: "rectangle"
        case .circle: "circle"
        case .line: "line.diagonal"
        case .stamp: "seal"
        case .link, .other: "questionmark.square.dashed"
        }
    }

    private var title: LocalizedStringKey {
        if entry.depth > 0 { return "Reply" }
        return switch entry.annotation.kind {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strikethrough"
        case .note: "Note"
        case .freeText: "Text"
        case .ink: "Drawing"
        case .square: "Rectangle"
        case .circle: "Ellipse"
        case .line: "Line"
        case .stamp: "Stamp"
        case .link, .other: "Annotation"
        }
    }
}
