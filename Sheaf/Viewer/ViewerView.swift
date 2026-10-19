import AppKit
import ImagePlayground
import SwiftUI
import TipKit

/// The viewer: sidebar, pages, toolbar, markup tools and inspector for one document.
struct ViewerView: View {
    @Bindable var viewer: ViewerModel
    let fileURL: URL?
    @FocusState private var isSearchFocused: Bool
    /// One tip at a time, in this order, each shown once.
    @State private var tips = TipGroup(.ordered) {
        EditTip()
        OrganizeTip()
        MarkupTip()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(viewer: viewer)
                .toolbar(removing: .sidebarToggle)
                // This has to be the outermost modifier to take effect.
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 380)
        } detail: {
            // The Format panel is a column beside the pages, so it starts under the
            // toolbar and under any row of tools, which run the width of the window.
            // SwiftUI's own inspector reaches up behind the toolbar instead.
            //
            // Nothing passes under the toolbar. It is see-through, so pages under one
            // part of it and the panel's backdrop under another showed as two toolbars
            // side by side. Now the window's own background is under all of it, with a
            // line below, in every mode.
            VStack(spacing: 0) {
                toolRows
                HStack(spacing: 0) {
                    pages
                        // A margin the strip stands in, so that it never covers a page; the
                        // panel of options does, while it is open.
                        .padding(viewer.toolsOnLeft ? .leading : .trailing, viewer.isOrganizing ? 0 : 64)
                        .background(Color(nsColor: viewer.pdfView.backgroundColor))
                        // The tools float over the pages at one side, as in Inkpage: the strip,
                        // the options of the tool in hand beside it, and the zoom at the foot.
                        .overlay(alignment: viewer.toolsOnLeft ? .topLeading : .topTrailing) {
                            if !viewer.isOrganizing {
                                GeometryReader { geometry in
                                    VStack(alignment: viewer.toolsOnLeft ? .leading : .trailing, spacing: 10) {
                                        ToolStrip(viewer: viewer, room: geometry.size.height - 24)
                                        Spacer(minLength: 0)
                                        ZoomCapsule(viewer: viewer)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: viewer.toolsOnLeft ? .topLeading : .topTrailing)
                                }
                            }
                        }
                    if viewer.isAssistantVisible {
                        AssistantPanel(viewer: viewer)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: viewer.isAssistantVisible)
        }
        .background(WindowReader { viewer.window = $0 })
        // Whether the file came out of a message in Mail, which File > Reply and closing ask about.
        .onChange(of: fileURL, initial: true) { viewer.refreshMailOrigin() }
        // Using a feature is the best sign its tip is no longer needed.
        .onChange(of: viewer.isContentEditing) { EditTip().invalidate(reason: .actionPerformed) }
        .onChange(of: viewer.isOrganizing) { OrganizeTip().invalidate(reason: .actionPerformed) }
        .onChange(of: viewer.isMarkupVisible) { MarkupTip().invalidate(reason: .actionPerformed) }
        .navigationSubtitle(viewer.pageSummary)
        .searchable(text: $viewer.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onChange(of: viewer.searchFocusRequests) { isSearchFocused = true }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SidebarMenu(viewer: viewer)
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isOrganizing) {
                    Label("Organize Pages", systemImage: "rectangle.grid.3x2")
                }
                .help("Rearrange, add and remove pages")
                .popoverTip(tips.currentTip as? OrganizeTip)
            }
            ToolbarItem {
                DocumentToolsMenu(viewer: viewer)
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
                Toggle(isOn: $viewer.isAssistantVisible) {
                    Label("Summary", systemImage: "apple.intelligence")
                }
                .help("Sum the document up and ask about it, with Apple Intelligence")
            }
        }
        // Reading aloud ends with the window.
        .onDisappear { viewer.pageReader.stop() }
        .sheet(item: $viewer.activeSheet) { sheet in
            switch sheet {
            case .watermark: WatermarkSheet(viewer: viewer)
            case .headerFooter: HeaderFooterSheet(viewer: viewer)
            case .bates: HeaderFooterSheet(viewer: viewer, bates: true)
            case .cropPages: CropPagesSheet(viewer: viewer)
            case .background: BackgroundSheet(viewer: viewer)
            case .hiddenInformation: HiddenInformationSheet(viewer: viewer)
            case .exportText: ExportSheet(viewer: viewer, kind: .text)
            case .exportRichText: ExportSheet(viewer: viewer, kind: .richText)
            case .exportWebPage: ExportSheet(viewer: viewer, kind: .webPage)
            case .info: DocumentInfoSheet(viewer: viewer)
            case .password: PasswordSheet(viewer: viewer)
            case .reduce: ReduceSheet(viewer: viewer)
            case .split: SplitSheet(viewer: viewer)
            case .blankPage: BlankPageSheet(viewer: viewer)
            case .working:
                ProgressView("Exporting…")
                    .padding(28)
                    .frame(width: 260)
                    .interactiveDismissDisabled()
            case .exportImages: ExportImagesSheet(viewer: viewer)
            case .scanner: ScannerSheet(viewer: viewer)
            case .recognize: RecognizeSheet(viewer: viewer)
            case .exportWord: ExportSheet(viewer: viewer, kind: .word)
            case .exportExcel: ExportSheet(viewer: viewer, kind: .excel)
            case .exportArchival: ExportSheet(viewer: viewer, kind: .archival)
            }
        }
        // Insert > Image Playground: the system's sheet, whose picture goes on the page.
        .imagePlaygroundSheet(isPresented: $viewer.isImagePlaygroundPresented, concepts: viewer.playgroundConcepts, sourceImage: viewer.playgroundSource) { url in
            viewer.addPlaygroundPicture(at: url)
        }
        .alert("Download Super Resolution?", isPresented: $viewer.isSuperResolutionDownloadPresented) {
            Button("Download") { viewer.downloadSuperResolutionAndEnlarge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS downloads what Super Resolution needs from Apple once. After that it works on this Mac, without the internet.")
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
        .alert("Redact what is marked?", isPresented: $viewer.isApplyRedactionsConfirmationPresented) {
            Button("Redact", role: .destructive) { viewer.applyRedactions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text, pictures and drawings under the \(viewer.redactionMarkCount) marks are removed from the document for good, not just covered. Copies of the file made earlier, and versions macOS has kept, are not changed.")
        }
        .alert("Edit", isPresented: Binding(get: { viewer.editMessage != nil }, set: { if !$0 { viewer.editMessage = nil } })) {
        } message: {
            Text(viewer.editMessage ?? "")
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

    /// Whatever row of tools is out, above the pages and the Format panel.
    @ViewBuilder private var toolRows: some View {
        // The line under the toolbar. A row of tools reads as part of the toolbar and has the line under itself.
        if !viewer.isReplaceVisible, !viewer.isOrganizing { Divider() }
        if viewer.isOrganizing {
            OrganizerBar(viewer: viewer)
            Divider()
        } else {
            if viewer.isReplaceVisible {
                ReplaceBar(viewer: viewer)
                Divider()
            }
        }
    }

    /// The pages, or the organizer.
    @ViewBuilder private var pages: some View {
        if viewer.isOrganizing {
            VStack(spacing: 0) {
                PageOrganizer(viewer: viewer)
                Divider()
                OrganizerStatusBar(viewer: viewer)
            }
        } else {
            PDFKitView(viewer: viewer)
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
struct WindowReader: NSViewRepresentable {
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

/// The tools that work on the whole document, in one menu of the toolbar, so that they are
/// at hand without searching the menu bar: shrinking, protecting, converting, stamping
/// every page, making scans searchable, comparing, running a flow.
private struct DocumentToolsMenu: View {
    @Bindable var viewer: ViewerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let editable = viewer.sheafDocument?.isEditable == true
        Menu {
            Section {
                Button("Reduce File Size…", systemImage: "arrow.down.right.and.arrow.up.left") { viewer.activeSheet = .reduce }
                    .disabled(!editable)
                Button(viewer.sheafDocument?.password == nil ? "Set Password…" : "Change Password…", systemImage: "lock") { viewer.activeSheet = .password }
                    .disabled(!editable)
                Button("Document Info…", systemImage: "info.circle") { viewer.activeSheet = .info }
            }
            Section {
                Button("Recognize Text…", systemImage: "text.viewfinder") { viewer.activeSheet = .recognize }
                    .disabled(!editable)
                Button("Watermark…", systemImage: "drop") { viewer.activeSheet = .watermark }
                    .disabled(!editable)
                Button("Header and Footer…", systemImage: "rectangle.topthird.inset.filled") { viewer.activeSheet = .headerFooter }
                    .disabled(!editable)
                Button("Bates Numbering…", systemImage: "number") { viewer.activeSheet = .bates }
                    .disabled(!editable)
                Button("Background…", systemImage: "rectangle.fill") { viewer.activeSheet = .background }
                    .disabled(!editable)
                Button("Crop Pages…", systemImage: "crop") { viewer.activeSheet = .cropPages }
                    .disabled(!editable)
                Button("Flatten Annotations…", systemImage: "square.3.layers.3d.down.right") { viewer.isFlattenConfirmationPresented = true }
                    .disabled(!editable)
            }
            Section {
                Button("Remove Hidden Information…", systemImage: "eye.slash") { viewer.activeSheet = .hiddenInformation }
                    .disabled(!editable)
                Button(viewer.isReadingAloud ? "Stop Reading Out Loud" : "Read Out Loud", systemImage: viewer.isReadingAloud ? "stop.circle" : "speaker.wave.2") { viewer.toggleReadingAloud() }
            }
            Section {
                Menu("Export To", systemImage: "square.and.arrow.up.on.square") {
                    Button("Word…") { viewer.activeSheet = .exportWord }
                    Button("Excel…") { viewer.activeSheet = .exportExcel }
                    Button("PDF/A…") { viewer.activeSheet = .exportArchival }
                    Button("Images…") { viewer.activeSheet = .exportImages }
                    Divider()
                    Button("Rich Text…") { viewer.activeSheet = .exportRichText }
                    Button("Web Page…") { viewer.activeSheet = .exportWebPage }
                    Button("Plain Text…") { viewer.activeSheet = .exportText }
                }
                Button("Split into Documents…", systemImage: "rectangle.split.2x1") { viewer.activeSheet = .split }
                    .disabled(viewer.pageCount < 2)
                Button("Compare with…", systemImage: "rectangle.on.rectangle.angled") { viewer.compareWithAnother() }
                Menu("Run Flow", systemImage: "point.3.connected.trianglepath.dotted") {
                    ForEach(FlowStore.shared.flows) { flow in
                        Button(flow.name) { viewer.run(flow) }
                            .disabled(flow.steps.isEmpty || !editable)
                    }
                    Divider()
                    Button("Edit Flows…") { openWindow(id: FlowsWindow.windowID) }
                }
            }
            Section {
                Button("Print…", systemImage: "printer") { viewer.printDocument() }
            }
        } label: {
            Label("Document Tools", systemImage: "wrench.and.screwdriver")
        }
        .help("Tools for the whole document: reduce its size, set a password, recognize text, convert, compare")
        .disabled(viewer.isOrganizing)
    }
}

