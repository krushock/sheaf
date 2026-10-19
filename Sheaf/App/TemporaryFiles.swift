import Foundation

/// Folders of copies Sheaf makes for a moment: a PDF and the email it answers, for Mail
/// to pick up, and pages as they come off a scanner. They hold people's documents and
/// mail, so they are removed once they have served, rather than left to macOS.
nonisolated enum TemporaryFiles {
    /// The names such folders start with in the app's temporary folder.
    static let prefixes = ["Reply-", "Scans-"]

    /// Removes the folders left from earlier, for example when Sheaf quit before it got to
    /// them. Ones made in the last `age` seconds may still be in use and stay.
    static func sweep(olderThan age: TimeInterval = 600) {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where prefixes.contains(where: name.hasPrefix) {
            let url = folder.appendingPathComponent(name, isDirectory: true)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if Date().timeIntervalSince(made) > age { try? manager.removeItem(at: url) }
        }
    }

    /// Removes a folder after giving whatever app it was handed to time to read it.
    static func remove(_ folder: URL, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
