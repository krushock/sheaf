import SwiftUI

/// The sidebar: search results while searching, otherwise the chosen mode.
struct SidebarView: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        if viewer.isShowingSearchResults {
            SearchResultsList(viewer: viewer)
        } else {
            switch viewer.sidebarMode {
            case .thumbnails: ThumbnailList(viewer: viewer)
            case .tableOfContents: OutlineList(viewer: viewer)
            case .annotations: AnnotationList(viewer: viewer)
            }
        }
    }
}

/// The menu at the leading edge of the toolbar that picks what the sidebar shows.
struct SidebarMenu: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        Menu {
            Toggle("Hide Sidebar", isOn: Binding(get: { !viewer.isSidebarVisible }, set: { viewer.isSidebarVisible = !$0 }))
            Divider()
            ForEach(SidebarMode.allCases) { mode in
                Toggle(isOn: Binding(
                    get: { viewer.isSidebarVisible && viewer.sidebarMode == mode },
                    set: { _ in viewer.showSidebar(mode) }
                )) {
                    Label(mode.title, systemImage: mode.systemImage)
                }
            }
        } label: {
            Label("Sidebar", systemImage: "sidebar.left")
        }
        .help("Choose what the sidebar shows")
    }
}

extension ViewerModel {
    func showSidebar(_ mode: SidebarMode) {
        sidebarMode = mode
        isSidebarVisible = true
    }
}
