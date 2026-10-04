import Foundation

/// Where something on a page comes from: an operation in one of the page's streams.
struct ContentSource: Hashable, Sendable {
    /// Index into `Interpretation.streams`. Zero is the page's own content.
    var stream: Int
    var operation: Int
}

/// One glyph as the page draws it.
struct RawGlyph: Sendable {
    var code: Int
    /// Index into `Interpretation.fonts`.
    var font: Int
    var text: String?
    /// Takes glyph space, in which the font is one unit tall, to the page as displayed.
    var matrix: Affine
    /// The glyph's own width in thousandths of the font size.
    var width: Double
    var color: PDFColor
    var renderMode: Int
    var charSpacing: Double
    var wordSpacing: Double
    var horizontalScale: Double
    /// The font size the content sets, before any scaling by the matrices around it.
    var textFontSize: Double
    var source: ContentSource
    /// Which glyph of the operation this is, counting from zero.
    var index: Int
}

/// A picture as the page places it.
struct RawImage: Sendable {
    /// Takes the unit square to where the picture is on the page as displayed.
    var matrix: Affine
    /// The image object, or `nil` for a picture written inline in the content.
    var object: ObjectID?
    var name: PDFName?
    var source: ContentSource
    /// How much of what is behind the picture it hides: 1 hides it all.
    var alpha = 1.0
}

/// A painted shape.
struct RawPath: Sendable {
    var bounds: PDFRectangle
    var stream: Int
    /// The operations that build and paint the shape.
    var operations: ClosedRange<Int>
}

/// One stream of drawing instructions: the page's own, or a form drawn from it.
struct InterpretedStream {
    var content: ContentStream
    /// The form the instructions belong to. `nil` for the page's own content.
    var form: ObjectID?
    /// The stream and operation that drew this form.
    var invokedFrom: ContentSource?
    var resources: PDFDictionary
}

/// Everything a page draws, with where each thing is and which instruction draws it.
struct Interpretation {
    var glyphs: [RawGlyph] = []
    var images: [RawImage] = []
    var paths: [RawPath] = []
    var fonts: [PageFont] = []
    var fontIDs: [ObjectID?] = []
    /// The name the page's own content uses for each font, where it uses it.
    var fontNames: [PDFName?] = []
    var streams: [InterpretedStream] = []
    var geometry: PageGeometry
    /// Whether the page's own content ends as it began: nothing saved and not restored,
    /// and the same coordinate system. Drawing added after it then needs no fencing off.
    var endsClean = true
}

extension PDFEditor {
    /// Runs a page's drawing instructions, without drawing, to find out what is where.
    ///
    /// Coordinates are those of the page as displayed: origin at the bottom left of what
    /// the reader sees, upright whichever way the page is turned.
    func interpret(pageAt index: Int, includingPaths: Bool = false) throws -> Interpretation {
        let pages = try pageIDs()
        guard pages.indices.contains(index) else { throw SheafError.pageOutOfRange(index) }
        let page = pages[index]
        let geometry = try geometry(ofPageAt: index)
        var result = Interpretation(geometry: geometry)
        let resources = try inherited("Resources", forPage: page).map(resolve)?.dictionaryValue ?? [:]
        let content = try contentStream(forPage: page)
        result.streams.append(InterpretedStream(content: content, form: nil, invokedFrom: nil, resources: resources))

        var fontsByObject: [ObjectID: Int] = [:]
        var fontsByName: [String: Int] = [:]
        var budget = 2_000_000
        var active: Set<ObjectID> = []

        func fontIndex(named name: PDFName, in resources: PDFDictionary, stream: Int) throws -> Int? {
            guard let entry = try value("Font", in: resources).dictionaryValue?[name] else { return nil }
            if let id = entry.referenceValue, let known = fontsByObject[id] {
                if stream == 0, result.fontNames[known] == nil { result.fontNames[known] = name }
                return known
            }
            let key = "\(stream)/\(name.rawValue)"
            if entry.referenceValue == nil, let known = fontsByName[key] { return known }
            guard let dictionary = try resolve(entry).dictionaryValue else { return nil }
            let font: PageFont
            // Only fonts as the file has them are remembered. A font added or changed
            // since may change again without its own dictionary showing it, as a typed
            // font does when it gains glyphs.
            let cacheID = entry.referenceValue.flatMap { isAsInFile($0) ? $0 : nil }
            if let cacheID, let known = fontCache.font(for: cacheID, dictionary) {
                font = known
            } else {
                guard let read = try? PageFont(dictionary: dictionary, source: self) else { return nil }
                if let cacheID { fontCache.keep(read, for: cacheID, dictionary) }
                font = read
            }
            result.fonts.append(font)
            result.fontIDs.append(entry.referenceValue)
            result.fontNames.append(stream == 0 ? name : nil)
            let index = result.fonts.count - 1
            if let id = entry.referenceValue { fontsByObject[id] = index } else { fontsByName[key] = index }
            return index
        }

        struct State {
            var ctm: Affine
            var font: Int?
            var fontSize = 0.0
            var charSpacing = 0.0
            var wordSpacing = 0.0
            var horizontalScale = 1.0
            var leading = 0.0
            var rise = 0.0
            var renderMode = 0
            var fill = PDFColor.black
            var fillAlpha = 1.0
        }

        func run(_ streamIndex: Int, initial: State, depth: Int) throws {
            let stream = result.streams[streamIndex]
            var state = initial
            var stack: [State] = []
            var textMatrix = Affine.identity, lineMatrix = Affine.identity
            // The shape being built.
            var pathPoints: [PDFPoint] = []
            var pathStart: Int?

            func show(_ string: Data, operation: Int, counter: inout Int) {
                guard let fontIndex = state.font else { return }
                let font = result.fonts[fontIndex]
                for code in font.codes(in: string) {
                    let width = font.width(of: code)
                    let matrix = Affine(a: state.fontSize * state.horizontalScale, d: state.fontSize, f: state.rise).then(textMatrix).then(state.ctm)
                    result.glyphs.append(RawGlyph(
                        code: code, font: fontIndex, text: font.text(of: code), matrix: matrix, width: width, color: state.fill,
                        renderMode: state.fillAlpha <= 0.001 ? 3 : state.renderMode, charSpacing: state.charSpacing, wordSpacing: state.wordSpacing,
                        horizontalScale: state.horizontalScale, textFontSize: state.fontSize,
                        source: ContentSource(stream: streamIndex, operation: operation), index: counter
                    ))
                    counter += 1
                    // Word spacing applies to the space of one-byte fonts only.
                    let spacing = state.charSpacing + (code == 32 && font.codeLength == 1 ? state.wordSpacing : 0)
                    let advance = (width / 1000 * state.fontSize + spacing) * state.horizontalScale
                    textMatrix = Affine.translation(advance, 0).then(textMatrix)
                }
            }
            func nextLine(_ x: Double, _ y: Double) {
                lineMatrix = Affine.translation(x, y).then(lineMatrix)
                textMatrix = lineMatrix
            }
            func color(_ numbers: [Double]) -> PDFColor {
                PDFColor(.array(numbers.map(PDFObject.real))) ?? .black
            }

            for (operationIndex, operation) in stream.content.operations.enumerated() {
                budget -= 1
                guard budget > 0 else { return }
                let numbers = operation.operands.compactMap(\.doubleValue)
                switch operation.name {
                case "q":
                    if stack.count < 256 { stack.append(state) }
                case "Q":
                    if let saved = stack.popLast() { state = saved }
                case "cm":
                    if let matrix = Affine(numbers) { state.ctm = matrix.then(state.ctm) }
                case "BT":
                    textMatrix = .identity
                    lineMatrix = .identity
                case "Tf":
                    if let name = operation.operands.first?.nameValue {
                        state.font = try fontIndex(named: name, in: stream.resources, stream: streamIndex)
                        state.fontSize = numbers.last ?? 0
                    }
                case "Tc": state.charSpacing = numbers.first ?? 0
                case "Tw": state.wordSpacing = numbers.first ?? 0
                case "Tz": state.horizontalScale = (numbers.first ?? 100) / 100
                case "TL": state.leading = numbers.first ?? 0
                case "Ts": state.rise = numbers.first ?? 0
                case "Tr": state.renderMode = Int(max(min(numbers.first ?? 0, 7), 0))
                case "Td":
                    if numbers.count == 2 { nextLine(numbers[0], numbers[1]) }
                case "TD":
                    if numbers.count == 2 {
                        state.leading = -numbers[1]
                        nextLine(numbers[0], numbers[1])
                    }
                case "Tm":
                    if let matrix = Affine(numbers) {
                        textMatrix = matrix
                        lineMatrix = matrix
                    }
                case "T*":
                    nextLine(0, -state.leading)
                case "Tj":
                    var counter = 0
                    if let string = operation.operands.first?.stringValue { show(string, operation: operationIndex, counter: &counter) }
                case "'", "\"":
                    if operation.name == "\"", numbers.count >= 2 {
                        state.wordSpacing = numbers[0]
                        state.charSpacing = numbers[1]
                    }
                    nextLine(0, -state.leading)
                    var counter = 0
                    if let string = operation.operands.last?.stringValue { show(string, operation: operationIndex, counter: &counter) }
                case "TJ":
                    var counter = 0
                    for element in operation.operands.first?.arrayValue ?? [] {
                        if let string = element.stringValue {
                            show(string, operation: operationIndex, counter: &counter)
                        } else if let adjustment = element.doubleValue {
                            textMatrix = Affine.translation(-adjustment / 1000 * state.fontSize * state.horizontalScale, 0).then(textMatrix)
                        }
                    }
                case "g", "rg", "k":
                    state.fill = color(numbers)
                case "sc", "scn":
                    // Patterns and named colors have no plain numbers; they read as black.
                    state.fill = numbers.count == operation.operands.count ? color(numbers) : .black
                case "gs":
                    // A graphics state can set the font, which a few writers rely on.
                    guard let name = operation.operands.first?.nameValue,
                          let states = try value("ExtGState", in: stream.resources).dictionaryValue,
                          let entry = try resolve(states[name] ?? .null).dictionaryValue
                    else { break }
                    // Fully transparent text is there to be found and copied, not seen.
                    if let alpha = try value("ca", in: entry).doubleValue { state.fillAlpha = alpha }
                    if let font = try value("Font", in: entry).arrayValue, font.count == 2, let id = font[0].referenceValue {
                        if let known = fontsByObject[id] {
                            state.font = known
                        } else if let dictionary = try object(id).dictionaryValue, let loaded = try? PageFont(dictionary: dictionary, source: self) {
                            result.fonts.append(loaded)
                            result.fontIDs.append(id)
                            result.fontNames.append(nil)
                            fontsByObject[id] = result.fonts.count - 1
                            state.font = result.fonts.count - 1
                        }
                        state.fontSize = font[1].doubleValue ?? state.fontSize
                    }
                case "BI":
                    result.images.append(RawImage(matrix: state.ctm, object: nil, name: nil, source: ContentSource(stream: streamIndex, operation: operationIndex), alpha: state.fillAlpha))
                case "Do":
                    guard let name = operation.operands.first?.nameValue,
                          let entry = try value("XObject", in: stream.resources).dictionaryValue?[name],
                          let object = try? resolve(entry).streamValue
                    else { continue }
                    let source = ContentSource(stream: streamIndex, operation: operationIndex)
                    switch object.dictionary["Subtype"]?.nameValue {
                    case "Image":
                        result.images.append(RawImage(matrix: state.ctm, object: entry.referenceValue, name: name, source: source, alpha: state.fillAlpha))
                    case "Form":
                        guard depth < 6, result.streams.count < 2000, let id = entry.referenceValue, active.insert(id).inserted,
                              let data = try? decodedData(of: object)
                        else { continue }
                        defer { active.remove(id) }
                        let own = try value("Resources", in: object.dictionary).dictionaryValue ?? stream.resources
                        let formMatrix = Affine(try value("Matrix", in: object.dictionary).arrayValue?.compactMap(\.doubleValue) ?? []) ?? .identity
                        result.streams.append(InterpretedStream(content: ContentStream(data: data), form: id, invokedFrom: source, resources: own))
                        var inner = state
                        inner.ctm = formMatrix.then(state.ctm)
                        try run(result.streams.count - 1, initial: inner, depth: depth + 1)
                    default:
                        break
                    }
                case "m", "l":
                    guard includingPaths, numbers.count == 2 else { continue }
                    if pathStart == nil { pathStart = operationIndex }
                    pathPoints.append(state.ctm.apply(PDFPoint(x: numbers[0], y: numbers[1])))
                case "c", "v", "y":
                    guard includingPaths else { continue }
                    if pathStart == nil { pathStart = operationIndex }
                    var index = 0
                    while index + 1 < numbers.count {
                        pathPoints.append(state.ctm.apply(PDFPoint(x: numbers[index], y: numbers[index + 1])))
                        index += 2
                    }
                case "re":
                    guard includingPaths, numbers.count == 4 else { continue }
                    if pathStart == nil { pathStart = operationIndex }
                    for corner in [(0.0, 0.0), (numbers[2], 0), (0, numbers[3]), (numbers[2], numbers[3])] {
                        pathPoints.append(state.ctm.apply(PDFPoint(x: numbers[0] + corner.0, y: numbers[1] + corner.1)))
                    }
                case "h", "W", "W*":
                    if includingPaths, pathStart == nil, !pathPoints.isEmpty { pathStart = operationIndex }
                case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
                    defer {
                        pathPoints = []
                        pathStart = nil
                    }
                    guard includingPaths, operation.name != "n", let start = pathStart, let bounds = PDFRectangle(enclosing: pathPoints) else { continue }
                    result.paths.append(RawPath(bounds: bounds, stream: streamIndex, operations: start...operationIndex))
                default:
                    break
                }
            }
            if streamIndex == 0 { result.endsClean = stack.isEmpty && state.ctm == initial.ctm }
        }

        try run(0, initial: State(ctm: geometry.toDisplay), depth: 0)
        return result
    }
}
