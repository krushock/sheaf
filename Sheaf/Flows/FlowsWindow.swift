import AppKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

extension FlowStep.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .recognizeText: "Recognize Text"
        case .reduce: "Reduce File Size"
        case .watermark: "Add Watermark"
        case .pageNumbers: "Add Page Numbers"
        case .rotate: "Rotate Pages"
        case .flatten: "Flatten Annotations and Form"
        case .archival: "Convert to PDF/A"
        case .toWord: "Export to Word"
        case .toExcel: "Export to Excel"
        case .toImages: "Export as Images"
        }
    }

    var systemImage: String {
        switch self {
        case .recognizeText: "text.viewfinder"
        case .reduce: "arrow.down.right.and.arrow.up.left"
        case .watermark: "drop.halffull"
        case .pageNumbers: "number"
        case .rotate: "rotate.right"
        case .flatten: "square.3.layers.3d.down.right"
        case .archival: "archivebox"
        case .toWord: "doc.richtext"
        case .toExcel: "tablecells"
        case .toImages: "photo.stack"
        }
    }
}

/// Tools > Flows: saved lists of steps, and running them on many files at once.
struct FlowsWindow: View {
    static let windowID = "flows"

    @State private var store = FlowStore.shared
    @State private var selection: Flow.ID?
    @State private var run = FlowRun()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($store.flows) { $flow in
                        TextField("Name", text: $flow.name)
                            .tag(flow.id)
                    }
                    .onMove { store.flows.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button {
                        selection = store.add().id
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add a flow")
                    Divider().frame(height: 14)
                    Button {
                        store.flows.removeAll { $0.id == selection }
                        selection = store.flows.first?.id
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection == nil)
                    .help("Remove the selected flow")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if let index = store.flows.firstIndex(where: { $0.id == selection }) {
                FlowEditor(flow: $store.flows[index], run: run)
            } else {
                ContentUnavailableView("No Flow Selected", systemImage: "point.3.connected.trianglepath.dotted", description: Text("A flow is a list of steps to run on documents, one after another. Add one with the plus button."))
            }
        }
        .navigationTitle("Flows")
        .frame(minWidth: 660, minHeight: 420)
        .onAppear { if selection == nil { selection = store.flows.first?.id } }
    }
}

/// The steps of one flow, and running it.
private struct FlowEditor: View {
    @Binding var flow: Flow
    let run: FlowRun

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if flow.steps.isEmpty {
                        Text("No steps yet. Add one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($flow.steps) { $step in
                        StepRow(step: $step) { flow.steps.removeAll { $0.id == step.id } }
                    }
                    .onMove { flow.steps.move(fromOffsets: $0, toOffset: $1) }
                    Menu("Add Step") {
                        ForEach(FlowStep.Kind.allCases, id: \.self) { kind in
                            Button {
                                add(kind)
                            } label: {
                                Label(kind.title, systemImage: kind.systemImage)
                            }
                        }
                    }
                    .fixedSize()
                } header: {
                    Text("Steps")
                } footer: {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.callout)
                    }
                }
                Section {
                    Toggle("Join the Files into One Document First", isOn: $flow.mergesFirst)
                }
            }
            .formStyle(.grouped)

            Divider()
            runBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard problem == nil, !run.isRunning else { return false }
            run.start(flow, on: urls)
            return true
        }
    }

    /// Why the flow cannot run as it is.
    private var problem: LocalizedStringKey? {
        if let index = flow.steps.firstIndex(where: \.kind.isConversion), index != flow.steps.count - 1 {
            return "A step that exports to another kind of file has to come last."
        }
        return nil
    }

    private func add(_ kind: FlowStep.Kind) {
        // An exporting step stays last; other steps go in before it.
        if let last = flow.steps.last, last.kind.isConversion, !kind.isConversion {
            flow.steps.insert(.make(kind), at: flow.steps.count - 1)
        } else {
            flow.steps.append(.make(kind))
        }
    }

    private var runBar: some View {
        HStack(spacing: 12) {
            switch run.phase {
            case .idle:
                Text("Drop files here, or choose them, to run the flow on each.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            case .working(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Button("Stop") { run.stop() }
            case .done(let count, let folder):
                Label("\(count) files saved", systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                    .buttonStyle(.link)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(2)
            }
            Spacer()
            Button("Run on Files…") { run.chooseAndStart(flow) }
                .keyboardShortcut(.defaultAction)
                .disabled(flow.steps.isEmpty || problem != nil || run.isRunning)
        }
        .padding(12)
    }
}

/// One step with its settings.
private struct StepRow: View {
    @Binding var step: FlowStep
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.kind.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(step.kind.title)
            Spacer(minLength: 12)
            settings
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this step")
            .accessibilityLabel("Remove Step")
        }
    }

    @ViewBuilder private var settings: some View {
        switch step.kind {
        case .reduce:
            Picker("Reduction", selection: $step.choice) {
                Text("Keep Everything Exact").tag("exact")
                Text("Balanced").tag("balanced")
                Text("Smallest").tag("smallest")
            }
            .labelsHidden()
            .fixedSize()
        case .watermark:
            TextField("Text", text: $step.text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            Picker("Opacity", selection: $step.number) {
                ForEach([0.15, 0.3, 0.5, 0.75], id: \.self) { value in
                    Text(value, format: .percent).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .pageNumbers:
            TextField("Text", text: $step.text, prompt: Text(verbatim: "{page} / {pages}"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .help("Use {page} for the page number and {pages} for the page count")
        case .rotate:
            Picker("Turn", selection: $step.number) {
                Text("Right").tag(1.0)
                Text("Upside Down").tag(2.0)
                Text("Left").tag(3.0)
            }
            .labelsHidden()
            .fixedSize()
        case .toImages:
            Picker("Format", selection: $step.choice) {
                Text(verbatim: "PNG").tag("png")
                Text(verbatim: "JPEG").tag("jpeg")
                Text(verbatim: "TIFF").tag("tiff")
            }
            .labelsHidden()
            .fixedSize()
            Picker("Resolution", selection: $step.number) {
                ForEach([72.0, 144, 300], id: \.self) { value in
                    Text("\(Int(value)) ppi").tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .recognizeText, .flatten, .archival, .toWord, .toExcel:
            EmptyView()
        }
    }
}

/// One run of a flow on a batch of files.
@Observable
final class FlowRun {
    enum Phase: Equatable {
        case idle
        case working(Double)
        case done(Int, URL)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    @ObservationIgnored private var flag = StopFlag()

    var isRunning: Bool { if case .working = phase { true } else { false } }

    func stop() { flag.set() }

    func chooseAndStart(_ flow: Flow) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose the files to run “\(flow.name)” on.")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        start(flow, on: panel.urls)
    }

    /// Asks where the results go, then runs the flow.
    func start(_ flow: Flow, on urls: [URL]) {
        let usable = urls.filter { url in
            UTType(filenameExtension: url.pathExtension).map { $0.conforms(to: .pdf) || $0.conforms(to: .image) } ?? false
        }
        guard !usable.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a folder for the results. The original files are not changed.")
        panel.prompt = String(localized: "Save Here")
        #if DEBUG
        let chosen = DebugSnapshot.flowOutputFolder ?? (panel.runModal() == .OK ? panel.url : nil)
        #else
        let chosen = panel.runModal() == .OK ? panel.url : nil
        #endif
        guard let folder = chosen else { return }
        run(flow, sources: usable.compactMap { try? Toolbox.Source(url: $0) }, into: folder)
    }

    func run(_ flow: Flow, sources: [Toolbox.Source], into folder: URL) {
        let flag = StopFlag()
        self.flag = flag
        phase = .working(0)
        Task {
            let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
            let job = Task.detached(priority: .userInitiated) { () -> Result<Int, any Error> in
                defer { continuation.finish() }
                return Result {
                    let outputs = try FlowRunner.run(flow, on: sources) { value in
                        continuation.yield(value)
                        return !flag.isSet
                    }
                    let scoped = folder.startAccessingSecurityScopedResource()
                    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                    for output in outputs { try Toolbox.write(output.data, named: output.name, extension: output.fileExtension, in: folder) }
                    return outputs.count
                }
            }
            for await value in updates { phase = .working(value) }
            switch await job.value {
            case .success(let count): phase = .done(count, folder)
            case .failure(let error): phase = error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
        }
    }
}

extension ViewerModel {
    /// Runs a flow on the document in this window. A flow that ends with a PDF changes
    /// the document, as one step that Undo takes back; one that exports asks where to save.
    func run(_ flow: Flow) {
        guard let sheafDocument, !flow.steps.isEmpty else { return }
        let source = Toolbox.Source(data: sheafDocument.currentData, name: documentName, password: sheafDocument.password)
        isFindingText = true
        Task {
            let job = Task.detached(priority: .userInitiated) { Result { try FlowRunner.run(flow, on: [source]) } }
            let result = await job.value
            isFindingText = false
            switch result {
            case .failure(let error):
                editMessage = error.localizedDescription
            case .success(let outputs):
                if flow.makesPDF, let output = outputs.first {
                    // PDF/A drops the password; everything else keeps it.
                    let password = flow.steps.contains { $0.kind == .archival } ? nil : sheafDocument.password
                    if sheafDocument.replaceContents(flow.name, with: output.data, password: password) { show(sheafDocument) }
                } else {
                    save(outputs)
                }
            }
        }
    }

    private func save(_ outputs: [FlowRunner.Output]) {
        guard let first = outputs.first else { return }
        do {
            if outputs.count == 1 {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: first.fileExtension) ?? .data]
                panel.nameFieldStringValue = first.name
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try first.data.write(to: url, options: .atomic)
            } else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = String(localized: "Save Here")
                guard panel.runModal() == .OK, let folder = panel.url else { return }
                for output in outputs { try Toolbox.write(output.data, named: output.name, extension: output.fileExtension, in: folder) }
            }
        } catch {
            editMessage = error.localizedDescription
        }
    }
}
