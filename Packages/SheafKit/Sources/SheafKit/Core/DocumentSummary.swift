/// Cheap, read-only facts about a PDF file.
public struct DocumentSummary: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        /// Media box size, before rotation is applied.
        public var size: PageSize
        /// Clockwise rotation in degrees: 0, 90, 180 or 270.
        public var rotation: Int

        public init(size: PageSize, rotation: Int) {
            self.size = size
            self.rotation = rotation
        }
    }

    /// PDF header version, for example 1.7.
    public var majorVersion: Int
    public var minorVersion: Int
    public var isEncrypted: Bool
    /// True when the document is encrypted and no valid password was supplied.
    /// A locked document reports no pages.
    public var isLocked: Bool
    public var pages: [Page]

    public var pageCount: Int { pages.count }

    public init(majorVersion: Int, minorVersion: Int, isEncrypted: Bool, isLocked: Bool, pages: [Page]) {
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.isEncrypted = isEncrypted
        self.isLocked = isLocked
        self.pages = pages
    }
}

/// Reads facts about existing PDF data. Implemented in `Platform/`.
public enum PDFInspector {}

/// Creates new PDF data. Implemented in `Platform/`.
public enum PDFGenerator {}
