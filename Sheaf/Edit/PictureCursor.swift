import AppKit

/// The pointers shown over the handles of a selected thing: resizing along the way the
/// handle pulls, and turning.
enum PictureCursor {
    /// The system's resize pointer for a handle that pulls in a direction on screen.
    ///
    /// - Parameter degrees: The direction, counterclockwise from pointing right.
    static func resize(toward degrees: Double) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [.right, .topRight, .top, .topLeft, .left, .bottomLeft, .bottom, .bottomRight]
        return NSCursor.frameResize(position: positions[step(degrees, of: 8)], directions: .all)
    }

    /// A curved arrow with a head at each end, as Pages shows while Command is held over
    /// a handle. It curves around the picture's center, which lies opposite `degrees`.
    static func rotate(toward degrees: Double) -> NSCursor {
        let step = step(degrees, of: 16)
        if let cursor = rotateCursors[step] { return cursor }
        let side = 28.0
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: side / 2, y: side / 2)
            context.rotate(by: Double(step) * 22.5 * .pi / 180)

            let center = CGPoint(x: -10, y: 0), radius = 10.0, sweep = 46.0 * .pi / 180
            let arc = CGMutablePath()
            arc.addArc(center: center, radius: radius, startAngle: -sweep, endAngle: sweep, clockwise: false)
            var shapes = [arc.copy(strokingWithWidth: 1.7, lineCap: .butt, lineJoin: .round, miterLimit: 4)]
            for sign in [-1.0, 1.0] {
                let angle = sign * sweep
                let end = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                // The head points on along the curve, past its end.
                let onward = angle + sign * .pi / 2
                let head = CGMutablePath()
                head.move(to: CGPoint(x: end.x + 5 * cos(onward), y: end.y + 5 * sin(onward)))
                head.addLine(to: CGPoint(x: end.x + 3.8 * cos(angle), y: end.y + 3.8 * sin(angle)))
                head.addLine(to: CGPoint(x: end.x - 3.8 * cos(angle), y: end.y - 3.8 * sin(angle)))
                head.closeSubpath()
                shapes.append(head)
            }
            // A white edge keeps it readable on dark pictures, as the system's pointers have.
            context.setLineJoin(.round)
            context.setLineWidth(2.6)
            context.setStrokeColor(.white)
            context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: CGColor(gray: 0, alpha: 0.35))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for shape in shapes {
                context.addPath(shape)
                context.strokePath()
            }
            context.setFillColor(.black)
            for shape in shapes {
                context.addPath(shape)
                context.fillPath()
            }
            context.endTransparencyLayer()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
        rotateCursors[step] = cursor
        return cursor
    }

    private static var rotateCursors: [Int: NSCursor] = [:]

    /// A direction as one of `count` equal steps around the circle.
    private static func step(_ degrees: Double, of count: Int) -> Int {
        guard degrees.isFinite else { return 0 }
        let step = Int((degrees / (360 / Double(count))).rounded())
        return ((step % count) + count) % count
    }
}
