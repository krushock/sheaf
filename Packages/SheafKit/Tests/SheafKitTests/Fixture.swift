import Foundation
import Testing

enum Fixture: String, CaseIterable {
    case text3Pages = "text-3pages"
    case image1Page = "image-1page"
    case encrypted = "encrypted-user-password"
    case handwritten = "handwritten-classic-xref"
    case outlineAnnotations = "outline-annotations-12pages"
    /// `TestPDF.form()` as a file, for trying the app on.
    case form = "form-1page"
    /// `TestPDF.paperForm()` as a file.
    case paperForm = "paper-form-1page"

    var data: Data {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: rawValue, withExtension: "pdf", subdirectory: "Fixtures"),
                "missing fixture \(rawValue).pdf"
            )
            return try Data(contentsOf: url)
        }
    }
}
