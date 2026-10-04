import AppKit
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
                    if viewer.isInspectorVisible {
                        FormatPanel(viewer: viewer)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: viewer.isInspectorVisible)
        }
        .background(WindowReader { viewer.window = $0 })
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
                ZoomMenu(viewer: viewer)
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isOrganizing) {
                    Label("Organize Pages", systemImage: "rectangle.grid.3x2")
                }
                .help("Rearrange, add and remove pages")
                .popoverTip(tips.currentTip as? OrganizeTip)
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isMarkupVisible) {
                    Label("Markup", systemImage: "pencil.tip.crop.circle")
                }
                .help("Show the markup tools")
                .disabled(viewer.sheafDocument?.isEditable != true || viewer.isOrganizing)
                .popoverTip(tips.currentTip as? MarkupTip)
            }
            ToolbarItem {
                Toggle(isOn: $viewer.isContentEditing) {
                    Label("Edit", systemImage: "character.cursor.ibeam")
                }
                .help("Change the text and pictures on the pages")
                .disabled(viewer.sheafDocument?.isEditable != true || viewer.isOrganizing)
                .popoverTip(tips.currentTip as? EditTip)
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
        if !viewer.hasToolRow, !viewer.isOrganizing { Divider() }
        if viewer.isOrganizing {
            OrganizerBar(viewer: viewer)
            Divider()
        } else {
            if viewer.isFormEditing {
                FormBar(viewer: viewer)
                Divider()
            } else if viewer.isMarkupVisible {
                MarkupBar(viewer: viewer)
                Divider()
            } else if viewer.isContentEditing {
                EditBar(viewer: viewer)
                Divider()
            }
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

/// The Format panel: a column on the right, under the toolbar, that looks like the
/// system's inspector does: a light gray a step off the window's own, with the groups
/// of controls a step darker on it.
private struct FormatPanel: View {
    let viewer: ViewerModel

    var body: some View {
        InspectorView(viewer: viewer)
            // The forms inside bring a background of their own, which would hide the panel's.
            .scrollContentBackground(.hidden)
            .frame(width: 280)
            .frame(maxHeight: .infinity)
            // As views, not as a style: a style would fill up behind the toolbar as well.
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Color.primary.opacity(0.06)
                }
            }
            .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
    }
}

/// The zoom menu in the toolbar: it shows the zoom and offers the page layout, a list
/// of zoom levels, and fitting to the window, as the one in Pages does.
private struct ZoomMenu: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        Menu {
            Picker("Page layout", selection: $viewer.layout) {
                ForEach(PageLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            ForEach(ViewerModel.zoomSteps, id: \.self) { percent in
                Toggle(isOn: Binding(get: { viewer.isZoomed(to: percent) }, set: { _ in viewer.setZoom(percent: percent) })) {
                    Text(Double(percent) / 100, format: .percent)
                }
            }

            Divider()

            Toggle("Fit Width", isOn: Binding(get: { viewer.isFitToWindow }, set: { _ in viewer.zoomToFit() }))
            Toggle("Fit Page", isOn: Binding(get: { viewer.isFitPage }, set: { _ in viewer.zoomToFitPage() }))
        } label: {
            Text(Double(viewer.zoomPercent) / 100, format: .percent)
                .monospacedDigit()
        }
        .help("Zoom")
        .accessibilityLabel("Zoom")
        .accessibilityValue(Text(Double(viewer.zoomPercent) / 100, format: .percent))
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
