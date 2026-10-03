import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A Quick Look preview of a file, falling back to its Finder icon.
struct FileThumbnail: View {
    let url: URL
    let size: CGSize
    @State private var preview: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: size, scale: displayScale, representationTypes: .thumbnail
            )
            preview = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
