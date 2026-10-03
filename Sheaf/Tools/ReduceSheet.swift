import SheafKit
import SwiftUI
import Synchronization

/// File > Reduce File Size.
struct ReduceSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    private enum Preset: String, CaseIterable, Identifiable {
        case exact, balanced, smallest, custom

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .exact: "Keep Everything Exact"
            case .balanced: "Balanced"
            case .smallest: "Smallest"
            case .custom: "Custom"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .exact: "Packs the file more tightly. Nothing looks different."
            case .balanced: "Pictures at 150 pixels per inch. Good on screen and in print."
            case .smallest: "Pictures at 96 pixels per inch. For sending; soft when zoomed in."
            case .custom: "Choose the resolution and quality of pictures."
            }
        }
    }

    private enum Phase: Equatable {
        case choosing
        case working(Double)
        case done(before: Int, after: Int)
        case noGain
        case failed(String)
    }

    @State private var preset = Preset.balanced
    @State private var resolution = 150.0
    @State private var quality = 65.0
    @State private var scalesPictures = true
    @State private var removesExtras = true
    @State private var phase = Phase.choosing
    @State private var work: Task<Void, Never>?
    @State private var stop = StopFlag()

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .choosing: choices
            case .working(let progress): working(progress)
            case .done(let before, let after): result(before: before, after: after)
            case .noGain:
                message("Already as Small as It Gets", systemImage: "checkmark.circle", "These settings would not make the document smaller, so it was left as it is.")
            case .failed(let reason):
                message("The Document Could Not Be Reduced", systemImage: "exclamationmark.triangle", LocalizedStringKey(reason))
            }
        }
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                switch phase {
                case .choosing: Button("Cancel") { dismiss() }
                case .working: Button("Stop", action: cancel)
                default: EmptyView()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                switch phase {
                case .choosing: Button("Reduce", action: start)
                case .working: Button("Reduce") {}.disabled(true)
                default: Button("Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(phase != .choosing)
    }

    private var currentSize: Int { viewer.sheafDocument?.currentData.count ?? 0 }

    private var choices: some View {
        Form {
            Section {
                Picker("Reduce", selection: $preset) {
                    ForEach(Preset.allCases) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(preset)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("This document is \(formattedSize(currentSize)).")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            if preset == .custom {
                Section {
                    Toggle("Scale Down Large Pictures", isOn: $scalesPictures)
                    if scalesPictures {
                        LabeledSlider(title: "Pixels per Inch", value: $resolution, range: 50...400, step: 10)
                    }
                    LabeledSlider(title: "Picture Quality", value: $quality, range: 10...100, step: 5) { "\(Int($0))%" }
                }
            }

            Section {
                Toggle("Remove Thumbnails and Private App Data", isOn: $removesExtras)
            } footer: {
                Text("Reducing replaces the document in this window. Choose Edit > Undo to go back, or File > Duplicate first to keep the original.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func working(_ progress: Double) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress) {
                Text("Reducing the document…")
            }
        }
        .padding(28)
    }

    private func result(before: Int, after: Int) -> some View {
        let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
        return message(
            "\(saved)% Smaller", systemImage: "arrow.down.right.and.arrow.up.left.circle",
            "From \(formattedSize(before)) to \(formattedSize(after)). Save the document to keep the smaller version."
        )
    }

    private func message(_ title: LocalizedStringKey, systemImage: String, _ detail: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
            Text(title).font(.title3.bold())
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var options: CompressionOptions {
        switch preset {
        case .exact: CompressionOptions(removesExtras: removesExtras)
        case .balanced: CompressionOptions(maximumImageResolution: 150, imageQuality: 0.65, removesExtras: removesExtras)
        case .smallest: CompressionOptions(maximumImageResolution: 96, imageQuality: 0.4, removesExtras: removesExtras)
        case .custom: CompressionOptions(maximumImageResolution: scalesPictures ? resolution : nil, imageQuality: quality / 100, removesExtras: removesExtras)
        }
    }

    private func start() {
        guard let document = viewer.sheafDocument else { return }
        let source = Toolbox.Source(data: document.currentData, name: viewer.documentName, password: document.password)
        let options = options, before = source.data.count, stop = StopFlag()
        self.stop = stop
        phase = .working(0)
        work = Task {
            let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
            let job = Task.detached(priority: .userInitiated) { () -> Result<Data, any Error> in
                defer { continuation.finish() }
                return Result {
                    try Toolbox.compress(source, options: options) { value in
                        continuation.yield(value)
                        return !stop.isSet
                    }
                }
            }
            for await value in updates { phase = .working(value) }
            switch await job.value {
            case .success(let data):
                // A saving too small to notice is not worth replacing the document for.
                if Double(data.count) < Double(before) * 0.98,
                   document.replaceContents(String(localized: "Reduce File Size"), with: data, password: document.password) {
                    phase = .done(before: before, after: data.count)
                } else {
                    phase = .noGain
                }
            case .failure(let error):
                if error is CancellationError { dismiss() } else { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func cancel() {
        stop.set()
    }
}

/// A flag one thread sets to ask another to stop.
nonisolated final class StopFlag: Sendable {
    private let flag = Mutex(false)

    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}
