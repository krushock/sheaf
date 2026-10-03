import Foundation

/// Encrypts the strings and stream data of one object while it is written.
protocol ObjectCipher {
    func encrypt(string: Data) -> Data
    func encrypt(streamData: Data) -> Data
}

/// Writes objects in PDF syntax.
enum Serializer {
    static func append(_ object: PDFObject, to output: inout Data, cipher: (any ObjectCipher)? = nil) {
        switch object {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .boolean(let value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .integer(let value):
            output.append(contentsOf: String(value).utf8)
        case .real(let value):
            output.append(contentsOf: format(value).utf8)
        case .string(let value):
            append(string: cipher?.encrypt(string: value) ?? value, to: &output)
        case .name(let value):
            append(name: value, to: &output)
        case .array(let elements):
            output.append(0x5B)
            for (index, element) in elements.enumerated() {
                if index > 0 { output.append(0x20) }
                append(element, to: &output, cipher: cipher)
            }
            output.append(0x5D)
        case .dictionary(let dictionary):
            append(dictionary: dictionary, to: &output, cipher: cipher)
        case .stream(let stream):
            let data = cipher?.encrypt(streamData: stream.data) ?? stream.data
            var dictionary = stream.dictionary
            dictionary["Length"] = .integer(data.count)
            append(dictionary: dictionary, to: &output, cipher: cipher)
            output.append(contentsOf: "\nstream\n".utf8)
            output.append(data)
            output.append(contentsOf: "\nendstream".utf8)
        case .reference(let id):
            output.append(contentsOf: "\(id.number) \(id.generation) R".utf8)
        }
    }

    /// `12 0 obj … endobj` followed by a line feed.
    static func append(indirect object: PDFObject, id: ObjectID, to output: inout Data, cipher: (any ObjectCipher)? = nil) {
        output.append(contentsOf: "\(id.number) \(id.generation) obj\n".utf8)
        append(object, to: &output, cipher: cipher)
        output.append(contentsOf: "\nendobj\n".utf8)
    }

    static func data(_ object: PDFObject) -> Data {
        var output = Data()
        append(object, to: &output)
        return output
    }

    private static func append(dictionary: PDFDictionary, to output: inout Data, cipher: (any ObjectCipher)?) {
        output.append(contentsOf: "<<".utf8)
        // Sorted so the same object always produces the same bytes.
        for key in dictionary.keys.sorted() {
            guard let value = dictionary[key] else { continue }
            output.append(0x20)
            append(name: key, to: &output)
            output.append(0x20)
            append(value, to: &output, cipher: cipher)
        }
        output.append(contentsOf: " >>".utf8)
    }

    private static func append(name: PDFName, to output: inout Data) {
        output.append(0x2F)
        for byte in name.bytes {
            if byte > 0x20, byte < 0x7F, byte != 0x23, !isPDFDelimiter(byte) {
                output.append(byte)
            } else {
                output.append(0x23)
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            }
        }
    }

    private static func append(string: Data, to output: inout Data) {
        let isReadable = string.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        if isReadable {
            output.append(0x28)
            for byte in string {
                if byte == 0x28 || byte == 0x29 || byte == 0x5C { output.append(0x5C) }
                output.append(byte)
            }
            output.append(0x29)
        } else {
            output.append(0x3C)
            for byte in string {
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            }
            output.append(0x3E)
        }
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// A real in plain decimal notation, which is all PDF accepts.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
