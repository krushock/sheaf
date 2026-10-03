import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The launch window: app identity and actions on the left, recent documents on the right.
struct WelcomeView: View {
    static let windowID = "welcome"

    @Environment(\.openDocument) private var openDocument
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preferences.welcomeShowsGrid) private var showsGrid = true
    @State private var recents: [URL] = []
    @State private var selection: URL?
    @State private var filter = ""

    var body: some View {
        HStack(spacing: 0) {
            identity
                .frame(width: 300)
                .frame(maxHeight: .infinity)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                recentDocuments
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 500)
        }
        // The panes run under the hidden title bar; the frame is the area below it.
        .ignoresSafeArea()
        .frame(height: 440)
        .onAppear(perform: refreshRecents)
        .onAppear { ToolInbox.shared.openWindow = openWindow }
        #if DEBUG
        .onAppear {
            DebugSnapshot.openWindow = openWindow
            DebugSnapshot.openSettingsIfRequested(openSettings)
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshRecents()
        }
    }

    // MARK: Left pane

    private var identity: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("Sheaf")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 4)
            Text("Version \(Self.version)")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                WelcomeAction("New Document", systemImage: "doc.badge.plus") {
                    NSDocumentController.shared.newDocument(nil)
                }
                WelcomeAction("Open…", systemImage: "folder") {
                    NSDocumentController.shared.openDocument(nil)
                }
                WelcomeAction("Merge PDFs…", systemImage: "doc.on.doc") {
                    openWindow(id: MergeWindow.windowID)
                }
                WelcomeAction("Images to PDF…", systemImage: "photo.on.rectangle") {
                    openWindow(id: ImagesWindow.windowID)
                }
                WelcomeAction("Reduce File Size…", systemImage: "arrow.down.right.and.arrow.up.left") {
                    open(with: .reduce)
                }
                WelcomeAction("Split a PDF…", systemImage: "square.split.2x1") {
                    open(with: .split)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    /// Asks for a PDF, opens it, and shows a tool on its window.
    private func open(with sheet: ToolSheet) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ToolInbox.shared.pendingSheets[url.standardizedFileURL] = sheet
        open(url)
    }

    // MARK: Right pane

    private var header: some View {
        HStack(spacing: 12) {
            Text("Recents")
                .font(.headline)
            Spacer()
            SearchField(text: $filter, prompt: String(localized: "Search"))
                .frame(width: 180)
            Picker("View", selection: $showsGrid) {
                Label("Icons", systemImage: "square.grid.2x2").tag(true)
                Label("List", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var visibleRecents: [URL] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recents }
        return recents.filter { $0.lastPathComponent.localizedStandardContains(query) }
    }

    @ViewBuilder private var recentDocuments: some View {
        let urls = visibleRecents
        if recents.isEmpty {
            ContentUnavailableView(
                "No Recent Documents",
                systemImage: "clock",
                description: Text("PDFs you open appear here.")
            )
        } else if urls.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else if showsGrid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8, alignment: .top)], spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        RecentDocumentCell(url: url, isSelected: selection == url)
                            .onTapGesture(count: 2) { open(url) }
                            .simultaneousGesture(TapGesture().onEnded { selection = url })
                            .contextMenu { menu(for: url) }
                    }
                }
                .padding(12)
            }
        } else {
            List(urls, id: \.self, selection: $selection) { url in
                RecentDocumentRow(url: url)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first { menu(for: url) }
            } primaryAction: { urls in
                urls.first.map(open)
            }
        }
    }

    @ViewBuilder private func menu(for url: URL) -> some View {
        Button("Open") { open(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
            } catch {
                NSApp.presentError(error)
                refreshRecents()
            }
        }
    }

    private func refreshRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// One of the actions listed on the left of the Welcome window.
private struct WelcomeAction: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(.rect)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A recent document in the icon view.
private struct RecentDocumentCell: View {
    let url: URL
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            FileThumbnail(url: url, size: CGSize(width: 84, height: 104))
                .padding(6)
                .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(url.path(percentEncoded: false))
    }
}

/// A recent document in the list view.
private struct RecentDocumentRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            FileThumbnail(url: url, size: CGSize(width: 30, height: 36))
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Text((url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 2)
    }
}
