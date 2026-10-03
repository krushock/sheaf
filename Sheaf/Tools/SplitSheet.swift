import AppKit
import SheafKit
import SwiftUI

/// File > Split into Documents.
struct SplitSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case every, bookmarks, ranges, single

        var id: Self { self }
    }

    @State private var mode = Mode.every
    @State private var size = 2
    @State private var rangeText = ""
    @State private var failure: String?
    @State private var isWorking = false

    private var outline: [OutlineItem] { viewer.outline }

    var body: some View {
        Form {
            Section {
                Picker("Split", selection: $mode) {
                    Text("Every Few Pages").tag(Mode.every)
                    Text("At Each Top-Level Bookmark").tag(Mode.bookmarks)
                    Text("By Page Ranges").tag(Mode.ranges)
                    Text("Into Single Pages").tag(Mode.single)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            switch mode {
            case .every:
                Section {
                    Stepper("\(size) Pages in Each Document", value: $size, in: 1...max(viewer.pageCount - 1, 1))
                }
            case .ranges:
                Section {
                    TextField("Ranges", text: $rangeText, prompt: Text("1-3, 4-10, 11-"))
                } footer: {
                    Text("Separate the ranges with commas. Each range becomes a document.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .bookmarks, .single:
                EmptyView()
            }

            Section {
                LabeledContent("Result") {
                    Text(summary)
                        .foregroundStyle(parts == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if viewer.pageCount <= 2 { size = 1 }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Choose Folder…", action: chooseFolder)
                    .disabled((parts?.count ?? 0) < 1 || isWorking)
            }
        }
        .alert("The document could not be split.", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
    }

    /// The documents the settings would make, or `nil` when the settings cannot be read.
    private var parts: [SplitPart]? {
        let count = viewer.pageCount
        switch mode {
        case .every:
            return SplitPlan.every(size, pageCount: count)
        case .single:
            return SplitPlan.every(1, pageCount: count)
        case .bookmarks:
            let parts = SplitPlan.byBookmarks(outline, pageCount: count)
            return parts.isEmpty ? nil : parts
        case .ranges:
            let pieces = rangeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !pieces.isEmpty else { return nil }
            var parts: [SplitPart] = []
            for piece in pieces {
                guard let indexes = try? PageRanges.parse(piece, pageCount: count) else { return nil }
                parts.append(SplitPart(pageIndexes: indexes))
            }
            return parts
        }
    }

    private var summary: String {
        guard let parts else {
            switch mode {
            case .bookmarks: return String(localized: "This document has no bookmarks that lead to pages.")
            case .ranges: return rangeText.isEmpty ? String(localized: "Enter page ranges.") : String(localized: "Enter page numbers from 1 to \(viewer.pageCount).")
            default: return ""
            }
        }
        return parts.count == 1 ? String(localized: "1 document") : String(localized: "\(parts.count) documents")
    }

    private func chooseFolder() {
        guard let parts, let window = viewer.window?.attachedSheet ?? viewer.window,
              let document = viewer.sheafDocument
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Split")
        panel.message = String(localized: "Choose where to save the \(parts.count) documents.")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            let source = Toolbox.Source(data: document.currentData, name: viewer.documentName, password: document.password)
            let names = Toolbox.names(for: parts, baseName: source.name)
            isWorking = true
            Task {
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[URL], any Error> in
                    Result {
                        let scoped = folder.startAccessingSecurityScopedResource()
                        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                        let documents = try Toolbox.split(source, into: parts)
                        return try zip(documents, names).map { try Toolbox.write($0, named: $1, extension: "pdf", in: folder) }
                    }
                }.value
                isWorking = false
                switch outcome {
                case .success(let urls):
                    dismiss()
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                case .failure(let error):
                    failure = error.localizedDescription
                }
            }
        }
    }
}
