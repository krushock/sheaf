import AppKit
import PDFKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

extension ToolInbox {
    /// Hands documents to the Compare window and shows it.
    func compare(original: CompareSource?, revised: CompareSource?) {
        pendingComparison = (original, revised)
        open(CompareWindow.windowID)
    }
}

extension DocumentChange.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .inserted: "Added"
        case .deleted: "Removed"
        case .replaced: "Changed"
        case .pageAdded: "Page added"
        case .pageRemoved: "Page removed"
        case .appearance: "Looks different"
        }
    }

    var systemImage: String {
        switch self {
        case .inserted: "plus.circle.fill"
        case .deleted: "minus.circle.fill"
        case .replaced: "arrow.left.arrow.right.circle.fill"
        case .pageAdded: "doc.badge.plus"
        case .pageRemoved: "doc.badge.minus"
        case .appearance: "eye.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .inserted, .pageAdded: .green
        case .deleted, .pageRemoved: .red
        case .replaced: .blue
        case .appearance: .orange
        }
    }
}

/// Tools > Compare Documents: two documents side by side with their differences marked.
struct CompareWindow: View {
    static let windowID = "compare"

    @State private var model = CompareModel()
    @State private var window: NSWindow?

    var body: some View {
        NavigationSplitView {
            changeList
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            if model.isReady, model.comparison != nil {
                HStack(spacing: 0) {
                    side(.original, view: model.originalView)
                    Divider()
                    side(.revised, view: model.revisedView)
                }
            } else {
                chooser
            }
        }
        .background(WindowReader { window = $0 })
        .navigationTitle("Compare Documents")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                ControlGroup {
                    Button("Previous Difference", systemImage: "chevron.up") { model.step(-1) }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button("Next Difference", systemImage: "chevron.down") { model.step(1) }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                }
                .disabled(model.changes.isEmpty)
            }
            ToolbarItem {
                Toggle(isOn: $model.syncsScrolling) {
                    Label("Scroll Together", systemImage: "arrow.up.and.down.text.horizontal")
                }
                .help("Scroll both documents together")
            }
            ToolbarItem {
                Button("Swap Sides", systemImage: "arrow.left.arrow.right") { model.swapSides() }
                    .disabled(!model.isReady)
                    .help("Make the revised document the original, and the other way around")
            }
            ToolbarItem {
                Button("Export Report…", systemImage: "square.and.arrow.up") { model.exportReport(from: window) }
                    .disabled(model.comparison == nil)
                    .help("Save the list of differences as a PDF")
            }
        }
        .alert("Compare Documents", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear(perform: takePending)
        .onChange(of: ToolInbox.shared.comparisonRequests) { takePending() }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var subtitle: String {
        guard model.comparison != nil else { return "" }
        let count = model.changes.count
        return count == 0 ? String(localized: "No differences") : String(localized: "\(count) differences")
    }

    private func takePending() {
        guard let pending = ToolInbox.shared.pendingComparison else { return }
        ToolInbox.shared.pendingComparison = nil
        if let original = pending.original { model.set(original, as: .original) }
        if let revised = pending.revised { model.set(revised, as: .revised) }
    }

    // MARK: Parts

    @ViewBuilder private var changeList: some View {
        if let progress = model.progress {
            VStack(spacing: 12) {
                ProgressView(value: progress) { Text("Comparing…") }
                Button("Stop") { model.cancel() }
            }
            .padding(20)
            .frame(maxHeight: .infinity)
        } else if model.comparison == nil {
            ContentUnavailableView("No Comparison Yet", systemImage: "doc.on.doc", description: Text("Choose two documents to see how they differ."))
        } else if model.changes.isEmpty {
            ContentUnavailableView("No Differences", systemImage: "checkmark.circle", description: Text("The two documents read and look the same."))
        } else {
            List(model.changes, selection: $model.selection) { change in
                ChangeRow(change: change)
            }
        }
    }

    private func side(_ side: CompareModel.Side, view: PDFView) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(side == .original ? "Original" : "Revised")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.name(side))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Change…") { model.choose(side) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.bar)
            Divider()
            PlainPDFView(view: view)
        }
    }

    private var chooser: some View {
        HStack(spacing: 20) {
            well(.original, title: "Original", detail: "The earlier version")
            Image(systemName: "arrow.right")
                .font(.title2)
                .foregroundStyle(.tertiary)
            well(.revised, title: "Revised", detail: "The later version")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func well(_ side: CompareModel.Side, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let name = model.name(side)
        return VStack(spacing: 10) {
            Image(systemName: name.isEmpty ? "doc.badge.plus" : "doc.text.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            Text(title).font(.headline)
            (name.isEmpty ? Text(detail) : Text(name))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button(name.isEmpty ? "Choose…" : "Change…") { model.choose(side) }
        }
        .frame(width: 220, height: 190)
        .background(.quinary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }) else { return false }
            model.load(url, as: side)
            return true
        }
        .accessibilityElement(children: .combine)
    }
}

/// One difference in the list.
private struct ChangeRow: View {
    let change: DocumentChange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: change.kind.systemImage)
                .foregroundStyle(change.kind.tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(change.kind.title).font(.callout.weight(.medium))
                    Spacer()
                    Text(page).font(.caption).foregroundStyle(.secondary)
                }
                if !change.textA.isEmpty {
                    Text(change.textA)
                        .strikethrough(change.kind == .replaced || change.kind == .deleted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !change.textB.isEmpty {
                    Text(change.textB)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var page: String {
        let number = (change.pageB ?? change.pageA ?? 0) + 1
        return String(localized: "Page \(number)")
    }
}

/// A `PDFView` that only shows pages.
struct PlainPDFView: NSViewRepresentable {
    let view: PDFView

    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ view: PDFView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 500))
    }
}
