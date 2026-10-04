import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which app opens a PDF that is double-clicked in the Finder, and changing that.
enum DefaultPDFApp {
    /// An app that can open PDFs.
    struct Choice: Identifiable, Hashable {
        let url: URL
        let name: String
        let bundleID: String

        var id: String { bundleID }

        /// The app's icon at the size of a menu item.
        var icon: NSImage {
            let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
    }

    private static func choice(at url: URL) -> Choice? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return Choice(url: url, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, bundleID: id)
    }

    /// Sheaf as it is running now.
    static var sheaf: Choice? { choice(at: Bundle.main.bundleURL) }

    /// The app that opens PDFs now.
    static var current: Choice? {
        NSWorkspace.shared.urlForApplication(toOpen: .pdf).flatMap(choice)
    }

    static var isSheaf: Bool {
        current?.bundleID == Bundle.main.bundleIdentifier
    }

    /// Every app that says it opens PDFs: Sheaf first, the others by name. An app that
    /// is installed more than once is listed once.
    static var choices: [Choice] {
        var seen: Set<String> = []
        var result: [Choice] = []
        for candidate in [sheaf, current].compactMap(\.self) + NSWorkspace.shared.urlsForApplications(toOpen: .pdf).compactMap(choice)
        where seen.insert(candidate.bundleID).inserted {
            result.append(candidate)
        }
        let own = Bundle.main.bundleIdentifier
        return result.sorted { a, b in
            if (a.bundleID == own) != (b.bundleID == own) { return a.bundleID == own }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Makes an app the one that opens PDFs. macOS may ask the person to confirm.
    static func set(_ choice: Choice) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: choice.url, toOpen: .pdf)
    }

    /// What to say when macOS would not make the change.
    static func failureAlert(for error: any Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "The default PDF app could not be changed.")
        alert.informativeText = String(localized: "macOS did not allow it (\(error.localizedDescription)). To change it by hand, select a PDF in the Finder, choose File > Get Info, pick the app under “Open with”, and click Change All.")
        return alert
    }

    // MARK: Asking once

    /// Whether this is an automated run, where a question on screen would only be in the way.
    private static var isAutomated: Bool {
        UserDefaults.standard.double(forKey: "SnapshotWindows") > 0 || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Asks, the first time Sheaf is opened, whether it should open PDFs from now on.
    /// Never asks again, whatever the answer: Settings has the choice from then on.
    static func askOnceIfNeeded() {
        let defaults = UserDefaults.standard
        #if DEBUG
        let forced = defaults.bool(forKey: "SnapshotDefaultAppPrompt")
        #else
        let forced = false
        #endif
        guard forced || (!isAutomated && !defaults.bool(forKey: Preferences.askedAboutDefaultApp) && !isSheaf) else { return }
        // A moment after launch, when the first window is up to hang the question on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !forced { defaults.set(true, forKey: Preferences.askedAboutDefaultApp) }
            let alert = NSAlert()
            alert.messageText = String(localized: "Make Sheaf your default PDF app?")
            alert.informativeText = String(localized: "PDFs you open from the Finder and from other apps will open in Sheaf. You can change this at any time in Settings.")
            alert.addButton(withTitle: String(localized: "Use Sheaf"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            let answer: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .alertFirstButtonReturn, !forced, let sheaf else { return }
                Task {
                    do {
                        try await set(sheaf)
                    } catch {
                        failureAlert(for: error).runModal()
                    }
                }
            }
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }) {
                alert.beginSheetModal(for: window, completionHandler: answer)
            } else {
                answer(alert.runModal())
            }
        }
    }
}

/// The row in Settings that shows which app opens PDFs and lets another be chosen.
struct DefaultPDFAppPicker: View {
    @State private var choices: [DefaultPDFApp.Choice] = []
    @State private var selection = ""
    @State private var isChanging = false

    var body: some View {
        Picker("Default PDF app", selection: Binding(get: { selection }, set: choose)) {
            ForEach(choices) { choice in
                Label {
                    Text(choice.name)
                } icon: {
                    Image(nsImage: choice.icon)
                }
                .tag(choice.bundleID)
            }
        }
        .disabled(isChanging || choices.isEmpty)
        .onAppear(perform: refresh)
        // The choice can be changed elsewhere, in the Finder for one.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        choices = DefaultPDFApp.choices
        selection = DefaultPDFApp.current?.bundleID ?? ""
    }

    private func choose(_ bundleID: String) {
        guard bundleID != selection, let choice = choices.first(where: { $0.bundleID == bundleID }) else { return }
        let before = selection
        selection = bundleID
        isChanging = true
        Task {
            defer { isChanging = false }
            do {
                try await DefaultPDFApp.set(choice)
                // What macOS now says, which is the truth whether or not it asked first.
                refresh()
            } catch {
                selection = before
                DefaultPDFApp.failureAlert(for: error).runModal()
            }
        }
    }
}
