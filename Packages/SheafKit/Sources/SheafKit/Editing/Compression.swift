import Foundation

/// How hard to squeeze a document.
public struct CompressionOptions: Sendable, Equatable {
    /// Pictures finer than this many pixels per inch, at the size they are shown, are
    /// scaled down to it. `nil` keeps every picture's pixels.
    public var maximumImageResolution: Double?
    /// JPEG quality for photographs, from 0 to 1. `nil` keeps every pixel value exact.
    public var imageQuality: Double?
    /// Drops what readers never show: page thumbnails, and the private working data that
    /// design apps leave in files they export.
    public var removesExtras = true

    public init(maximumImageResolution: Double? = nil, imageQuality: Double? = nil, removesExtras: Bool = true) {
        self.maximumImageResolution = maximumImageResolution
        self.imageQuality = imageQuality
        self.removesExtras = removesExtras
    }

    /// Nothing visible changes: tighter packing only.
    public static let lossless = CompressionOptions()
    /// Good on screen and in print.
    public static let balanced = CompressionOptions(maximumImageResolution: 150, imageQuality: 0.65)
    /// For sending. Pictures soften when zoomed in.
    public static let smallest = CompressionOptions(maximumImageResolution: 96, imageQuality: 0.4)
}

extension PDFEditor {
    /// The document written out as small as the options allow.
    ///
    /// Always: unused material is left out, uncompressed data is compressed, identical
    /// streams are stored once and small objects are packed together. With picture options,
    /// photographs are scaled to the resolution asked for and stored as JPEG; drawings and
    /// screenshots are scaled but kept exact. Pictures whose colors are not plain gray or
    /// RGB, and those in formats made for scans of text, are left as they are.
    ///
    /// - Parameter progress: Called with a value from 0 to 1 as work proceeds. Return
    ///   `false` to stop, which throws `CancellationError`.
    public func compressed(
        _ options: CompressionOptions, protection: Protection = .keep, progress: ((Double) -> Bool)? = nil
    ) throws -> Data {
        var copy = self
        func report(_ value: Double) throws {
            if let progress, !progress(value) { throw CancellationError() }
        }
        try report(0)
        if options.maximumImageResolution != nil || options.imageQuality != nil {
            let usages = try copy.imageUsages()
            let images = usages.keys.sorted()
            for (index, id) in images.enumerated() {
                try report(0.05 + 0.75 * Double(index) / Double(max(images.count, 1)))
                guard let usage = usages[id] else { continue }
                try copy.recompressImage(id, shownAt: usage, options)
            }
        }
        try report(0.8)
        try copy.tidyStreams(removingExtras: options.removesExtras)
        try report(0.9)
        let data = try copy.rewritten(protection: protection, options: WriteOptions(packsObjects: true, mergesDuplicates: true))
        try report(1)
        return data
    }

    // MARK: Where pictures are shown

    /// The largest size, in points, at which each picture appears on any page.
    func imageUsages() throws -> [ObjectID: PageSize] {
        var usages: [ObjectID: PageSize] = [:]
        var forms: [ObjectID: [(image: ObjectID, matrix: Affine)]] = [:]
        var inProgress: Set<ObjectID> = []

        func placements(in content: Data, resources: PDFDictionary, depth: Int) throws -> [(image: ObjectID, matrix: Affine)] {
            // Pictures are only ever drawn with this operator.
            guard content.range(of: Data("Do".utf8)) != nil,
                  let xObjects = try value("XObject", in: resources).dictionaryValue
            else { return [] }
            var result: [(ObjectID, Affine)] = []
            var matrix = Affine.identity
            var stack: [Affine] = []
            for operation in ContentStream(data: content).operations {
                switch operation.name {
                case "q":
                    if stack.count < 256 { stack.append(matrix) }
                case "Q":
                    matrix = stack.popLast() ?? matrix
                case "cm":
                    let values = operation.operands.compactMap(\.doubleValue)
                    guard values.count == 6 else { continue }
                    matrix = Affine(a: values[0], b: values[1], c: values[2], d: values[3], e: values[4], f: values[5]).then(matrix)
                case "Do":
                    guard let name = operation.operands.first?.nameValue, let id = xObjects[name]?.referenceValue,
                          let stream = try? object(id).streamValue, result.count < 10_000
                    else { continue }
                    switch stream.dictionary["Subtype"]?.nameValue {
                    case "Image":
                        result.append((id, matrix))
                    case "Form":
                        for placement in try formPlacements(id, stream, inheriting: resources, depth: depth) {
                            result.append((placement.image, placement.matrix.then(matrix)))
                        }
                    default:
                        break
                    }
                default:
                    break
                }
            }
            return result
        }

        /// The pictures a form draws, in the form's own coordinates. Worked out once per form.
        func formPlacements(_ id: ObjectID, _ stream: PDFStream, inheriting resources: PDFDictionary, depth: Int) throws -> [(image: ObjectID, matrix: Affine)] {
            if let known = forms[id] { return known }
            guard depth < 8, inProgress.insert(id).inserted, let content = try? decodedData(of: stream) else { return [] }
            defer { inProgress.remove(id) }
            let own = try value("Resources", in: stream.dictionary).dictionaryValue ?? resources
            let values = try value("Matrix", in: stream.dictionary).arrayValue?.compactMap(\.doubleValue) ?? []
            let formMatrix = values.count == 6 ? Affine(a: values[0], b: values[1], c: values[2], d: values[3], e: values[4], f: values[5]) : .identity
            let found = try placements(in: content, resources: own, depth: depth + 1).map { ($0.image, $0.matrix.then(formMatrix)) }
            forms[id] = found
            return found
        }

        func record(_ found: [(image: ObjectID, matrix: Affine)]) {
            for (image, matrix) in found {
                // The picture fills the unit square, which the matrix stretches onto the page.
                let width = (matrix.a * matrix.a + matrix.b * matrix.b).squareRoot()
                let height = (matrix.c * matrix.c + matrix.d * matrix.d).squareRoot()
                let known = usages[image] ?? PageSize(width: 0, height: 0)
                usages[image] = PageSize(width: max(known.width, width), height: max(known.height, height))
            }
        }

        for page in try pageIDs() {
            guard let dictionary = try object(page).dictionaryValue else { continue }
            let resources = try inherited("Resources", forPage: page).map(resolve)?.dictionaryValue ?? [:]
            if let content = try? contentStream(forPage: page).data() {
                record(try placements(in: content, resources: resources, depth: 0))
            }
            // Stamps and signatures keep their pictures in the annotation's appearance.
            for entry in try value("Annots", in: dictionary).arrayValue ?? [] {
                guard let annotation = try? resolve(entry).dictionaryValue,
                      let appearances = try? value("AP", in: annotation).dictionaryValue,
                      let id = appearances["N"]?.referenceValue, let stream = try? object(id).streamValue,
                      let rect = PDFRectangle(try value("Rect", in: annotation)),
                      let box = PDFRectangle(try value("BBox", in: stream.dictionary)), box.width > 0, box.height > 0
                else { continue }
                let fit = Affine.scale(rect.width / box.width, rect.height / box.height)
                record(try formPlacements(id, stream, inheriting: [:], depth: 0).map { ($0.image, $0.matrix.then(fit)) })
            }
        }
        return usages
    }

    // MARK: Pictures

    private mutating func recompressImage(_ id: ObjectID, shownAt size: PageSize, _ options: CompressionOptions) throws {
        guard let stream = try object(id).streamValue else { return }
        let dictionary = stream.dictionary
        guard dictionary["Subtype"]?.nameValue == "Image",
              try value("ImageMask", in: dictionary).boolValue != true,
              try value("BitsPerComponent", in: dictionary).intValue == 8,
              dictionary["Decode"] == nil,
              // A mask given as a range of colors needs the colors to stay exact.
              try value("Mask", in: dictionary).arrayValue == nil,
              let width = try value("Width", in: dictionary).intValue, width > 0,
              let height = try value("Height", in: dictionary).intValue, height > 0,
              let components = try components(ofColorSpace: dictionary["ColorSpace"] ?? .null)
        else { return }
        // Colors blended ahead of time against a backdrop must stay exact too.
        if let mask = try value("SMask", in: dictionary).streamValue, mask.dictionary["Matte"] != nil { return }
        // Icons and other small pictures have nothing to give, and show every lost detail.
        guard width * height >= 64 * 64, stream.data.count >= 16 * 1024, size.width > 0, size.height > 0 else { return }

        var scale = 1.0
        if let limit = options.maximumImageResolution {
            let resolution = min(Double(width) / size.width, Double(height) / size.height) * 72
            // Scaling down by a small amount blurs for little gain.
            if resolution > limit * 1.25 { scale = limit / resolution }
        }
        let targetWidth = max(Int((Double(width) * scale).rounded()), 1), targetHeight = max(Int((Double(height) * scale).rounded()), 1)

        let filters = try StreamFilters.filters(of: dictionary, resolve: resolve).map(\.name)
        let source: ImageRecoder.Source
        if filters == ["DCTDecode"] || filters == ["DCT"] {
            source = .jpeg(stream.data)
        } else if filters.allSatisfy({ !StreamFilters.imageFilters.contains($0) }), let samples = try? decodedData(of: stream) {
            source = .raw(samples, width: width, height: height)
        } else {
            return
        }
        guard let output = ImageRecoder.recode(source, components: components, width: targetWidth, height: targetHeight, quality: options.imageQuality),
              // Recompressing costs quality; it has to buy a real saving.
              Double(output.data.count) < Double(stream.data.count) * 0.9
        else { return }

        var updated = dictionary
        updated["Width"] = .integer(output.width)
        updated["Height"] = .integer(output.height)
        updated["Filter"] = .name(output.isJPEG ? "DCTDecode" : "FlateDecode")
        for key in ["DecodeParms", "Length", "F", "FFilter", "FDecodeParms", "DL"] as [PDFName] { updated[key] = nil }
        set(.stream(PDFStream(dictionary: updated, data: output.data)), for: id)
    }

    /// One for gray, three for RGB, `nil` for color spaces whose numbers are not plain
    /// gray or RGB levels.
    private func components(ofColorSpace object: PDFObject) throws -> Int? {
        let space = try resolve(object)
        switch space.nameValue {
        case "DeviceGray", "CalGray": return 1
        case "DeviceRGB", "CalRGB": return 3
        default: break
        }
        guard let parts = space.arrayValue, let kind = try parts.first.map(resolve)?.nameValue else { return nil }
        switch kind {
        case "CalGray": return 1
        case "CalRGB": return 3
        case "ICCBased":
            guard parts.count > 1, let count = try resolve(parts[1]).streamValue?.dictionary["N"]?.intValue, count == 1 || count == 3 else { return nil }
            return count
        default:
            return nil
        }
    }

    // MARK: Everything else

    /// Compresses data stored plain or with older, weaker methods, and takes out extras.
    private mutating func tidyStreams(removingExtras: Bool) throws {
        let numbers = Set(base.objectNumbers).union(changedNumbers).sorted()
        let weakFilters: Set<PDFName> = ["LZWDecode", "LZW", "ASCIIHexDecode", "AHx", "ASCII85Decode", "A85", "RunLengthDecode", "RL"]
        for number in numbers {
            let id = id(forNumber: number)
            guard let object = try? object(id) else { continue }
            switch object {
            case .dictionary(var dictionary):
                guard removingExtras else { continue }
                let before = dictionary.count
                dictionary["PieceInfo"] = nil
                if dictionary["Type"]?.nameValue == "Page" { dictionary["Thumb"] = nil }
                if dictionary.count != before { set(.dictionary(dictionary), for: id) }

            case .stream(var stream):
                let type = stream.dictionary["Type"]?.nameValue
                // These are rebuilt when the file is written, or must stay readable as text.
                if type == "XRef" || type == "ObjStm" || type == "Metadata" { continue }
                var changed = false
                if removingExtras {
                    let before = stream.dictionary.count
                    stream.dictionary["PieceInfo"] = nil
                    // A copy of the facts about one picture, often larger than the picture.
                    if stream.dictionary["Subtype"]?.nameValue == "Image" { stream.dictionary["Metadata"] = nil }
                    changed = stream.dictionary.count != before
                }
                let filters = (try? StreamFilters.filters(of: stream.dictionary, resolve: resolve).map(\.name)) ?? []
                let isPlain = filters.isEmpty && stream.data.count > 64
                let isWeak = !filters.isEmpty && filters.allSatisfy(weakFilters.contains)
                if isPlain || isWeak, let decoded = try? decodedData(of: stream) {
                    let packed = Flate.deflate(decoded)
                    if packed.count < stream.data.count {
                        stream.data = packed
                        stream.dictionary["Filter"] = .name("FlateDecode")
                        for key in ["DecodeParms", "Length", "DL"] as [PDFName] { stream.dictionary[key] = nil }
                        changed = true
                    }
                }
                if changed { set(.stream(stream), for: id) }

            default:
                continue
            }
        }
    }
}
