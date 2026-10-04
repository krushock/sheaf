import Foundation

/// A step in the order the things on a page are stacked in.
///
/// A PDF page has no layers to rearrange: things simply cover what was drawn before
/// them. Moving something forward or back means drawing it later or earlier.
public enum StackingMove: String, Sendable, CaseIterable {
    case toFront, forward, backward, toBack
}

/// What a page's drawing has set up by some point in its content: for each level of
/// saved state that is still open, the operations that made it what it is.
struct DrawingState {
    var levels: [[ContentStream.Operation]] = [[]]
    /// The marked-content sections that are open.
    var marked: [ContentStream.Operation] = []
}

extension ContentStream {
    private static let construction: Set<String> = ["m", "l", "c", "v", "y", "h", "re"]
    private static let painting: Set<String> = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"]
    private static let settings: Set<String> = ["w", "J", "j", "M", "d", "ri", "i", "Tc", "Tw", "Tz", "TL", "Tf", "Tr", "Ts"]

    /// For each place between operations, counting the two ends, whether something can
    /// be drawn there: not inside a text object, and not while a shape is being built.
    ///
    /// - Parameter outsideMarkedContent: Also not inside a marked section, where what is
    ///   drawn would become part of the section: of its layer, its tag or its style.
    static func boundaries(in operations: [Operation], outsideMarkedContent: Bool = false) -> [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(operations.count + 1)
        var inText = false, inPath = false
        var marked = 0
        for operation in operations {
            result.append(!inText && !inPath && (marked == 0 || !outsideMarkedContent))
            switch operation.name {
            case "BT": inText = true
            case "ET": inText = false
            case "BMC", "BDC": marked += 1
            case "EMC": marked = max(marked - 1, 0)
            case "W", "W*": inPath = true
            case let name where construction.contains(name): inPath = true
            case let name where painting.contains(name): inPath = false
            default: break
            }
        }
        result.append(true)
        return result
    }

    /// The state the drawing is in just before an operation.
    ///
    /// Only what is still in force is kept: closed groups are gone, a setting made twice
    /// is kept once, and nothing that paints is included. Running the operations of the
    /// levels in order, from a clean start, gives the same state again.
    static func drawingState(before position: Int, in operations: [Operation]) -> DrawingState {
        struct Entry {
            var key: String?
            var operations: [Operation]
        }
        var levels: [[Entry]] = [[]]
        var marked: [Operation] = []
        var path: [Operation] = []
        var clips = false
        func set(_ key: String, _ operations: [Operation]) {
            levels[levels.count - 1].removeAll { $0.key == key }
            levels[levels.count - 1].append(Entry(key: key, operations: operations))
        }
        /// A color given by numbers alone depends on the color space chosen before it.
        func setColor(_ key: String, _ operation: Operation, spaces: Set<String>) {
            let space = levels[levels.count - 1].first { $0.key == key }?.operations.first.flatMap { spaces.contains($0.name) ? $0 : nil }
            set(key, (space.map { [$0] } ?? []) + [operation])
        }
        for operation in operations.prefix(max(position, 0)) {
            switch operation.name {
            case "q":
                levels.append([])
            case "Q":
                if levels.count > 1 { levels.removeLast() }
            case "W", "W*":
                path.append(operation)
                clips = true
            case let name where construction.contains(name):
                path.append(operation)
            case let name where painting.contains(name):
                // A shape that clips stays in force. It is kept without being painted.
                if clips { levels[levels.count - 1].append(Entry(key: nil, operations: path + [Operation("n")])) }
                path = []
                clips = false
            case "cm":
                levels[levels.count - 1].append(Entry(key: nil, operations: [operation]))
            case "gs":
                set("gs \(operation.operands.first?.nameValue?.rawValue ?? "")", [operation])
            case "cs", "g", "rg", "k":
                set("fill", [operation])
            case "sc", "scn":
                setColor("fill", operation, spaces: ["cs", "g", "rg", "k"])
            case "CS", "G", "RG", "K":
                set("stroke", [operation])
            case "SC", "SCN":
                setColor("stroke", operation, spaces: ["CS", "G", "RG", "K"])
            case "BMC", "BDC":
                marked.append(operation)
            case "EMC":
                if !marked.isEmpty { marked.removeLast() }
            case let name where settings.contains(name):
                set(name, [operation])
            default:
                break
            }
        }
        return DrawingState(levels: levels.map { $0.flatMap(\.operations) }, marked: marked)
    }

    /// Operations taken out of their place, with the state they were drawn in, so they
    /// draw the same from a clean start anywhere on the page.
    static func lifted(_ body: [Operation], from state: DrawingState) -> [Operation] {
        // Marked sections go along: an optional layer keeps showing and hiding the thing,
        // and a style some writers hang on a section, such as a shadow, stays on it.
        [Operation("q")] + state.levels.flatMap(\.self) + state.marked + body + state.marked.map { _ in Operation("EMC") } + [Operation("Q")]
    }
}

/// Something a page draws, as far as stacking goes: where it is, and where in the
/// page's own content it is drawn.
private struct Layer {
    var frame: PDFRectangle
    var first: Int
    var last: Int

    func overlaps(_ other: Layer) -> Bool {
        // A hairline has no area of its own, but still lies over or under things.
        func grown(_ frame: PDFRectangle) -> PDFRectangle {
            var frame = frame
            if frame.width < 0.5 { (frame.x, frame.width) = (frame.x - 0.25, frame.width + 0.5) }
            if frame.height < 0.5 { (frame.y, frame.height) = (frame.y - 0.25, frame.height + 0.5) }
            return frame
        }
        let a = grown(frame), b = grown(other.frame)
        return min(a.x + a.width, b.x + b.width) - max(a.x, b.x) > 0.01 && min(a.y + a.height, b.y + b.height) - max(a.y, b.y) > 0.01
    }
}

private enum Destination: Equatable {
    case end
    case before(Int)

    /// The operation to draw before, or `nil` for after everything.
    var position: Int? {
        if case .before(let place) = self { place } else { nil }
    }
}

extension PDFEditor {
    private enum Thing {
        case image(Int)
        case block(Int)
    }

    /// Reads a page for restacking: the thing to move, and everything else it draws.
    private func layers(around thing: Thing, onPageAt index: Int) throws -> (Interpretation, PageContent, mine: Layer, others: [Layer], backdrops: [Layer])? {
        let interpretation = try interpret(pageAt: index, includingPaths: true)
        let content = Self.content(from: interpretation, source: self)
        let operations = interpretation.streams[0].content.operations
        /// The operation of the page's own content that something is drawn by, directly
        /// or through the forms it is inside.
        func top(_ source: ContentSource) -> Int {
            var source = source
            var steps = 0
            while source.stream != 0, interpretation.streams.indices.contains(source.stream), let from = interpretation.streams[source.stream].invokedFrom, steps < 16 {
                source = from
                steps += 1
            }
            return source.operation
        }
        let page = content.geometry.displaySize
        var mine: Layer?
        var others: [Layer] = [], backdrops: [Layer] = []
        func add(_ layer: Layer, isMine: Bool) {
            if isMine {
                mine = layer
            } else if layer.frame.width * layer.frame.height >= 0.9 * page.width * page.height {
                // Something that covers the page is what the page stands on. Things can
                // come out from under it, but nothing is sent behind it.
                backdrops.append(layer)
            } else {
                others.append(layer)
            }
        }
        for image in content.images {
            var range = top(image.source)...top(image.source)
            if image.source.stream == 0, let group = PictureGroup(around: image.source.operation, in: operations) { range = group.range }
            let isMine = if case .image(let id) = thing { id == image.id } else { false }
            add(Layer(frame: image.frame, first: range.lowerBound, last: range.upperBound), isMine: isMine)
        }
        for block in content.blocks {
            let places = block.lines.flatMap(\.glyphs).filter { !$0.isImplied }.map { top($0.source) }
            guard let first = places.min(), let last = places.max() else { continue }
            let isMine = if case .block(let id) = thing { id == block.id } else { false }
            add(Layer(frame: block.frame, first: first, last: last), isMine: isMine)
        }
        for path in interpretation.paths {
            let range = path.stream == 0 ? path.operations : top(ContentSource(stream: path.stream, operation: path.operations.lowerBound))...top(ContentSource(stream: path.stream, operation: path.operations.lowerBound))
            add(Layer(frame: path.bounds, first: range.lowerBound, last: range.upperBound), isMine: false)
        }
        guard let mine else { return nil }
        return (interpretation, content, mine, others, backdrops)
    }

    /// Where in the page's content a thing has to be drawn to make a move. `nil` when
    /// the move would change nothing: there is nothing over it, or under it, to pass.
    private func destination(_ move: StackingMove, for mine: Layer, among others: [Layer], backdrops: [Layer], in operations: [ContentStream.Operation]) -> Destination? {
        let above = (others + backdrops).filter { $0.last > mine.last && $0.overlaps(mine) }
        let below = others.filter { $0.first < mine.first && $0.overlaps(mine) }
        let boundaries = ContentStream.boundaries(in: operations)
        // Better still is a place outside every marked section, so the thing does not
        // split one in two. It is taken when getting there passes nothing else.
        let clear = ContentStream.boundaries(in: operations, outsideMarkedContent: true)
        let everything = others + backdrops
        func after(_ position: Int) -> Destination {
            var place = min(max(position + 1, 0), operations.count)
            while place < operations.count, !boundaries[place] { place += 1 }
            var further = place
            while further < operations.count, !clear[further] { further += 1 }
            if further != place, !everything.contains(where: { $0.last >= place && $0.first < further && $0.overlaps(mine) }) { place = further }
            return place >= operations.count ? .end : .before(place)
        }
        func before(_ position: Int) -> Destination {
            var place = min(max(position, 0), operations.count)
            while place > 0, !boundaries[place] { place -= 1 }
            var further = place
            while further > 0, !clear[further] { further -= 1 }
            if further != place, !everything.contains(where: { $0.first < place && $0.last >= further && $0.overlaps(mine) }) { place = further }
            return .before(place)
        }
        switch move {
        case .toFront: return above.isEmpty ? nil : .end
        case .forward: return above.min { $0.last < $1.last }.map { after($0.last) }
        case .backward: return below.max { $0.first < $1.first }.map { before($0.first) }
        case .toBack: return below.min { $0.first < $1.first }.map { before($0.first) }
        }
    }

    private func moves(for thing: Thing, onPageAt index: Int) throws -> Set<StackingMove> {
        guard let (interpretation, _, mine, others, backdrops) = try layers(around: thing, onPageAt: index) else { return [] }
        let operations = interpretation.streams[0].content.operations
        return Set(StackingMove.allCases.filter { destination($0, for: mine, among: others, backdrops: backdrops, in: operations) != nil })
    }

    /// The moves that would change how a picture is stacked: forward when something lies
    /// over it, back when something lies under it.
    public func stackingMoves(forImage id: Int, onPageAt index: Int) throws -> Set<StackingMove> {
        guard try pageContent(at: index).images.first(where: { $0.id == id })?.isEditable == true else { return [] }
        return try moves(for: .image(id), onPageAt: index)
    }

    public func stackingMoves(forBlock id: Int, onPageAt index: Int) throws -> Set<StackingMove> {
        guard try pageContent(at: index).blocks.first(where: { $0.id == id })?.isEditable == true else { return [] }
        return try moves(for: .block(id), onPageAt: index)
    }

    /// Moves a picture in the page's stacking order: to the very front or back, or past
    /// the nearest thing that lies over or under it. Whatever clipped it or made it see
    /// through goes with it.
    ///
    /// Nothing is sent behind what covers the whole page, such as a background.
    ///
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func restack(image id: Int, onPageAt index: Int, _ move: StackingMove) throws -> Bool {
        guard let (interpretation, content, mine, others, backdrops) = try layers(around: .image(id), onPageAt: index),
              let image = content.images.first(where: { $0.id == id })
        else { throw SheafError.malformed("the page has no such picture") }
        guard image.isEditable else { throw SheafError.unsupported("changing this picture") }
        let operations = interpretation.streams[0].content.operations
        guard let destination = destination(move, for: mine, among: others, backdrops: backdrops, in: operations) else { return false }
        let range = mine.first...mine.last
        let block = ContentStream.lifted(Array(operations[range]), from: ContentStream.drawingState(before: range.lowerBound, in: operations))
        var replacements: [Int: [ContentStream.Operation]] = [:]
        for position in range { replacements[position] = [] }
        try rewritePage(at: index, interpretation, replacing: replacements, inserting: block, at: destination.position)
        return true
    }

    /// Moves a block of text in the page's stacking order, as `restack(image:onPageAt:_:)` does a picture.
    @discardableResult
    public mutating func restack(block id: Int, onPageAt index: Int, _ move: StackingMove) throws -> Bool {
        guard let (interpretation, content, mine, others, backdrops) = try layers(around: .block(id), onPageAt: index),
              let block = content.blocks.first(where: { $0.id == id })
        else { throw SheafError.malformed("the page has no such block of text") }
        guard block.isEditable else { throw SheafError.unsupported("changing this text") }
        let operations = interpretation.streams[0].content.operations
        guard let destination = destination(move, for: mine, among: others, backdrops: backdrops, in: operations) else { return false }
        // The text is taken out where it is and set again, glyph for glyph, at its new place.
        var emitter = TextEmitter(fontPrefix: fontPrefix(), in: self)
        let glyphs = block.lines.flatMap(\.glyphs).filter { !$0.isImplied }
        for glyph in glyphs {
            guard let resource = interpretation.fontNames[glyph.font] else { throw SheafError.unsupported("changing this text") }
            emitter.exact(glyph, font: interpretation.fonts[glyph.font], resource: resource)
        }
        let addition = emitter.addition(in: &self)
        try rewritePage(at: index, interpretation, removing: glyphs, adding: addition, at: destination.position)
        return true
    }

    /// Draws a picture a second time, on top of everything, moved by an offset on the
    /// page as displayed. Both use the same image, so the file hardly grows.
    ///
    /// - Returns: The frame of the copy.
    @discardableResult
    public mutating func duplicateImage(_ id: Int, onPageAt index: Int, dx: Double, dy: Double) throws -> PDFRectangle {
        let interpretation = try interpret(pageAt: index)
        let content = Self.content(from: interpretation, source: self)
        guard let image = content.images.first(where: { $0.id == id }) else { throw SheafError.malformed("the page has no such picture") }
        guard image.isEditable, let (range, copy) = pictureOperations(for: image, interpretation, matrix: image.matrix.then(.translation(dx, dy))) else {
            throw SheafError.unsupported("changing this picture")
        }
        let operations = interpretation.streams[0].content.operations
        let block = ContentStream.lifted(copy, from: ContentStream.drawingState(before: range.lowerBound, in: operations))
        try rewritePage(at: index, interpretation, inserting: block)
        return PDFRectangle(x: image.frame.x + dx, y: image.frame.y + dy, width: image.frame.width, height: image.frame.height)
    }
}
