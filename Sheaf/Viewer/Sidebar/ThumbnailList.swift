import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailList: View {
    let viewer: ViewerModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(0..<viewer.pageCount, id: \.self) { index in
                    ThumbnailRow(viewer: viewer, index: index)
                        .contextMenu { menu(forPage: index) }
                }
                // Dragging a thumbnail reorders pages; dropping files adds theirs.
                .onMove { source, destination in
                    guard viewer.canEditPages else { return }
                    viewer.movePages(Array(source), to: destination)
                }
                .onInsert(of: [.fileURL]) { index, providers in
                    guard viewer.canEditPages else { return }
                    Task {
                        var urls: [URL] = []
                        for provider in providers {
                            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                                urls.append(url)
                            } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                                      let url = URL(dataRepresentation: data, relativeTo: nil) {
                                urls.append(url)
                            }
                        }
                        viewer.insertFiles(urls.filter(ViewerModel.canInsert), at: index)
                    }
                }
            }
            .onAppear { proxy.scrollTo(viewer.currentPageIndex, anchor: .center) }
            .onChange(of: viewer.currentPageIndex) { _, index in
                withAnimation { proxy.scrollTo(index) }
            }
        }
    }

    @ViewBuilder private func menu(forPage index: Int) -> some View {
        Group {
            Button("Rotate Left") { viewer.rotatePages([index], by: -90) }
            Button("Rotate Right") { viewer.rotatePages([index], by: 90) }
            Divider()
            Button("Duplicate") { viewer.duplicatePages([index]) }
            Button("Delete") { viewer.deletePages([index]) }
                .disabled(viewer.pageCount < 2)
            Divider()
            BlankPageMenu("Insert Blank Page", viewer: viewer, index: index + 1)
            Button("Insert from File…") { viewer.chooseFilesToInsert(at: index + 1) }
        }
        .disabled(!viewer.canEditPages)
        Divider()
        Button("Open as New Document") { viewer.extractPages([index]) }
            .disabled(viewer.sheafDocument?.editor == nil)
        Button("Organize Pages") { viewer.isOrganizing = true }
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { viewer.currentPageIndex },
            set: { if let index = $0, index != viewer.currentPageIndex { viewer.goToPage(index: index) } }
        )
    }
}

private struct ThumbnailRow: View {
    let viewer: ViewerModel
    let index: Int
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Rectangle().fill(.white)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
            }
            .aspectRatio(viewer.aspectRatio(ofPage: index), contentMode: .fit)
            .frame(maxWidth: 150, maxHeight: 200)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            Text(verbatim: "\(index + 1)")
                .font(.caption)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .accessibilityElement()
        .accessibilityLabel("Page \(index + 1)")
        // Runs again when the page is edited, so the thumbnail follows.
        .task(id: viewer.thumbnailVersion(forPage: index)) {
            image = await viewer.thumbnail(forPage: index)
        }
    }
}
