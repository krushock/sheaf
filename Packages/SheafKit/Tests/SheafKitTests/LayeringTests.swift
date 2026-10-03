import Foundation
import Testing

/// Apple's reading, drawing and measuring frameworks may be imported only under
/// `Sources/SheafKit/Platform/`. Everything else in the engine stays plain Swift.
@Suite struct LayeringTests {
    static let restricted = [
        "CoreGraphics", "CoreText", "Vision", "ImageIO", "PDFKit", "AppKit", "CoreImage", "Quartz",
        "zlib", "Compression", "CryptoKit", "CommonCrypto",
    ]

    @Test func platformFrameworksStayInPlatformFolder() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SheafKit", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        var checked = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            guard !file.pathComponents.contains("Platform") else { continue }
            checked += 1
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                let words = line.split(separator: " ")
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count else { continue }
                let module = words[index + 1].split(separator: ".").first.map(String.init) ?? ""
                #expect(!Self.restricted.contains(module), "\(file.lastPathComponent) imports \(module)")
            }
        }
        #expect(checked > 0, "no source files found at \(sources.path)")
    }
}
