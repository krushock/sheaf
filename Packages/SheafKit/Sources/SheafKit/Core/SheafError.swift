public enum SheafError: Error, Sendable, Equatable {
    /// The data is not a PDF, or is damaged beyond recovery.
    case notAPDF
    /// The file is a PDF but part of it could not be understood. The text says what and where.
    case malformed(String)
    /// The file uses a feature the engine does not handle. The text names it.
    case unsupported(String)
    /// The document is encrypted and needs a password to be read.
    case passwordRequired
    /// The document is encrypted and the supplied password did not unlock it.
    case incorrectPassword
    /// A page index was outside the document.
    case pageOutOfRange(Int)
    /// The image data could not be decoded.
    case unreadableImage
    /// Writing a new PDF failed.
    case generationFailed
}
