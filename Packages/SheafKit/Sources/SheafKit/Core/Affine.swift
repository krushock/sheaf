import Foundation

/// A transform of the plane, as PDF writes one: six numbers `a b c d e f`, where a point
/// goes to `(a·x + c·y + e, b·x + d·y + f)`.
struct Affine: Sendable, Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    static let identity = Affine()

    static func translation(_ x: Double, _ y: Double) -> Affine {
        Affine(e: x, f: y)
    }

    static func scale(_ x: Double, _ y: Double) -> Affine {
        Affine(a: x, d: y)
    }

    /// Counter-clockwise, about the origin.
    static func rotation(degrees: Double) -> Affine {
        let radians = degrees * .pi / 180
        return Affine(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians))
    }

    /// The transform that does this one first and `next` after it.
    func then(_ next: Affine) -> Affine {
        Affine(
            a: a * next.a + b * next.c, b: a * next.b + b * next.d,
            c: c * next.a + d * next.c, d: c * next.b + d * next.d,
            e: e * next.a + f * next.c + next.e, f: e * next.b + f * next.d + next.f
        )
    }

    func apply(_ point: PDFPoint) -> PDFPoint {
        PDFPoint(x: a * point.x + c * point.y + e, y: b * point.x + d * point.y + f)
    }

    /// The six numbers as they are written before a `cm` operator.
    var operands: String {
        [a, b, c, d, e, f].map(Serializer.format).joined(separator: " ")
    }
}

extension PathElement {
    func applying(_ transform: Affine) -> PathElement {
        switch self {
        case .move(let point): .move(transform.apply(point))
        case .line(let point): .line(transform.apply(point))
        case .curve(let control1, let control2, let end):
            .curve(control1: transform.apply(control1), control2: transform.apply(control2), end: transform.apply(end))
        case .close: .close
        }
    }

    /// The points that steer this step, which between them enclose the curve.
    var points: [PDFPoint] {
        switch self {
        case .move(let point), .line(let point): [point]
        case .curve(let control1, let control2, let end): [control1, control2, end]
        case .close: []
        }
    }
}

/// Where a page sits in its own coordinates and how it is turned for display.
public struct PageGeometry: Sendable, Equatable {
    /// The visible part of the page, before rotation.
    public var box: PDFRectangle
    /// Clockwise rotation in degrees: 0, 90, 180 or 270.
    public var rotation: Int

    /// The page's size as a reader sees it.
    public var displaySize: PageSize {
        rotation % 180 == 0 ? PageSize(width: box.width, height: box.height) : PageSize(width: box.height, height: box.width)
    }

    /// Takes a point on the page as displayed, measured from its bottom left corner, to
    /// the page's own coordinates. Drawing through this comes out upright however the
    /// page is turned.
    var fromDisplay: Affine {
        switch rotation {
        case 90: Affine(a: 0, b: 1, c: -1, d: 0, e: box.x + box.width, f: box.y)
        case 180: Affine(a: -1, b: 0, c: 0, d: -1, e: box.x + box.width, f: box.y + box.height)
        case 270: Affine(a: 0, b: -1, c: 1, d: 0, e: box.x, f: box.y + box.height)
        default: Affine(e: box.x, f: box.y)
        }
    }
}

extension PDFEditor {
    public func geometry(ofPageAt index: Int) throws -> PageGeometry {
        PageGeometry(box: try pageBox(at: index), rotation: try pageRotation(at: index))
    }
}
