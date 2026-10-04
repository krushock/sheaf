import SwiftUI

@main
struct SheafApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage(Preferences.showWelcomeAtLaunch) private var showWelcomeAtLaunch = true

    init() {
        SheafTips.configure()
    }

    var body: some Scene {
        // Listed first so it is the window shown at launch, as in Pages and Xcode.
        Window("Welcome to Sheaf", id: WelcomeView.windowID) {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(showWelcomeAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .keyboardShortcut("1", modifiers: [.command, .shift])

        DocumentGroup(newDocument: { SheafDocument() }) { file in
            DocumentWindow(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1080, height: 820)
        .commands {
            SheafCommands()
            UpdateCommands()
            CommandGroup(after: .help) {
                Button("Show Tips Again") { SheafTips.showAgain() }
            }
        }

        Window("New from PDFs", id: MergeWindow.windowID) {
            MergeWindow()
        }
        .defaultSize(width: 620, height: 460)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("New from Images", id: ImagesWindow.windowID) {
            ImagesWindow()
        }
        .defaultSize(width: 620, height: 560)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("Compare Documents", id: CompareWindow.windowID) {
            CompareWindow()
        }
        .defaultSize(width: 1280, height: 820)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("Flows", id: FlowsWindow.windowID) {
            FlowsWindow()
        }
        .defaultSize(width: 780, height: 520)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
        }
    }
}
