import SwiftUI

/// The content of one document window.
struct DocumentWindow: View {
    let document: SheafDocument
    let fileURL: URL?
    @State private var viewer = ViewerModel()
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        content
            .frame(minWidth: 520, minHeight: 380)
            .focusedSceneValue(isShowingPages ? viewer : nil)
            .onChange(of: undoManager, initial: true) { document.undoManager = undoManager }
            .onChange(of: document.revision) { viewer.documentDidChange() }
            .onAppear {
                dismissWindow(id: WelcomeView.windowID)
                ToolInbox.shared.openWindow = openWindow
                #if DEBUG
                DebugSnapshot.openWindow = openWindow
                DebugSnapshot.openSettingsIfRequested(openSettings)
                #endif
            }
            // Revert hands this view a new document object; unlocking bumps the generation.
            .task(id: DocumentState(object: ObjectIdentifier(document), generation: document.generation)) {
                showDocument()
            }
    }

    @ViewBuilder private var content: some View {
        if let pdf = document.pdf {
            if pdf.isLocked {
                PasswordPrompt(document: document)
            } else {
                ViewerView(viewer: viewer, fileURL: fileURL)
            }
        } else {
            Color.clear
        }
    }

    private var isShowingPages: Bool {
        document.pdf?.isLocked == false
    }

    private func showDocument() {
        document.loadIfNeeded()
        #if DEBUG
        DebugSnapshot.unlock(document)
        #endif
        guard let pdf = document.pdf, !pdf.isLocked else { return }
        viewer.show(document)
        // A tool chosen in the Welcome window before this document was open.
        if let url = fileURL?.standardizedFileURL, let sheet = ToolInbox.shared.pendingSheets.removeValue(forKey: url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { viewer.activeSheet = sheet }
        }
        #if DEBUG
        DebugSnapshot.configure(viewer)
        #endif
    }
}

private struct DocumentState: Hashable {
    let object: ObjectIdentifier
    let generation: Int
}
