import Foundation

/// A place on a page that looks like it was drawn to be filled in.
public struct FieldCandidate: Sendable, Equatable {
    /// `.text` or `.checkbox`.
    public var kind: FormField.Kind
    public var rect: PDFRectangle
    /// A text box tall enough for several lines.
    public var isMultiline = false

    public init(kind: FormField.Kind, rect: PDFRectangle, isMultiline: Bool = false) {
        self.kind = kind
        self.rect = rect
        self.isMultiline = isMultiline
    }
}

extension PDFEditor {
    /// Looks through a page's drawing for boxes and lines meant to be written in: outlined
    /// or white rectangles become text fields, small squares become checkboxes, and
    /// horizontal rules become text fields sitting on them.
    ///
    /// This only sees shapes. Whether a box already holds printed text, which would make
    /// it a table cell and not a field, is for the caller to check.
    public func detectFieldCandidates(onPageAt index: Int) throws -> [FieldCandidate] {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        let page = pages[index]
        let pageBox = try pageBox(at: index)
        let resources = try inherited("Resources", forPage: page).map(resolve)?.dictionaryValue ?? [:]

        var boxes: [(rect: PDFRectangle, isOutlined: Bool)] = []
        var rules: [PDFRectangle] = []
        var visiting: Set<ObjectID> = []

        func isLight(_ color: [Double]) -> Bool {
            switch color.count {
            case 1: color[0] > 0.9
            case 3: color.allSatisfy { $0 > 0.9 }
            case 4: color.allSatisfy { $0 < 0.1 }
            default: false
            }
        }

        func scan(_ content: Data, resources: PDFDictionary, base: Affine, depth: Int) throws {
            var matrix = base
            // Black is what a page starts with.
            var fill: [Double] = [0]
            var stack: [(Affine, [Double])] = []
            var rectangles: [PDFRectangle] = []
            var subpaths: [[PDFPoint]] = []
            var hasCurve = false

            func record(_ rect: PDFRectangle, stroked: Bool, filled: Bool) {
                guard boxes.count + rules.count < 5000 else { return }
                if rect.height <= 2.5, rect.width >= 36 {
                    rules.append(rect)
                } else if rect.width > 2.5, rect.height > 2.5, stroked || (filled && isLight(fill)) {
                    boxes.append((rect, stroked))
                }
            }

            for operation in ContentStream(data: content).operations {
                let numbers = operation.operands.compactMap(\.doubleValue)
                switch operation.name {
                case "q":
                    if stack.count < 256 { stack.append((matrix, fill)) }
                case "Q":
                    if let saved = stack.popLast() { (matrix, fill) = saved }
                case "cm":
                    guard numbers.count == 6 else { continue }
                    matrix = Affine(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], e: numbers[4], f: numbers[5]).then(matrix)
                case "g", "rg", "k":
                    fill = numbers
                case "sc", "scn":
                    // Patterns and the like have no numbers to judge by; treat them as dark.
                    fill = numbers.count == operation.operands.count ? numbers : [0]
                case "re":
                    guard numbers.count == 4 else { continue }
                    let corners = [PDFPoint(x: numbers[0], y: numbers[1]), PDFPoint(x: numbers[0] + numbers[2], y: numbers[1] + numbers[3])].map(matrix.apply)
                    // Only rectangles that are still upright after the page's transforms.
                    let isUpright = (abs(matrix.b) < 0.001 && abs(matrix.c) < 0.001) || (abs(matrix.a) < 0.001 && abs(matrix.d) < 0.001)
                    if isUpright, let rect = PDFRectangle(enclosing: corners) { rectangles.append(rect) } else { hasCurve = true }
                case "m":
                    guard numbers.count == 2 else { continue }
                    subpaths.append([matrix.apply(PDFPoint(x: numbers[0], y: numbers[1]))])
                case "l":
                    guard numbers.count == 2, !subpaths.isEmpty else { continue }
                    subpaths[subpaths.count - 1].append(matrix.apply(PDFPoint(x: numbers[0], y: numbers[1])))
                case "c", "v", "y":
                    hasCurve = true
                case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
                    defer {
                        rectangles = []
                        subpaths = []
                        hasCurve = false
                    }
                    guard operation.name != "n", !hasCurve else { continue }
                    let stroked = ["S", "s", "B", "B*", "b", "b*"].contains(operation.name)
                    let filled = operation.name != "S" && operation.name != "s"
                    for rect in rectangles { record(rect, stroked: stroked, filled: filled) }
                    for points in subpaths {
                        if points.count == 2, stroked, abs(points[0].y - points[1].y) < 0.5 {
                            record(PDFRectangle(x: min(points[0].x, points[1].x), y: points[0].y, width: abs(points[0].x - points[1].x), height: 0), stroked: true, filled: false)
                        } else if (4...5).contains(points.count), let rect = PDFRectangle(enclosing: points),
                                  // Four corners of an upright rectangle, drawn line by line.
                                  points.allSatisfy({ (abs($0.x - rect.x) < 0.5 || abs($0.x - rect.x - rect.width) < 0.5) && (abs($0.y - rect.y) < 0.5 || abs($0.y - rect.y - rect.height) < 0.5) }) {
                            record(rect, stroked: stroked, filled: filled)
                        }
                    }
                case "Do":
                    guard depth < 3, let name = operation.operands.first?.nameValue,
                          let id = try value("XObject", in: resources).dictionaryValue?[name]?.referenceValue,
                          let stream = try? object(id).streamValue, stream.dictionary["Subtype"]?.nameValue == "Form",
                          visiting.insert(id).inserted, let inner = try? decodedData(of: stream)
                    else { continue }
                    defer { visiting.remove(id) }
                    let values = try value("Matrix", in: stream.dictionary).arrayValue?.compactMap(\.doubleValue) ?? []
                    let formMatrix = values.count == 6 ? Affine(a: values[0], b: values[1], c: values[2], d: values[3], e: values[4], f: values[5]) : .identity
                    let own = try value("Resources", in: stream.dictionary).dictionaryValue ?? resources
                    try scan(inner, resources: own, base: formMatrix.then(matrix), depth: depth + 1)
                default:
                    break
                }
            }
        }
        try scan(try contentStream(forPage: page).data(), resources: resources, base: .identity, depth: 0)

        func overlap(_ a: PDFRectangle, _ b: PDFRectangle) -> Double {
            let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x), height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
            guard width > 0, height > 0 else { return 0 }
            return width * height / max(min(a.width * a.height, b.width * b.height), 0.01)
        }

        var candidates: [FieldCandidate] = []
        let pageArea = pageBox.width * pageBox.height
        for box in boxes {
            let rect = box.rect
            // Frames around the whole page or most of it are decoration.
            guard rect.width * rect.height < pageArea * 0.4 else { continue }
            if rect.width >= 6, rect.width <= 26, rect.height >= 6, rect.height <= 26, abs(rect.width - rect.height) <= max(2, rect.width * 0.2) {
                candidates.append(FieldCandidate(kind: .checkbox, rect: rect))
            } else if rect.width >= 36, rect.height >= 9, rect.height <= 400 {
                candidates.append(FieldCandidate(kind: .text, rect: rect, isMultiline: rect.height > 40))
            }
        }
        for rule in rules {
            // A rule that is one side of a box, or runs through one, is part of that box.
            let touchesBox = boxes.contains { box in
                guard rule.x < box.rect.x + box.rect.width, rule.x + rule.width > box.rect.x else { return false }
                let onAnEdge = abs(rule.y - box.rect.y) < 1.5 || abs(rule.y - box.rect.y - box.rect.height) < 1.5
                // Inside a frame around the whole page is not inside a box.
                let isInside = rule.y > box.rect.y && rule.y < box.rect.y + box.rect.height && box.rect.width * box.rect.height < pageArea * 0.4
                return onAnEdge || isInside
            }
            guard !touchesBox, rule.width < pageBox.width * 0.98 else { continue }
            candidates.append(FieldCandidate(kind: .text, rect: PDFRectangle(x: rule.x, y: rule.y + rule.height + 1, width: rule.width, height: 16)))
        }

        // The same box drawn twice, filled and then outlined, counts once. Places that
        // already have a field are left alone.
        let existing = try annotations(forPage: page).filter { $0.subtype == "Widget" }.map(\.rect)
        var kept: [FieldCandidate] = []
        for candidate in candidates where pageBox.contains(PDFPoint(x: candidate.rect.x + candidate.rect.width / 2, y: candidate.rect.y + candidate.rect.height / 2)) {
            if existing.contains(where: { overlap($0, candidate.rect) > 0.3 }) { continue }
            if kept.contains(where: { overlap($0.rect, candidate.rect) > 0.6 }) { continue }
            kept.append(candidate)
            if kept.count >= 400 { break }
        }
        // Reading order: rows from the top, each from the left.
        return kept.sorted { a, b in
            let rowA = a.rect.y + a.rect.height, rowB = b.rect.y + b.rect.height
            return abs(rowA - rowB) > 6 ? rowA > rowB : a.rect.x < b.rect.x
        }
    }
}
