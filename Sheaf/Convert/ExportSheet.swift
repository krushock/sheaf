import AppKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// What a document can be turned into.
enum ConversionKind: String, Identifiable {
    case word, excel, archival

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .word: "Export to Word"
        case .excel: "Export to Excel"
        case .archival: "Export as PDF/A"
        }
    }

    var systemImage: String {
        switch self {
        case .word: "doc.richtext"
        case .excel: "tablecells"
        case .archival: "archivebox"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .word:
            "The text is carried over in paragraphs with its fonts, sizes, colors and pictures, on pages of the same size. Columns, tables and exact positions are not, so expect to tidy the result."
        case .excel:
            "Each page becomes a sheet. Text that lines up in rows and columns lands in rows and columns, and numbers become numbers. Pages of running text become one column."
        case .archival:
            "PDF/A-2b is a form of PDF for keeping documents for decades. Fonts are put inside the file, colors are given a profile, and scripts, attachments and passwords are taken out."
        }
    }

    var fileExtension: String {
        switch self {
        case .word: "docx"
        case .excel: "xlsx"
        case .archival: "pdf"
        }
    }

    var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }

    var isBeta: Bool { self != .archival }
}

extension ArchivalNote {
    /// The note in words.
    var text: String {
        switch self {
        case .embeddedFont(let name): String(localized: "Put the font \(name) inside the file")
        case .addedColorProfile: String(localized: "Added a color profile (sRGB)")
        case .addedMetadata: String(localized: "Wrote the metadata the standard asks for")
        case .removedPassword: String(localized: "Removed the password")
        case .removedScripts(let count): String(localized: "Removed \(count) scripts and actions")
        case .removedAttachments(let count): String(localized: "Removed \(count) attached files")
        case .madeAnnotationsPrintable(let count): String(localized: "Set \(count) annotations to show and print")
        case .removedFormData: String(localized: "Removed the form's second copy of its data")
        case .recompressedStreams(let count): String(localized: "Repacked \(count) parts that used an old compression")
        case .fontNotEmbedded(let name): String(localized: "The font \(name) is not in the file and is not installed on this Mac")
        case .usesPrintingColors(let pages): String(localized: "\(pages) pages use printing-ink colors (CMYK), which need a press profile")
        case .annotationsWithoutAppearance(let count): String(localized: "\(count) annotations have no stored picture of themselves")
        case .unsupportedAnnotations(let count): String(localized: "\(count) annotations are of kinds the standard does not allow (sound, video, 3D, attachments)")
        }
    }
}

/// File > Export To: Word, Excel and PDF/A.
struct ExportSheet: View {
    let viewer: ViewerModel
    let kind: ConversionKind
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case choosing
        case working(Double)
        /// PDF/A made and waiting to be saved.
        case converted(ArchivalResult)
        case saved(URL)
        case failed(String)
    }

    @State private var phase = Phase.choosing
    @State private var stop = StopFlag()

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .choosing:
                message(kind.title, systemImage: kind.systemImage, kind.detail, badge: kind.isBeta)
            case .working(let progress):
                ProgressView(value: progress) { Text("Converting…") }
                    .padding(28)
            case .converted(let result):
                archivalResult(result)
            case .saved(let url):
                message("Saved", systemImage: "checkmark.circle", "\(url.lastPathComponent)", badge: false)
            case .failed(let reason):
                message("The Document Could Not Be Converted", systemImage: "exclamationmark.triangle", LocalizedStringKey(reason), badge: false)
            }
        }
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                switch phase {
                case .choosing, .converted: Button("Cancel") { dismiss() }
                case .working: Button("Stop") { stop.set() }
                case .saved(let url): Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                case .failed: EmptyView()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                switch phase {
                case .choosing: Button(kind == .archival ? "Convert" : "Export…", action: start)
                case .working: Button("Export…") {}.disabled(true)
                case .converted(let result): Button("Save…") { save(result.data) }
                case .saved, .failed: Button("Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled({ if case .working = phase { true } else { false } }())
    }

    private func message(_ title: LocalizedStringKey, systemImage: String, _ detail: LocalizedStringKey, badge: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
            HStack(spacing: 8) {
                Text(title).font(.title3.bold())
                if badge {
                    Text("Beta")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                        .accessibilityLabel("Beta feature")
                }
            }
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func archivalResult(_ result: ArchivalResult) -> some View {
        Form {
            if !result.fixed.isEmpty {
                Section("Done") {
                    ForEach(result.fixed, id: \.self) { note in
                        Label(note.text, systemImage: "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }
            Section {
                if result.remaining.isEmpty {
                    Label("Nothing was found that the standard does not allow.", systemImage: "checkmark.seal")
                } else {
                    ForEach(result.remaining, id: \.self) { note in
                        Label(note.text, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            } header: {
                Text(result.remaining.isEmpty ? "Ready" : "Could Not Be Put Right")
            } footer: {
                Text(result.remaining.isEmpty
                    ? "Sheaf has made every change it knows the standard asks for. If the file is going to an archive that checks, run it through their validator too."
                    : "The file can still be saved. It will be closer to the standard, but a validator will not pass it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func start() {
        guard let document = viewer.sheafDocument else { return }
        let source = Toolbox.Source(data: document.currentData, name: viewer.documentName, password: document.password)
        if kind == .archival {
            phase = .working(0.5)
            Task {
                let job = Task.detached(priority: .userInitiated) { Result { try Toolbox.archival(source) } }
                switch await job.value {
                case .success(let result): phase = .converted(result)
                case .failure(let error): phase = .failed(error.localizedDescription)
                }
            }
            return
        }
        // Ask where to put it first, so a long conversion is not thrown away by Cancel.
        guard let url = chooseDestination() else { return }
        let kind = kind, stop = StopFlag()
        self.stop = stop
        phase = .working(0)
        Task {
            let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
            let job = Task.detached(priority: .userInitiated) { () -> Result<Data, any Error> in
                defer { continuation.finish() }
                return Result {
                    let progress: @Sendable (Double) -> Bool = { value in
                        continuation.yield(value)
                        return !stop.isSet
                    }
                    return kind == .word ? try Toolbox.word(source, progress: progress) : try Toolbox.excel(source, progress: progress)
                }
            }
            for await value in updates { phase = .working(value) }
            switch await job.value {
            case .success(let data): write(data, to: url)
            case .failure(let error):
                if error is CancellationError { dismiss() } else { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = viewer.documentName + (kind == .archival ? " (PDF-A)" : "")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func save(_ data: Data) {
        guard let url = chooseDestination() else { return }
        write(data, to: url)
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            phase = .saved(url)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
