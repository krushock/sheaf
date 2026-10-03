import PDFKit
import SheafKit
import SwiftUI

/// File > Document Info: the title, author and keywords, and facts about the file.
struct DocumentInfoSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var info = DocumentInfo()
    @State private var original = DocumentInfo()

    var body: some View {
        Form {
            Section {
                TextField("Title", text: text(\.title))
                TextField("Author", text: text(\.author))
                TextField("Subject", text: text(\.subject))
                TextField("Keywords", text: text(\.keywords), axis: .vertical)
                    .lineLimit(1...3)
            }
            .disabled(!viewer.canEditPages)

            Section {
                fact("Made With", info.creator)
                fact("PDF Producer", info.producer)
                fact("Created", info.creationDate?.formatted(date: .abbreviated, time: .shortened))
                fact("Modified", info.modificationDate?.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                fact("Pages", "\(viewer.pageCount)")
                fact("Page Size", pageSize)
                fact("PDF Version", version)
                fact("File Size", (viewer.sheafDocument?.currentData.count).map(formattedSize))
                fact("Security", security)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)
        .onAppear {
            info = (try? viewer.sheafDocument?.editor?.info()) ?? DocumentInfo()
            original = info
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(viewer.canEditPages ? "Cancel" : "Close") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(info == original || !viewer.canEditPages)
            }
        }
    }

    private func text(_ keyPath: WritableKeyPath<DocumentInfo, String?>) -> Binding<String> {
        Binding(
            get: { info[keyPath: keyPath] ?? "" },
            set: { info[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    @ViewBuilder private func fact(_ title: LocalizedStringKey, _ value: String?) -> some View {
        LabeledContent(title) {
            Text(value ?? "—")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private var pageSize: String? {
        guard let size = try? viewer.sheafDocument?.editor?.geometry(ofPageAt: viewer.currentPageIndex).displaySize else { return nil }
        let usesInches = Locale.current.measurementSystem == .us
        let unit = usesInches ? 72.0 : 72 / 25.4
        func number(_ value: Double) -> String {
            (value / unit).formatted(.number.precision(.fractionLength(usesInches ? 2 : 0)))
        }
        return usesInches
            ? String(localized: "\(number(size.width)) × \(number(size.height)) inches")
            : String(localized: "\(number(size.width)) × \(number(size.height)) mm")
    }

    private var version: String? {
        (viewer.sheafDocument?.editor?.base.version).map { "\($0.major).\($0.minor)" }
    }

    private var security: String {
        guard let file = viewer.sheafDocument?.editor?.base, file.isEncrypted else { return String(localized: "None") }
        switch file.encryptionAlgorithm {
        case .aes256: return String(localized: "Password, AES 256-bit")
        case .aes128: return String(localized: "Password, AES 128-bit")
        case .rc4(let bits): return String(localized: "Password, RC4 \(bits)-bit")
        case nil: return String(localized: "Password")
        }
    }

    private func save() {
        var changed = info
        changed.modificationDate = .now
        viewer.sheafDocument?.apply(String(localized: "Change Document Info")) { editor, _ in
            try editor.setInfo(changed)
        }
        dismiss()
    }
}
