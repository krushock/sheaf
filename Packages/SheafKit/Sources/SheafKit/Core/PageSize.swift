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
}
