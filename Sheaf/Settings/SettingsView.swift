import SwiftUI

struct SettingsView: View {
    private enum Pane: String {
        case general, viewing
    }

    /// The pane last looked at, which Settings opens on again.
    @AppStorage("settings.pane") private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                GeneralSettings()
            }
            Tab("Viewing", systemImage: "doc.text.magnifyingglass", value: Pane.viewing) {
                ViewingSettings()
            }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.showWelcomeAtLaunch) private var showWelcomeAtLaunch = true
    @AppStorage(Preferences.newDocumentPaper) private var newDocumentPaper = NewDocumentPaper.system

    var body: some View {
        Form {
            Toggle("Show Welcome window when Sheaf opens", isOn: $showWelcomeAtLaunch)
            Picker("New document page size", selection: $newDocumentPaper) {
                ForEach(NewDocumentPaper.allCases) { Text($0.title).tag($0) }
            }
            Section {
                DefaultPDFAppPicker()
            } footer: {
                Text("The app that opens a PDF when you double-click it in the Finder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ViewingSettings: View {
    @AppStorage(Preferences.pageLayout) private var pageLayout = PageLayout.continuous
    @AppStorage(Preferences.openingZoom) private var openingZoom = OpeningZoom.fitWidth
    @AppStorage(Preferences.openingSidebar) private var openingSidebar = OpeningSidebar.thumbnails

    var body: some View {
        Form {
            Section {
                Picker("Page layout", selection: $pageLayout) {
                    ForEach(PageLayout.allCases) { Text($0.title).tag($0) }
                }
                Picker("Zoom", selection: $openingZoom) {
                    ForEach(OpeningZoom.allCases) { Text($0.title).tag($0) }
                }
                Picker("Sidebar", selection: $openingSidebar) {
                    ForEach(OpeningSidebar.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("When Opening a Document")
            } footer: {
                Text("These apply to documents you open from now on.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
