import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the Services menu and Finder's context menu can send to Sheaf: files selected in
/// another app. The entries are declared in Info.plist under `NSServices`.
final class ServicesProvider: NSObject {
    private func urls(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    @objc func mergeFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = urls(from: pasteboard).filter(ViewerModel.canInsert)
        guard !files.isEmpty else { return }
        ToolInbox.shared.mergeURLs = files
        ToolInbox.shared.open(MergeWindow.windowID)
    }

    @objc func imagesToPDF(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = urls(from: pasteboard).filter { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
        guard !files.isEmpty else { return }
        ToolInbox.shared.imageURLs = files
        ToolInbox.shared.open(ImagesWindow.windowID)
    }

    @objc func reduceFileSize(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        for url in urls(from: pasteboard) where url.pathExtension.lowercased() == "pdf" {
            ToolInbox.shared.pendingSheets[url.standardizedFileURL] = .reduce
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}
