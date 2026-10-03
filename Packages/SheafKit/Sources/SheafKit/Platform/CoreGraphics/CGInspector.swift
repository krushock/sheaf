import CoreGraphics
import Foundation

extension PDFInspector {
    /// Summarizes a PDF.
    ///
    /// - Parameter password: Tried when the document is encrypted. Pass `nil` to get a
    ///   locked summary for documents that need one.
    /// - Throws: `SheafError.notAPDF` when the data cannot be parsed,
    ///   `SheafError.incorrectPassword` when a supplied password is wrong.
    public static func summary(of data: Data, password: String? = nil) throws(SheafError) -> DocumentSummary {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { throw .notAPDF }

        if !document.isUnlocked, let password {
            guard document.unlockWithPassword(password) else { throw .incorrectPassword }
        }

        var major: Int32 = 0
        var minor: Int32 = 0
        document.getVersion(majorVersion: &major, minorVersion: &minor)

        var pages: [DocumentSummary.Page] = []
        if document.isUnlocked {
            pages.reserveCapacity(document.numberOfPages)
            // Core Graphics page numbers start at 1.
            for number in stride(from: 1, through: document.numberOfPages, by: 1) {
                guard let page = document.page(at: number) else { continue }
                let box = page.getBoxRect(.mediaBox)
                pages.append(.init(
                    size: PageSize(width: box.width, height: box.height),
                    rotation: ((Int(page.rotationAngle) % 360) + 360) % 360
                ))
            }
        }

        return DocumentSummary(
            majorVersion: Int(major),
            minorVersion: Int(minor),
            isEncrypted: document.isEncrypted,
            isLocked: !document.isUnlocked,
            pages: pages
        )
    }
}
