/// A page size in PDF points (1/72 inch).
public struct PageSize: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let letter = PageSize(width: 612, height: 792)
    public static let a4 = PageSize(width: 595, height: 842)
    public static let a3 = PageSize(width: 842, height: 1191)
    public static let a5 = PageSize(width: 420, height: 595)
    public static let legal = PageSize(width: 612, height: 1008)
    public static let tabloid = PageSize(width: 792, height: 1224)

    /// The same paper turned on its side.
    public var turned: PageSize { PageSize(width: height, height: width) }
}
