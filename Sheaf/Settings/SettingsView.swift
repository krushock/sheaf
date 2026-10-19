import SwiftUI

struct SettingsView: View {
    private enum Pane: String {
        case general, viewing, intelligence
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
            // Only in a copy of Sheaf that Apple lets use Private Cloud Compute: the pane
            // holds that one choice, and there is nothing to choose without it.
            if DocumentReader.isCloudPermitted {
                Tab("Intelligence", systemImage: "apple.intelligence", value: Pane.intelligence) {
                    IntelligenceSettings()
                }
            }
        }
        .frame(width: 480)
        .onAppear {
            if pane == .intelligence, !DocumentReader.isCloudPermitted { pane = .general }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.showWelcomeAtLaunch) private var showWelcomeAtLaunch = true
    @AppStorage(Preferences.newDocumentPaper) private var newDocumentPaper = NewDocumentPaper.system
    @AppStorage(Preferences.markupAuthor) private var authorName = NSFullUserName()

    var body: some View {
        Form {
            Toggle("Show Welcome window when Sheaf opens", isOn: $showWelcomeAtLaunch)
            Picker("New document page size", selection: $newDocumentPaper) {
                ForEach(NewDocumentPaper.allCases) { Text($0.title).tag($0) }
            }
            Section {
                TextField("Name on notes and markup", text: $authorName, prompt: Text("None"))
            } footer: {
                Text("Saved in the PDF with each note, highlight, drawing and signature you add, so anyone you send it to can see it. Leave it empty to add none.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FileAssociationSettings()
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Which of Apple's models reads documents for summaries and answers.
private struct IntelligenceSettings: View {
    @AppStorage(Preferences.readingEngine) private var engine = ReadingEngine.device

    var body: some View {
        Form {
            if let reason = DocumentReader.unavailableReason {
                Section {
                    Label(reason, systemImage: "apple.intelligence")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker("Summaries and answers", selection: DocumentReader.isCloudAvailable ? $engine : .constant(.device)) {
                        ForEach(ReadingEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!DocumentReader.isCloudAvailable)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On This Mac keeps everything on your Mac. It reads a few pages at a time, so long documents take minutes.")
                        Text("Private Cloud Compute sends the document's text to Apple's larger model on servers built so that nobody, Apple included, can keep or see it. It takes in four times as much at once, so a long document is read in far fewer parts. macOS limits how much it can be used; past the limit, Sheaf goes back to this Mac and says so.")
                        if !DocumentReader.isCloudAvailable {
                            Text("Private Cloud Compute is not available on this Mac right now.")
                        } else if engine == .cloud {
                            let limit = DocumentReader.cloudLimit
                            if limit.isReached {
                                Text(limit.resets.map { "The limit is reached until \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "The limit is reached for now.")
                            } else if limit.isNear {
                                Text("The limit is close.")
                            }
                        }
                        Text("Writing Tools, Image Playground and what is done to pictures follow Apple Intelligence in System Settings, not this choice.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
