import SwiftUI

/// Menu bar commands that act on the frontmost document window.
struct SheafCommands: Commands {
    @FocusedValue(ViewerModel.self) private var viewer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New from PDFs…") { openWindow(id: MergeWindow.windowID) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New from Images…") { openWindow(id: ImagesWindow.windowID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Group {
                Button("Export…") { viewer?.export() }
                Button("Export as Images…") { viewer?.activeSheet = .exportImages }
                Button("Split into Documents…") { viewer?.activeSheet = .split }
                    .disabled((viewer?.pageCount ?? 0) < 2)

                Divider()

                Button("Reduce File Size…") { viewer?.activeSheet = .reduce }
                    .disabled(viewer?.canEditPages != true)
                Button(viewer?.sheafDocument?.password == nil ? "Set Password…" : "Change Password…") { viewer?.activeSheet = .password }
                    .disabled(viewer?.canEditPages != true)
                Button("Document Info…") { viewer?.activeSheet = .info }
                    .keyboardShortcut("i")
            }
            .disabled(viewer == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { viewer?.printDocument() }
                .keyboardShortcut("p")
                .disabled(viewer == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Insert") {
                Button("Blank Page") { viewer?.insertBlankPage() }
                Button("Pages from File…") { viewer?.chooseFilesToInsert() }
                Button("Pages from Scanner…") { viewer?.activeSheet = .scanner }
            }
            .disabled(viewer?.canEditPages != true)
            Menu("Find") {
                Button("Find…") { viewer?.focusSearchField() }
                    .keyboardShortcut("f")
                Button("Find Next") { viewer?.selectNextSearchResult() }
                    .keyboardShortcut("g")
                    .disabled(viewer?.searchResults.isEmpty ?? true)
                Button("Find Previous") { viewer?.selectPreviousSearchResult() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(viewer?.searchResults.isEmpty ?? true)
            }
            .disabled(viewer == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Group {
                Toggle("Hide Sidebar", isOn: binding(false) { !$0.isSidebarVisible } set: { $0.isSidebarVisible = !$1 })
                    .keyboardShortcut("1", modifiers: [.command, .option])
                ForEach(Array(SidebarMode.allCases.enumerated()), id: \.element) { offset, mode in
                    Toggle(mode.title, isOn: binding(false) { $0.isSidebarVisible && $0.sidebarMode == mode } set: { viewer, _ in viewer.showSidebar(mode) })
                        .keyboardShortcut(KeyEquivalent(Character("\(offset + 2)")), modifiers: [.command, .option])
                }

                Toggle("Organize Pages", isOn: binding(false) { $0.isOrganizing } set: { $0.isOrganizing = $1 })
                    .keyboardShortcut("o", modifiers: [.command, .option])

                Divider()

                ForEach(Array(PageLayout.allCases.enumerated()), id: \.element) { offset, layout in
                    Toggle(layout.title, isOn: binding(false) { $0.layout == layout } set: { viewer, _ in viewer.layout = layout })
                        .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")))
                }

                Divider()

                Button("Actual Size") { viewer?.zoomToActualSize() }
                    .keyboardShortcut("0")
                Toggle("Zoom to Fit", isOn: binding(false) { $0.isFitToWindow } set: { viewer, _ in viewer.zoomToFit() })
                    .keyboardShortcut("9")
                Button("Zoom In") { viewer?.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!(viewer?.canZoomIn ?? false))
                Button("Zoom Out") { viewer?.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!(viewer?.canZoomOut ?? false))

                Divider()
            }
            .disabled(viewer == nil)
        }

        InspectorCommands()
        ImportFromDevicesCommands()

        CommandMenu("Tools") {
            Group {
                Toggle("Show Markup Toolbar", isOn: binding(false) { $0.isMarkupVisible } set: { $0.isMarkupVisible = $1 })
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                Menu("Annotate") {
                    tool(.highlight, "h")
                    tool(.underline, "u")
                    tool(.strikeOut, "s")
                    Divider()
                    tool(.rectangle, "r")
                    tool(.ellipse, "o")
                    tool(.line, "i")
                    tool(.arrow, "a")
                    tool(.draw, "d")
                    Divider()
                    tool(.text, "t")
                    tool(.note, "n")
                    tool(.link, "k")
                }

                Divider()

                Button("Add Bookmark") { viewer?.addBookmark() }
                    .keyboardShortcut("d")

                Divider()

                Button("Flatten Annotations…") { viewer?.isFlattenConfirmationPresented = true }

                Divider()

                Menu("Form") {
                    Toggle("Show Form Toolbar", isOn: binding(false) { $0.isFormEditing } set: { $0.isFormEditing = $1 })
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                    Menu("Add Field") {
                        ForEach(FormTool.allCases) { tool in
                            Button(tool.title) {
                                viewer?.isFormEditing = true
                                viewer?.formTool = tool
                            }
                        }
                    }
                    Button("Detect Fields on This Page") {
                        viewer?.isFormEditing = true
                        viewer?.detectFields()
                    }
                    Divider()
                    Toggle("Highlight Fields", isOn: binding(true) { $0.highlightsFields } set: { $0.highlightsFields = $1 })
                    Button("Next Field") { viewer?.focusNextField() }
                        .disabled(viewer?.hasForm != true)
                    Divider()
                    Button("Reset Form…") { viewer?.isResetFormConfirmationPresented = true }
                        .disabled(viewer?.hasForm != true)
                    Button("Flatten Form…") { viewer?.isFlattenFormConfirmationPresented = true }
                        .disabled(viewer?.hasForm != true)
                }

                Divider()

                Button("Rotate Left") { viewer.map { $0.rotatePages($0.targetPageIndexes, by: -90) } }
                    .keyboardShortcut("l")
                Button("Rotate Right") { viewer.map { $0.rotatePages($0.targetPageIndexes, by: 90) } }
                    .keyboardShortcut("r")
                Menu("Pages") {
                    Button("Duplicate") { viewer.map { $0.duplicatePages($0.targetPageIndexes) } }
                    Button("Delete") { viewer.map { $0.deletePages($0.targetPageIndexes) } }
                        .disabled(viewer?.canDeleteTargetPages != true)
                    Divider()
                    Button("Split Down the Middle") { viewer.map { $0.splitPagesInHalf($0.targetPageIndexes, direction: .vertical) } }
                    Button("Split Across the Middle") { viewer.map { $0.splitPagesInHalf($0.targetPageIndexes, direction: .horizontal) } }
                    Divider()
                    Button("Open as New Document") { viewer.map { $0.extractPages($0.targetPageIndexes) } }
                }
                .disabled(viewer?.targetPageIndexes.isEmpty ?? true)

                Divider()

                Button("Watermark…") { viewer?.activeSheet = .watermark }
                Button("Header and Footer…") { viewer?.activeSheet = .headerFooter }
            }
            .disabled(viewer?.sheafDocument?.isEditable != true)
        }

        CommandMenu("Go") {
            Group {
                Button("Previous Page") { viewer?.goToPreviousPage() }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                    .disabled((viewer?.currentPageIndex ?? 0) == 0)
                Button("Next Page") { viewer?.goToNextPage() }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                    .disabled((viewer?.currentPageIndex ?? 0) + 1 >= (viewer?.pageCount ?? 0))
                Button("First Page") { viewer?.goToFirstPage() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Last Page") { viewer?.goToLastPage() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Divider()

                Button("Back") { viewer?.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!(viewer?.canGoBack ?? false))
                Button("Forward") { viewer?.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!(viewer?.canGoForward ?? false))

                Divider()

                Button("Go to Page…") { viewer?.isGoToPagePresented = true }
                    .keyboardShortcut("g", modifiers: [.command, .option])
            }
            .disabled(viewer == nil)
        }
    }

    /// A menu item that picks an annotation tool, showing the markup toolbar if needed.
    private func tool(_ tool: MarkupTool, _ key: Character) -> some View {
        Button(tool.title) {
            guard let viewer else { return }
            // With text selected, the text tools mark it straight away.
            if let kind = tool.textMarkupKind, viewer.pdfView.currentSelection?.string?.isEmpty == false {
                viewer.applyTextMarkup(kind)
                return
            }
            viewer.isMarkupVisible = true
            viewer.tool = tool
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .control])
    }

    /// A binding onto the focused viewer that reads as `fallback` when no document is in front.
    private func binding<Value>(
        _ fallback: Value,
        get: @escaping (ViewerModel) -> Value,
        set: @escaping (ViewerModel, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { viewer.map(get) ?? fallback },
            set: { value in if let viewer { set(viewer, value) } }
        )
    }
}
