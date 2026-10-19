import SwiftUI

/// The Summary panel: a column on the right, in place of the Format panel, where Apple
/// Intelligence sums the document up and answers questions about it.
struct AssistantPanel: View {
    @Bindable var viewer: ViewerModel

    private var assistant: AssistantModel { viewer.assistant }

    var body: some View {
        @Bindable var assistant = viewer.assistant
        VStack(spacing: 0) {
            Picker("Show", selection: $assistant.tab) {
                ForEach(AssistantTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let reason = DocumentReader.unavailableReason {
                ContentUnavailableView {
                    Label("Apple Intelligence", systemImage: "apple.intelligence")
                } description: {
                    Text(reason)
                }
                .frame(maxHeight: .infinity)
            } else if let kind = assistant.tab.kind {
                SummaryView(viewer: viewer, kind: kind)
            } else {
                AskView(viewer: viewer)
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        // The same backdrop as the Format panel; see there for why it is made of views.
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Color.primary.opacity(0.06)
            }
        }
        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
    }
}

/// The choice between the model on this Mac and Private Cloud Compute, shown where the
/// other can be used, with a line under it saying what the choice means.
private struct EngineChoice: View {
    @AppStorage(Preferences.readingEngine) private var engine = ReadingEngine.device
    let caution: LocalizedStringKey

    var body: some View {
        let offersCloud = DocumentReader.isCloudAvailable
        if offersCloud {
            Picker("Made by", selection: $engine) {
                ForEach(ReadingEngine.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Group {
            if offersCloud, engine == .cloud {
                Text("Made by Apple Intelligence on Private Cloud Compute, which keeps none of the text.") + Text(verbatim: " ") + Text(caution)
            } else {
                Text("Made by Apple Intelligence on this Mac.") + Text(verbatim: " ") + Text(caution)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A block of text on the panel, set off the way a group of controls is in the Format panel.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: .rect(cornerRadius: 8))
    }
}

private struct SummaryView: View {
    @Bindable var viewer: ViewerModel
    let kind: SummaryKind

    var body: some View {
        @Bindable var assistant = viewer.assistant
        let summary = assistant.summaries[kind]
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let summary {
                        Text(summary.subject)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                        if !summary.text.isEmpty {
                            Card {
                                Text(summary.text)
                                    .textSelection(.enabled)
                                    .lineSpacing(2)
                            }
                        }
                        if let progress = summary.progress {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(progress).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 2)
                        }
                        if let failure = summary.failure {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }
                        if let note = summary.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }
                        if !summary.isRunning, !summary.text.isEmpty {
                            HStack(spacing: 14) {
                                Button("Copy", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(summary.text, forType: .string)
                                }
                                .help("Copy the text")
                                Button("Add as Note", systemImage: "note.text.badge.plus") {
                                    viewer.addNote(with: summary.text, heading: kind == .summary
                                        ? String(localized: "Summary by Apple Intelligence")
                                        : String(localized: "Key points by Apple Intelligence"))
                                }
                                    .help("Put the text on this page as a note")
                                    .disabled(viewer.sheafDocument?.isEditable != true)
                                Spacer()
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                            .padding(.horizontal, 2)
                        }
                    } else {
                        Text(kind == .summary
                             ? "Apple Intelligence reads the document on this Mac and says in a few sentences what it is about."
                             : "Apple Intelligence reads the document on this Mac and lists the points that matter most.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // One above the other: side by side they do not fit in every language.
                Picker("Of", selection: $assistant.scope) {
                    Text(ReadingScope.document.title).tag(ReadingScope.document)
                    Text(ReadingScope.page.title).tag(ReadingScope.page)
                    if viewer.hasTextSelection || assistant.scope == .selection {
                        Text(ReadingScope.selection.title).tag(ReadingScope.selection)
                    }
                }
                .labelsHidden()
                Group {
                    if summary?.isRunning == true {
                        Button("Stop") { assistant.stop(kind) }
                    } else if summary == nil {
                        Button("Summarize") { assistant.summarize(kind, in: viewer) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(viewer.pageCount == 0)
                    } else {
                        Button("Again") { assistant.summarize(kind, in: viewer) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                EngineChoice(caution: "Check what matters against the document.")
            }
            .padding(12)
        }
    }
}

private struct AskView: View {
    @Bindable var viewer: ViewerModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var assistant = viewer.assistant
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if assistant.exchanges.isEmpty {
                            Text("Ask what the document says. Apple Intelligence answers on this Mac from the document's text, and names the pages the answer is from.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }
                        ForEach(assistant.exchanges) { exchange in
                            ExchangeView(viewer: viewer, exchange: exchange)
                                .id(exchange.id)
                        }
                    }
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.exchanges.last) {
                    if let last = assistant.exchanges.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Ask about this document", text: $assistant.question, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFieldFocused)
                        .onSubmit { assistant.ask(in: viewer) }
                    if assistant.isAnswering {
                        Button("Stop", systemImage: "stop.circle.fill") { assistant.stopAnswering() }
                            .help("Stop answering")
                    } else {
                        Button("Ask", systemImage: "arrow.up.circle.fill") { assistant.ask(in: viewer) }
                            .help("Ask")
                            .disabled(assistant.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewer.pageCount == 0)
                    }
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .imageScale(.large)
                EngineChoice(caution: "Answers can be wrong. Check the pages they name.")
                if !assistant.exchanges.isEmpty {
                    Button("Clear") { assistant.clearConversation() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(12)
        }
        .onAppear { isFieldFocused = true }
    }
}

private struct ExchangeView: View {
    let viewer: ViewerModel
    let exchange: AssistantModel.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exchange.question)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .padding(.horizontal, 2)
            if !exchange.answer.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(exchange.answer)
                            .textSelection(.enabled)
                            .lineSpacing(2)
                        if !exchange.pageIndexes.isEmpty {
                            // The pages the answer is from, each a way to go there.
                            HStack(spacing: 6) {
                                ForEach(exchange.pageIndexes, id: \.self) { pageIndex in
                                    Button("Page \(pageIndex + 1)") { viewer.goToPage(index: pageIndex) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help("Go to page \(pageIndex + 1)")
                                }
                            }
                        }
                    }
                }
            }
            if exchange.isRunning, exchange.answer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading…").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            if let failure = exchange.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
            if let note = exchange.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }
}
