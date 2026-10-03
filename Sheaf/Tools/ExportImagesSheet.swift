import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File > Export as Images: each page as a picture file.
struct ExportImagesSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    private enum Format: String, CaseIterable, Identifiable {
        case png, jpeg, tiff, heic

        var id: Self { self }

        var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .tiff: .tiff
            case .heic: .heic
            }
        }

        var title: String {
            switch self {
            case .png: "PNG"
            case .jpeg: "JPEG"
            case .tiff: "TIFF"
            case .heic: "HEIC"
            }
        }

        var isLossy: Bool { self == .jpeg || self == .heic }
    }

    @State private var format = Format.png
    @State private var resolution = 144
    @State private var quality = 90.0
    @State private var scope = PageScope()
    @State private var progress: Double?
    @State private var stop = StopFlag()
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $format) {
                    ForEach(Format.allCases) { Text($0.title).tag($0) }
                }
                Picker("Resolution", selection: $resolution) {
                    Text("72 pixels per inch (screen)").tag(72)
                    Text("144 pixels per inch (Retina)").tag(144)
                    Text("300 pixels per inch (print)").tag(300)
                    Text("600 pixels per inch").tag(600)
                }
                if format.isLossy {
                    LabeledSlider(title: "Quality", value: $quality, range: 10...100, step: 5) { "\(Int($0))%" }
                }
            }
            Section {
                PageScopeRows(scope: $scope, pageCount: viewer.pageCount, currentPage: viewer.currentPageIndex)
            }
            if let progress {
                Section {
                    ProgressView(value: progress) { Text("Exporting pages…") }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(progress == nil ? "Cancel" : "Stop") {
                    if progress == nil { dismiss() } else { stop.set() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Choose Folder…", action: chooseFolder)
                    .disabled(targets == nil || progress != nil)
            }
        }
        .interactiveDismissDisabled(progress != nil)
        .alert("The pages could not be exported.", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
    }

    private var targets: [Int]? {
        scope.indexes(pageCount: viewer.pageCount, current: viewer.currentPageIndex)
    }

    private func chooseFolder() {
        guard let targets, let window = viewer.window?.attachedSheet ?? viewer.window,
              let document = viewer.sheafDocument
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export")
        panel.message = targets.count == 1
            ? String(localized: "Choose where to save the picture.")
            : String(localized: "Choose where to save the \(targets.count) pictures.")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            export(targets, of: document, to: folder)
        }
    }

    private func export(_ targets: [Int], of document: SheafDocument, to folder: URL) {
        let source = Toolbox.Source(data: document.currentData, name: viewer.documentName, password: document.password)
        let type = format.type, resolution = Double(resolution), quality = quality / 100
        let fileExtension = type.preferredFilenameExtension ?? format.rawValue
        // Numbers padded to the same width, so the files sort in page order.
        let digits = max(String(viewer.pageCount).count, 2)
        let stop = StopFlag()
        self.stop = stop
        progress = 0
        Task {
            let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
            let job = Task.detached(priority: .userInitiated) { () -> Result<[URL], any Error> in
                defer { continuation.finish() }
                return Result {
                    let scoped = folder.startAccessingSecurityScopedResource()
                    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                    var urls: [URL] = []
                    try Toolbox.renderPages(source, pages: targets, as: type, resolution: resolution, quality: quality) { data, index in
                        let number = String(repeating: "0", count: max(digits - String(index + 1).count, 0)) + String(index + 1)
                        urls.append(try Toolbox.write(data, named: "\(source.name) \(number)", extension: fileExtension, in: folder))
                        continuation.yield(Double(urls.count) / Double(targets.count))
                        return !stop.isSet
                    }
                    return urls
                }
            }
            for await value in updates { progress = value }
            progress = nil
            switch await job.value {
            case .success(let urls):
                dismiss()
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }
}
