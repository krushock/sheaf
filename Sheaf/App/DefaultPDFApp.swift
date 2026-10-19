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
    static var current: Choice? { current(for: .pdf) }

    /// The app that opens files of a type now.
    static func current(for type: UTType) -> Choice? {
        NSWorkspace.shared.urlForApplication(toOpen: type).flatMap(choice)
    }

    static var isSheaf: Bool {
        current?.bundleID == Bundle.main.bundleIdentifier
    }

    /// Every app that says it opens PDFs: Sheaf first, the others by name. An app that
    /// is installed more than once is listed once.
    static var choices: [Choice] { choices(for: [.pdf]) }

    /// The apps that open every one of some types, and the ones that open any of them now:
    /// Sheaf first, the others by name.
    static func choices(for types: [UTType]) -> [Choice] {
        var seen: Set<String> = []
        var result: [Choice] = []
        let openers = types.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0).compactMap(choice)) }
        let common = openers.dropFirst().reduce(openers.first ?? []) { $0.intersection($1) }
        let now = types.compactMap(current(for:))
        for candidate in [sheaf].compactMap(\.self) + now + common.sorted { $0.name < $1.name }
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
        try await set(choice, for: [.pdf])
    }

    /// Makes an app the one that opens files of some types, one type after another.
    /// macOS may ask the person to confirm each.
    static func set(_ choice: Choice, for types: [UTType]) async throws {
        for type in types {
            try await NSWorkspace.shared.setDefaultApplication(at: choice.url, toOpen: type)
        }
    }

    /// The kinds of picture Sheaf opens, as its Info.plist lists them.
    static let pictureTypes: [UTType] = [.jpeg, .png, .heic, .tiff, .gif, .bmp, .webP, UTType("public.avif")].compactMap(\.self)

    /// What to say when macOS would not make the change.
    static func failureAlert(for error: any Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "The default app could not be changed.")
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

/// A row in Settings that shows which app opens some kinds of file and lets another be
/// chosen. For several kinds at once it shows their app when they share one.
struct DefaultAppPicker: View {
    let title: Text
    let types: [UTType]
    @State private var choices: [DefaultPDFApp.Choice] = []
    @State private var selection = ""
    @State private var isChanging = false

    /// Shown when the kinds of file open in different apps.
    private static let mixed = "mixed"

    init(_ title: LocalizedStringKey, types: [UTType]) {
        self.title = Text(title)
        self.types = types
    }

    /// For a name macOS gives, in the person's language already.
    init(verbatim title: String, types: [UTType]) {
        self.title = Text(verbatim: title)
        self.types = types
    }

    var body: some View {
        Picker(selection: Binding(get: { selection }, set: choose)) {
            if selection == Self.mixed {
                Text("Different Apps").tag(Self.mixed)
                Divider()
            }
            ForEach(choices) { choice in
                Label {
                    Text(choice.name)
                } icon: {
                    Image(nsImage: choice.icon)
                }
                .tag(choice.bundleID)
            }
        } label: {
            title
        }
        .disabled(isChanging || choices.isEmpty)
        .onAppear(perform: refresh)
        // The choice can be changed elsewhere, in the Finder for one.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        choices = DefaultPDFApp.choices(for: types)
        let now = Set(types.map { DefaultPDFApp.current(for: $0)?.bundleID ?? "" })
        selection = now.count == 1 ? now.first ?? "" : Self.mixed
    }

    private func choose(_ bundleID: String) {
        guard bundleID != selection, bundleID != Self.mixed, let choice = choices.first(where: { $0.bundleID == bundleID }) else { return }
        let before = selection
        selection = bundleID
        isChanging = true
        Task {
            defer { isChanging = false }
            do {
                try await DefaultPDFApp.set(choice, for: types)
            } catch {
                selection = before
                DefaultPDFApp.failureAlert(for: error).runModal()
            }
            // What macOS now says, which is the truth whether or not it asked first.
            refresh()
        }
    }
}

/// Settings ▸ General: which app opens PDFs and pictures from the Finder.
struct FileAssociationSettings: View {
    var body: some View {
        Section {
            DefaultAppPicker("PDF documents", types: [.pdf])
            DefaultAppPicker("Pictures", types: DefaultPDFApp.pictureTypes)
            DisclosureGroup("Each kind of picture") {
                ForEach(DefaultPDFApp.pictureTypes, id: \.identifier) { type in
                    DefaultAppPicker(verbatim: type.localizedDescription ?? type.preferredFilenameExtension?.uppercased() ?? type.identifier, types: [type])
                }
            }
        } header: {
            Text("Default Apps")
        } footer: {
            Text("The app that opens each kind of file when you double-click it in the Finder. Sheaf opens a picture as a one-page document. macOS may ask you to confirm each change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
