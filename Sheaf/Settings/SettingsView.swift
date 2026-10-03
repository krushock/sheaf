import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Viewing", systemImage: "doc.text.magnifyingglass") {
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
