import AppKit
import SwiftUI

/// The viewer: sidebar, pages, toolbar, markup tools and inspector for one document.
struct ViewerView: View {
    @Bindable var viewer: ViewerModel
    let fileURL: URL?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(viewer: viewer)
                .toolbar(removing: .sidebarToggle)
                // This has to be the outermost modifier to take effect.
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if viewer.isOrganizing {
                    OrganizerBar(viewer: viewer)
                    Divider()
                    PageOrganizer(viewer: viewer)
                    Divider()
                    OrganizerStatusBar(viewer: viewer)
                } else {
                    if viewer.isFormEditing {
                        FormBar(viewer: viewer)
                        Divider()
                    } else if viewer.isMarkupVisible {
                        MarkupBar(viewer: viewer)
                        Divider()
                    }
                    PDFKitView(viewer: viewer)
                        // Pages scroll under the toolbar, except when a row of tools sits in between.
                        .ignoresSafeArea(edges: viewer.isMarkupVisible || viewer.isFormEditing ? [] : .top)
                }
            }
            .inspector(isPresented: $viewer.isInspectorVisible) {
                InspectorView(viewer: viewer)
                    .inspectorColumnWidth(min: 240, ideal: 270, max: 340)
            }
        }
        .background(WindowReader { viewer.window = $0 })
        .navigationSubtitle(viewer.pageSummary)
        .searchable(text: $viewer.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onChange(of: viewer.searchFocusRequests) { isSearchFocused = true }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SidebarMenu(viewer: viewer)
            }
            ToolbarItem {
                ControlGroup {
                    Button("Zoom Out", systemImage: "minus.magnifyingglass", action: viewer.zoomOut)
                        .disabled(!viewer.canZoomOut)
                    Button("Zoom In", systemImage: "plus.magnifyingglass", action: viewer.zoomIn)
                        .disabled(!viewer.canZoomIn)
                }
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isOrganizing) {
                    Label("Organize Pages", systemImage: "rectangle.grid.3x2")
                }
                .help("Rearrange, add and remove pages")
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isMarkupVisible) {
                    Label("Markup", systemImage: "pencil.tip.crop.circle")
                }
                .help("Show the markup tools")
                .disabled(viewer.sheafDocument?.isEditable != true || viewer.isOrganizing)
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isFormEditing) {
                    Label("Form", systemImage: "rectangle.and.pencil.and.ellipsis")
                }
                .help("Add and change form fields")
                .disabled(viewer.sheafDocument?.isEditable != true || viewer.isOrganizing)
            }
            ToolbarItem {
                if let fileURL {
                    ShareLink(item: fileURL)
                } else {
                    Button("Share", systemImage: "square.and.arrow.up") {}
                        .disabled(true)
                        .help("Save the document to share it")
                }
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isInspectorVisible) {
                    Label("Format", systemImage: "paintbrush")
                }
                .help("Show or hide the Format panel")
            }
        }
        .sheet(item: $viewer.activeSheet) { sheet in
            switch sheet {
            case .watermark: WatermarkSheet(viewer: viewer)
            case .headerFooter: HeaderFooterSheet(viewer: viewer)
            case .info: DocumentInfoSheet(viewer: viewer)
            case .password: PasswordSheet(viewer: viewer)
            case .reduce: ReduceSheet(viewer: viewer)
            case .split: SplitSheet(viewer: viewer)
            case .exportImages: ExportImagesSheet(viewer: viewer)
            case .scanner: ScannerSheet(viewer: viewer)
            }
        }
        // File > Import from iPhone or iPad delivers photos and scans here as new pages.
        .importsItemProviders([.pdf, .image]) { providers in
            guard viewer.canEditPages, !providers.isEmpty else { return false }
            viewer.insertImported(providers)
            return true
        }
        .alert("Go to Page", isPresented: $viewer.isGoToPagePresented) {
            GoToPageFields(viewer: viewer)
        } message: {
            Text("Enter a page number from 1 to \(viewer.pageCount).")
        }
        .alert("Reset the form?", isPresented: $viewer.isResetFormConfirmationPresented) {
            Button("Reset") { viewer.resetForm() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every field goes back to what it started with, or is emptied.")
        }
        .alert("Flatten the form?", isPresented: $viewer.isFlattenFormConfirmationPresented) {
            Button("Flatten") { viewer.flattenForm() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What is filled in becomes part of the pages. The fields are removed and can no longer be changed.")
        }
        .alert("Detect Fields", isPresented: Binding(get: { viewer.detectionMessage != nil }, set: { if !$0 { viewer.detectionMessage = nil } })) {
        } message: {
            Text(viewer.detectionMessage ?? "")
        }
        .sheet(isPresented: $viewer.isSignatureCreatorPresented, onDismiss: { viewer.signatureTarget = nil }) {
            SignatureCreator { signature in
                SignatureStore.shared.add(signature)
                viewer.place(signature)
            }
        }
        .alert("Flatten all annotations?", isPresented: $viewer.isFlattenConfirmationPresented) {
            Button("Flatten") { viewer.flattenAnnotations() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Highlights, notes, drawings and stamps become part of the pages and can no longer be changed. Links stay as they are.")
        }
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { viewer.isSidebarVisible ? .all : .detailOnly },
            set: { viewer.isSidebarVisible = $0 != .detailOnly }
        )
    }
}

private struct GoToPageFields: View {
    let viewer: ViewerModel
    @State private var pageText = ""

    var body: some View {
        TextField("Page", text: $pageText)
        Button("Go") {
            if let number = Int(pageText.trimmingCharacters(in: .whitespaces)) {
                viewer.goToPage(index: min(max(number, 1), viewer.pageCount) - 1)
            }
        }
        .keyboardShortcut(.defaultAction)
        Button("Cancel", role: .cancel) {}
    }
}

/// Tells its owner which window it is in.
private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}
