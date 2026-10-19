import SheafKit
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
            Divider()
            Button("Compare Documents…") { openWindow(id: CompareWindow.windowID) }
            Button("Flows…") { openWindow(id: FlowsWindow.windowID) }
        }

        CommandGroup(after: .saveItem) {
            Group {
                Button("Export…") { viewer?.export() }
                Menu("Export To") {
                    Button("Word…") { viewer?.activeSheet = .exportWord }
                    Button("Excel…") { viewer?.activeSheet = .exportExcel }
                    Button("PDF/A…") { viewer?.activeSheet = .exportArchival }
                    Divider()
                    Button("Rich Text…") { viewer?.activeSheet = .exportRichText }
                    Button("Web Page…") { viewer?.activeSheet = .exportWebPage }
                    Button("Plain Text…") { viewer?.activeSheet = .exportText }
                }
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
                // For a document opened from a message in Mail: send it back to whoever sent it.
                // Always in the menu, and dimmed for documents that did not come from Mail.
                Divider()
                // Who the sender is, is asked of Mail when the command is chosen.
                Button("Reply to Sender…") { viewer?.replyInMail() }
                    .disabled(viewer?.mailOrigin == nil || !MailReply.canCompose)
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
                if let viewer {
                    BlankPageMenu("Blank Page", viewer: viewer)
                } else {
                    Button("Blank Page") {}
                }
                Button("Pages from File…") { viewer?.chooseFilesToInsert() }
                Button("Pages from Scanner…") { viewer?.activeSheet = .scanner }
                Divider()
                Button("Text") {
                    viewer?.isContentEditing = true
                    viewer?.editTool = .text
                }
                Button("Picture…") { viewer?.choosePictureToAdd() }
                // As in Pages: a picture made on this Mac from a description, or from the
                // text or picture that is selected.
                Button("Image Playground…", systemImage: "apple.image.playground") { viewer?.openImagePlayground() }
                    .disabled(viewer?.offersImagePlayground != true)
            }
            .disabled(viewer?.canEditPages != true)
            WritingToolsMenu()
            // Command-D does this while text or a picture is selected; see SheafPDFView.
            Button("Duplicate") { viewer?.duplicateContentSelection() }
                .disabled(viewer?.canArrangeContent != true)
            Menu("Find") {
                Button("Find…") { viewer?.focusSearchField() }
                    .keyboardShortcut("f")
                Button("Find Next") { viewer?.selectNextSearchResult() }
                    .keyboardShortcut("g")
                    .disabled(viewer?.searchResults.isEmpty ?? true)
                Button("Find Previous") { viewer?.selectPreviousSearchResult() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(viewer?.searchResults.isEmpty ?? true)
                Divider()
                Button("Find and Replace…") { viewer?.showReplace() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(viewer?.sheafDocument?.isEditable != true)
            }
            .disabled(viewer == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Group {
                Toggle("Hide Sidebar", isOn: binding(false) { !$0.isSidebarVisible } set: { $0.setSidebarVisible(!$1) })
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
                Toggle("Fit Width", isOn: binding(false) { $0.isFitToWindow } set: { viewer, _ in viewer.zoomToFit() })
                    .keyboardShortcut("9")
                Toggle("Fit Page", isOn: binding(false) { $0.isFitPage } set: { viewer, _ in viewer.zoomToFitPage() })
                    .keyboardShortcut("8")
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

        // The options panel beside the tools, and the Summary column.
        CommandGroup(before: .sidebar) {
            Button(viewer?.isInspectorVisible == true ? "Hide Options" : "Show Options") { withAnimation(.easeOut(duration: 0.15)) { viewer?.isInspectorVisible.toggle() } }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(viewer == nil)
            Button(viewer?.isAssistantVisible == true ? "Hide Summary" : "Show Summary") { viewer?.isAssistantVisible.toggle() }
                .keyboardShortcut("u", modifiers: [.command, .control])
                .disabled(viewer == nil)
            Button(viewer?.isReadingAloud == true ? "Stop Reading Out Loud" : "Read Out Loud") { viewer?.toggleReadingAloud() }
                .disabled(viewer == nil)
        }
        ImportFromDevicesCommands()

        CommandMenu("Arrange") {
            let moves = viewer?.stackingMoves ?? []
            // The order and the shortcuts are those of the Arrange menu in Pages.
            Button(StackingMove.forward.title) { viewer?.restackSelection(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift, .option])
                .disabled(!moves.contains(.forward))
            Button(StackingMove.toFront.title) { viewer?.restackSelection(.toFront) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!moves.contains(.toFront))
            Button(StackingMove.backward.title) { viewer?.restackSelection(.backward) }
                .keyboardShortcut("b", modifiers: [.command, .shift, .option])
                .disabled(!moves.contains(.backward))
            Button(StackingMove.toBack.title) { viewer?.restackSelection(.toBack) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!moves.contains(.toBack))

            Divider()

            Menu("Align on Page") {
                ForEach(PageAlignment.allCases) { alignment in
                    if alignment == .top { Divider() }
                    Button(alignment.title, systemImage: alignment.systemImage) { viewer?.alignSelection(alignment) }
                }
            }
            .disabled(viewer?.canArrangeContent != true)

            Divider()

            Button("Rotate Left") { viewer?.rotateSelectedPicture(by: 90) }
                .disabled(viewer?.canArrangeContent != true || viewer?.selectedImage == nil)
            Button("Rotate Right") { viewer?.rotateSelectedPicture(by: -90) }
                .disabled(viewer?.canArrangeContent != true || viewer?.selectedImage == nil)
            Button("Flip Horizontally") { viewer?.flipSelectedPicture(horizontally: true) }
                .disabled(viewer?.canArrangeContent != true || viewer?.selectedImage == nil)
            Button("Flip Vertically") { viewer?.flipSelectedPicture(horizontally: false) }
                .disabled(viewer?.canArrangeContent != true || viewer?.selectedImage == nil)

            Divider()

            Button("Edit Mask") { viewer?.beginMaskEditing() }
                .disabled(viewer?.canArrangeContent != true || viewer?.selectedImage == nil)
            Button("Reset Mask") { viewer?.resetMask() }
                .disabled(viewer?.selectedImage?.shownPart == nil && viewer?.maskEdit == nil)
            Button("Auto Crop") { viewer?.autoCropSelectedPicture() }
                .disabled(viewer?.canArrangeContent != true || viewer?.selectedImage?.isEditable != true || viewer?.pictureWork != nil)
        }

        CommandMenu("Tools") {
            // Reading a document changes nothing in it, so these work on a locked one too.
            Button("Summarize", systemImage: "apple.intelligence") { viewer?.summarizeDocument() }
                .disabled(viewer == nil)
            Divider()
            Group {
                // The tools of the strip at the side of the pages.
                Toggle("Select", isOn: binding(false) { $0.hand == .pointer } set: { viewer, _ in viewer.take(.pointer) })
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                Toggle("Edit Text and Pictures", isOn: binding(false) { $0.hand == .edit } set: { viewer, on in viewer.take(on ? .edit : .pointer) })
                    .keyboardShortcut("e", modifiers: [.command, .shift])

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
                    // Shift-Command-F is Bring to Front, as in Pages.
                    Toggle("Edit Form Fields", isOn: binding(false) { $0.hand == .form } set: { viewer, on in viewer.take(on ? .form : .pointer) })
                        .keyboardShortcut("m", modifiers: [.command, .shift])
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

                Menu("Redact") {
                    Button("Mark Selected Text") { viewer?.markSelectionForRedaction() }
                        .disabled(viewer?.hasTextSelection != true)
                    Button("Draw Marks") {
                        viewer?.isContentEditing = true
                        viewer?.editTool = .redact
                    }
                    Menu("Find and Mark") {
                        ForEach(RedactionPattern.allCases) { pattern in
                            Button(pattern.title) {
                                viewer?.isContentEditing = true
                                viewer?.markForRedaction(pattern)
                            }
                        }
                    }
                    Divider()
                    Toggle("Preview Redactions", isOn: binding(false) { $0.previewsRedactions } set: { $0.previewsRedactions = $1 })
                        .disabled((viewer?.redactionMarkCount ?? 0) == 0)
                    Button("Remove All Marks") { viewer?.removeRedactionMarks() }
                        .disabled((viewer?.redactionMarkCount ?? 0) == 0)
                    Button("Apply Redactions…") { viewer?.isApplyRedactionsConfirmationPresented = true }
                        .disabled((viewer?.redactionMarkCount ?? 0) == 0)
                }

                Button("Recognize Text…") { viewer?.activeSheet = .recognize }

                Button("Compare with…") { viewer?.compareWithAnother() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])

                Menu("Run Flow") {
                    ForEach(FlowStore.shared.flows) { flow in
                        Button(flow.name) { viewer?.run(flow) }
                            .disabled(flow.steps.isEmpty)
                    }
                    Divider()
                    Button("Edit Flows…") { openWindow(id: FlowsWindow.windowID) }
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
                Button("Bates Numbering…") { viewer?.activeSheet = .bates }
                Button("Background…") { viewer?.activeSheet = .background }
                Button("Crop Pages…") { viewer?.activeSheet = .cropPages }

                Divider()

                Button("Remove Hidden Information…") { viewer?.activeSheet = .hiddenInformation }
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

/// Edit > Writing Tools, as other apps have it: the system's own list, which works on the
/// text being edited and on text selected on a page. The items are AppKit's, with their
/// own names in the person's language; each is sent down the responder chain as it is.
private struct WritingToolsMenu: View {
    var body: some View {
        if let menu = NSMenuItem.writingToolsItems.first, let items = menu.submenu?.items {
            Menu {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if item.isSeparatorItem {
                        Divider()
                    } else {
                        Button {
                            NSApp.sendAction(#selector(NSResponder.showWritingTools(_:)), to: nil, from: item)
                        } label: {
                            Text(verbatim: item.title)
                        }
                    }
                }
            } label: {
                Label {
                    Text(verbatim: menu.title)
                } icon: {
                    Image(systemName: "apple.writing.tools")
                }
            }
        }
    }
}
