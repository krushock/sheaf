/// How pictures are laid out when they are made into pages.
public struct ImageDocumentOptions: Sendable, Equatable {
    public enum Paper: Sendable, Equatable {
        /// Each page is the size of its picture.
        case fitImage
        /// Every page is this size, with the picture scaled to fit and centered.
        case fixed(PageSize)
    }

    public var paper = Paper.fitImage
    /// Space between the picture and the page's edges.
    public var margin = 0.0
    /// Turns the paper on its side for pictures that are wider than tall.
    public var turnsPaperToFit = true

    public init(paper: Paper = .fitImage, margin: Double = 0, turnsPaperToFit: Bool = true) {
        self.paper = paper
        self.margin = margin
        self.turnsPaperToFit = turnsPaperToFit
    }
}
