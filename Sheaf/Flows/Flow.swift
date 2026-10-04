import Foundation
import PDFKit
import SheafKit
import UniformTypeIdentifiers

/// One thing a flow does to a document.
nonisolated struct FlowStep: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case recognizeText, reduce, watermark, pageNumbers, rotate, flatten, archival, toWord, toExcel, toImages

        /// Steps that turn the document into something else. Nothing can follow them.
        var isConversion: Bool { self == .toWord || self == .toExcel || self == .toImages }
    }

    var id = UUID()
    var kind: Kind
    /// The watermark's words, or the page number's wording.
    var text = ""
    /// How much to reduce by, or the picture format.
    var choice = ""
    /// The watermark's opacity, quarter turns, or pixels per inch.
    var number = 0.0

    /// A step of a kind with its usual settings.
    static func make(_ kind: Kind) -> FlowStep {
        switch kind {
        case .reduce: FlowStep(kind: kind, choice: "balanced")
        case .watermark: FlowStep(kind: kind, text: "DRAFT", number: 0.3)
        case .pageNumbers: FlowStep(kind: kind, text: "{page}")
        case .rotate: FlowStep(kind: kind, number: 1)
        case .toImages: FlowStep(kind: kind, choice: "png", number: 144)
        case .recognizeText, .flatten, .archival, .toWord, .toExcel: FlowStep(kind: kind)
        }
    }
}

/// A saved list of steps to run on documents.
nonisolated struct Flow: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var steps: [FlowStep] = []
    /// Joins the files it is given into one document before the steps.
    var mergesFirst = false

    /// The kind of file the flow ends with.
    var resultExtension: String {
        switch steps.last?.kind {
        case .toWord: "docx"
        case .toExcel: "xlsx"
        case .toImages: steps.last?.choice ?? "png"
        default: "pdf"
        }
    }

    var makesPDF: Bool { resultExtension == "pdf" }

    /// The flows a new copy of the app starts with, as examples to change or remove.
    static var starters: [Flow] {
        [
            Flow(name: String(localized: "Make a Scan Searchable"), steps: [.make(.recognizeText), .make(.reduce)]),
            Flow(name: String(localized: "Prepare for Email"), steps: [.make(.flatten), FlowStep(kind: .reduce, choice: "smallest")]),
            Flow(name: String(localized: "Stamp as Draft"), steps: [.make(.watermark), .make(.pageNumbers)]),
            Flow(name: String(localized: "Archive"), steps: [.make(.recognizeText), .make(.archival)]),
        ]
    }
}

/// Runs flows. Touches nothing on screen, so it can run off the main thread.
nonisolated enum FlowRunner {
    struct Output: Sendable {
        var name: String
        var fileExtension: String
        var data: Data
    }

    /// Runs a flow on files.
    ///
    /// - Parameter progress: Called with the fraction done. Return `false` to stop.
    static func run(_ flow: Flow, on files: [Toolbox.Source], progress: @escaping @Sendable (Double) -> Bool = { _ in true }) throws -> [Output] {
        guard !files.isEmpty else { throw ToolError.nothingToDo }
        var sources = files
        if flow.mergesFirst, files.count > 1 {
            sources = [Toolbox.Source(data: try Toolbox.merge(files), name: flow.name)]
        }
        var outputs: [Output] = []
        let stepCount = Double(max(flow.steps.count, 1))
        for (fileIndex, file) in sources.enumerated() {
            // Pictures are welcome too: each becomes a one-page document first.
            var current = file.isPDF ? file : Toolbox.Source(data: try PDFGenerator.document(fromImageData: file.data), name: file.name)
            var converted = false
            for (stepIndex, step) in flow.steps.enumerated() {
                let base = (Double(fileIndex) + Double(stepIndex) / stepCount) / Double(sources.count)
                let share = 1 / stepCount / Double(sources.count)
                guard progress(base) else { throw CancellationError() }
                let within: @Sendable (Double) -> Bool = { progress(base + $0 * share) }
                switch step.kind {
                case .recognizeText:
                    current.data = try Toolbox.recognizeText(current, progress: within).data
                case .reduce:
                    let options: CompressionOptions = step.choice == "exact" ? .lossless : step.choice == "smallest" ? .smallest : .balanced
                    current.data = try Toolbox.compress(current, options: options, progress: within)
                case .watermark:
                    var watermark = Watermark(content: .text(step.text.isEmpty ? "DRAFT" : step.text))
                    watermark.opacity = min(max(step.number, 0.05), 1)
                    current.data = try Toolbox.edit(current) { try $0.addWatermark(watermark) }
                case .pageNumbers:
                    var lines = HeaderFooter()
                    lines.footer.center = step.text.isEmpty ? "{page}" : step.text
                    let name = current.name
                    current.data = try Toolbox.edit(current) { try $0.addHeaderFooter(lines, documentName: name) }
                case .rotate:
                    let turns = Int(step.number.rounded())
                    current.data = try Toolbox.edit(current) { editor in
                        for index in 0..<(try editor.pageCount()) { try editor.rotatePage(at: index, by: turns * 90) }
                    }
                case .flatten:
                    current.data = try Toolbox.flatten(current, annotations: true, form: true)
                case .archival:
                    current.data = try Toolbox.archival(current).data
                    current.password = nil
                case .toWord:
                    outputs.append(Output(name: current.name, fileExtension: "docx", data: try Toolbox.word(current, progress: within)))
                    converted = true
                case .toExcel:
                    outputs.append(Output(name: current.name, fileExtension: "xlsx", data: try Toolbox.excel(current, progress: within)))
                    converted = true
                case .toImages:
                    let type = UTType(filenameExtension: step.choice) ?? .png
                    let name = current.name
                    try Toolbox.renderPages(current, as: type, resolution: min(max(step.number, 36), 600)) { data, index in
                        outputs.append(Output(name: "\(name) \(index + 1)", fileExtension: step.choice.isEmpty ? "png" : step.choice, data: data))
                        return within(0.5)
                    }
                    converted = true
                }
                // Whatever turns the document into another kind of file ends the flow.
                if converted { break }
            }
            if !converted { outputs.append(Output(name: current.name, fileExtension: "pdf", data: current.data)) }
        }
        guard progress(1) else { throw CancellationError() }
        return outputs
    }
}

/// The saved flows. Kept as one small file in the app's own folder.
nonisolated enum FlowFile {
    static var url: URL {
        let folder = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Sheaf", isDirectory: true)
        return folder.appendingPathComponent("Flows.json")
    }

    /// What is saved, or the starter flows when nothing has been yet.
    static func read() -> [Flow] {
        guard let data = try? Data(contentsOf: url), let flows = try? JSONDecoder().decode([Flow].self, from: data) else { return Flow.starters }
        return flows
    }

    static func write(_ flows: [Flow]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(flows) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The flows, for the windows and menus to show and change.
@Observable
final class FlowStore {
    static let shared = FlowStore()

    var flows: [Flow] = FlowFile.read() {
        didSet { if flows != oldValue { FlowFile.write(flows) } }
    }

    @discardableResult
    func add() -> Flow {
        var name = String(localized: "New Flow")
        var number = 2
        while flows.contains(where: { $0.name == name }) {
            name = String(localized: "New Flow \(number)")
            number += 1
        }
        let flow = Flow(name: name, steps: [])
        flows.append(flow)
        return flow
    }
}
