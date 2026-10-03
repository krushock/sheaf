/// SheafKit is Sheaf's in-house PDF engine.
///
/// - `PDFFile` reads a PDF: its objects, cross-reference table, compression and encryption.
/// - `PDFEditor` holds changes on top of a file: pages, metadata, content.
/// - `PDFEditor.serialized` appends the changes to the untouched original bytes;
///   `PDFEditor.rewritten` writes the document out afresh, optionally with new protection.
/// - `ContentStream` reads and writes a page's drawing instructions.
///
/// Layering rule: everything outside `Platform/` is plain Swift and Foundation. System
/// libraries for drawing, measuring, compression and cryptography are imported only inside
/// `Platform/`. `LayeringTests` enforces this.
public enum SheafKit {
    public static let version = "0.2.0"
}
