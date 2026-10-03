import Foundation

/// The number and generation that identify an indirect object.
public struct ObjectID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var number: Int
    public var generation: Int

    public init(_ number: Int, _ generation: Int = 0) {
        self.number = number
        self.generation = generation
    }

    public static func < (a: ObjectID, b: ObjectID) -> Bool {
        (a.number, a.generation) < (b.number, b.generation)
    }

    public var description: String { "\(number) \(generation) R" }
}

/// A PDF name, without its leading slash.
///
/// Names are byte sequences, not text. To keep any name exact through a round trip, the
/// storage holds one Unicode scalar per byte. Names written in ASCII, which is nearly all
/// of them, read naturally: `"Type"`, `"MediaBox"`.
public struct PDFName: Hashable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    /// From text whose scalars are all below U+0100, such as a literal in source code.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(bytes: some Sequence<UInt8>) {
        var scalars = String.UnicodeScalarView()
        for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
        rawValue = String(scalars)
    }

    public var bytes: [UInt8] {
        rawValue.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    /// The name as text, read as UTF-8 when its bytes allow, for showing to people.
    public var text: String {
        String(bytes: bytes, encoding: .utf8) ?? rawValue
    }

    public static func < (a: PDFName, b: PDFName) -> Bool { a.rawValue < b.rawValue }

    public var description: String { "/" + rawValue }
}

public typealias PDFDictionary = [PDFName: PDFObject]

/// A stream: a dictionary plus bytes.
public struct PDFStream: Sendable, Equatable {
    public var dictionary: PDFDictionary
    /// The bytes as stored in the file, decrypted but with filters such as Flate still applied.
    public var data: Data

    public init(dictionary: PDFDictionary = [:], data: Data) {
        self.dictionary = dictionary
        self.data = data
    }
}

/// Any PDF object.
public indirect enum PDFObject: Sendable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    /// A string's bytes. Use `PDFText` to read or make text strings.
    case string(Data)
    case name(PDFName)
    case array([PDFObject])
    case dictionary(PDFDictionary)
    case stream(PDFStream)
    case reference(ObjectID)
}

extension PDFObject {
    public var isNull: Bool { self == .null }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { value } else { nil }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        // Some writers emit whole numbers with a fraction: `/Rotate 90.0`.
        case .real(let value) where value == value.rounded() && abs(value) < 1e15: Int(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        default: nil
        }
    }

    public var stringValue: Data? {
        if case .string(let value) = self { value } else { nil }
    }

    /// A text string decoded to Swift text.
    public var textValue: String? {
        stringValue.map(PDFText.decode)
    }

    public var nameValue: PDFName? {
        if case .name(let value) = self { value } else { nil }
    }

    public var arrayValue: [PDFObject]? {
        if case .array(let value) = self { value } else { nil }
    }

    /// The dictionary of a dictionary or of a stream.
    public var dictionaryValue: PDFDictionary? {
        switch self {
        case .dictionary(let value): value
        case .stream(let stream): stream.dictionary
        default: nil
        }
    }

    public var streamValue: PDFStream? {
        if case .stream(let value) = self { value } else { nil }
    }

    public var referenceValue: ObjectID? {
        if case .reference(let value) = self { value } else { nil }
    }
}

extension PDFObject: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(arrayLiteral elements: PDFObject...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (PDFName, PDFObject)...) {
        self = .dictionary(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// A rectangle as PDF stores it: two opposite corners, in any order.
public struct PDFRectangle: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init?(_ object: PDFObject) {
        guard let values = object.arrayValue?.compactMap(\.doubleValue), values.count == 4 else { return nil }
        x = min(values[0], values[2])
        y = min(values[1], values[3])
        width = abs(values[2] - values[0])
        height = abs(values[3] - values[1])
    }

    /// The smallest rectangle containing all the points, or `nil` when there are none.
    public init?(enclosing points: [PDFPoint]) {
        guard let first = points.first else { return nil }
        var (minX, minY, maxX, maxY) = (first.x, first.y, first.x, first.y)
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func contains(_ point: PDFPoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }

    public var object: PDFObject {
        .array([x, y, x + width, y + height].map { $0 == $0.rounded() && abs($0) < 1e15 ? .integer(Int($0)) : .real($0) })
    }
}
