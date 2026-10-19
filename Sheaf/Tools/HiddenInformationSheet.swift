import SheafKit
import SwiftUI

extension HiddenInformation {
    var title: String {
        switch self {
        case .metadata: String(localized: "Metadata")
        case .attachments: String(localized: "Attached Files")
        case .scripts: String(localized: "Scripts and Actions")
        case .comments: String(localized: "Comments and Markup")
        case .bookmarks: String(localized: "Bookmarks")
        case .privateData: String(localized: "Private Data of Other Apps")
        }
    }

    var detail: String {
        switch self {
        case .metadata: String(localized: "The author, title, keywords, dates, and the apps the document was made with.")
        case .attachments: String(localized: "Files carried inside the document.")
        case .scripts: String(localized: "JavaScript, and actions that run when the document opens or that send form data.")
        case .comments: String(localized: "Notes, highlights, drawings and stamps. Links and form fields stay.")
        case .bookmarks: String(localized: "The document's table of contents.")
        case .privateData: String(localized: "What the app that made the document keeps for itself, and stored page thumbnails.")
        }
    }

    var systemImage: String {
        switch self {
        case .metadata: "info.circle"
        case .attachments: "paperclip"
        case .scripts: "curlybraces"
        case .comments: "text.bubble"
        case .bookmarks: "bookmark"
        case .privateData: "lock.doc"
        }
    }
}

/// Tools > Remove Hidden Information: what a document carries besides its pages, found
/// and taken out before it is shared, as Acrobat's Sanitize Document does.
struct HiddenInformationSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var found: [HiddenInformation: Int]?
    @State private var chosen: Set<HiddenInformation> = []
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                if let found {
                    ForEach(HiddenInformation.allCases) { kind in
                        Toggle(isOn: binding(kind)) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title)
                                    Text(found[kind].map { String(localized: "Found \($0)") } ?? String(localized: "None"))
                                        .font(.caption)
                                        .foregroundStyle(found[kind] == nil ? .tertiary : .secondary)
                                }
                            } icon: {
                                Image(systemName: kind.systemImage)
                            }
                        }
                        .disabled(found[kind] == nil)
                        .help(kind.detail)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } header: {
                Text("Remove from the Document")
            } footer: {
                Text("The document is written out afresh, so what is removed, and anything deleted from it earlier, is gone from the file and not just hidden. Undo brings it back until the document is closed. Text under redaction marks is not touched here: use Redact for that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Remove", action: apply)
                    .disabled(chosen.isEmpty)
            }
        }
        .task {
            let result = (try? viewer.sheafDocument?.editor?.hiddenInformation()) ?? [:]
            found = result
            chosen = Set(result.keys)
        }
    }

    private func binding(_ kind: HiddenInformation) -> Binding<Bool> {
        Binding(get: { chosen.contains(kind) }, set: { on in
            if on { chosen.insert(kind) } else { chosen.remove(kind) }
        })
    }

    private func apply() {
        guard let document = viewer.sheafDocument, var editor = document.editor else { return }
        do {
            try editor.removeHiddenInformation(chosen)
            let data = try editor.rewritten()
            guard document.replaceContents(String(localized: "Remove Hidden Information"), with: data, password: document.password) else {
                throw CocoaError(.fileWriteUnknown)
            }
            viewer.show(document)
            let names = HiddenInformation.allCases.filter(chosen.contains).map(\.title)
            viewer.editMessage = String(localized: "Removed \(names.formatted(.list(type: .and))). Save the document to keep this version.")
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
