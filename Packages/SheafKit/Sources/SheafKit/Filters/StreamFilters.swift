import Foundation

/// Undoes the encoding filters applied to a stream's bytes.
enum StreamFilters {
    /// Filters that compress images. Their output is pixels, which the engine never needs,
    /// so such streams are passed through untouched.
    static let imageFilters: Set<PDFName> = ["DCTDecode", "DCT", "JPXDecode", "CCITTFaxDecode", "CCF", "JBIG2Decode"]

    /// The names in `/Filter` and their matching `/DecodeParms`, in the order they apply.
    static func filters(of dictionary: PDFDictionary, resolve: (PDFObject) throws -> PDFObject) rethrows -> [(name: PDFName, parameters: PDFDictionary)] {
        let filter = try resolve(dictionary["Filter"] ?? dictionary["F"] ?? .null)
        let parameters = try resolve(dictionary["DecodeParms"] ?? dictionary["DP"] ?? .null)
        let names: [PDFObject] = filter.arrayValue ?? (filter.isNull ? [] : [filter])
        let parameterList: [PDFObject] = parameters.arrayValue ?? [parameters]
        var result: [(PDFName, PDFDictionary)] = []
        for (index, entry) in names.enumerated() {
            guard let name = try resolve(entry).nameValue else { continue }
            let own = index < parameterList.count ? try resolve(parameterList[index]).dictionaryValue : nil
            result.append((name, own ?? [:]))
        }
        return result
    }

    static func decode(_ stream: PDFStream, resolve: (PDFObject) throws -> PDFObject = { $0 }) throws -> Data {
        var data = stream.data
        for (name, parameters) in try filters(of: stream.dictionary, resolve: resolve) {
            switch name {
            case "FlateDecode", "Fl":
                data = try unpredict(Flate.inflate(data), parameters)
            case "LZWDecode", "LZW":
                data = try unpredict(lzw(data, earlyChange: parameters["EarlyChange"]?.intValue != 0), parameters)
            case "ASCIIHexDecode", "AHx":
                data = asciiHex(data)
            case "ASCII85Decode", "A85":
                data = ascii85(data)
            case "RunLengthDecode", "RL":
                data = runLength(data)
            case "Crypt":
                continue // decryption has already happened by the time filters run
            default:
                throw SheafError.unsupported("stream filter \(name.rawValue)")
            }
        }
        return data
    }

    // MARK: Predictors

    private static func unpredict(_ data: Data, _ parameters: PDFDictionary) throws -> Data {
        let predictor = parameters["Predictor"]?.intValue ?? 1
        guard predictor > 1 else { return data }
        let colors = max(parameters["Colors"]?.intValue ?? 1, 1)
        let bitsPerComponent = max(parameters["BitsPerComponent"]?.intValue ?? 8, 1)
        let columns = max(parameters["Columns"]?.intValue ?? 1, 1)
        guard columns <= 1 << 24, colors <= 64, bitsPerComponent <= 32 else { return data }
        let rowLength = (columns * colors * bitsPerComponent + 7) / 8
        let pixelLength = max((colors * bitsPerComponent + 7) / 8, 1)
        let input = [UInt8](data)

        if predictor == 2 {
            // TIFF: each sample is a difference from the one to its left. Whole bytes only.
            guard bitsPerComponent == 8 else { return data }
            var output = input
            var rowStart = 0
            while rowStart + rowLength <= output.count {
                for index in pixelLength..<rowLength {
                    output[rowStart + index] &+= output[rowStart + index - pixelLength]
                }
                rowStart += rowLength
            }
            return Data(output)
        }

        // PNG: every row starts with a byte naming the filter used for it.
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        var previous = [UInt8](repeating: 0, count: rowLength)
        var row = [UInt8](repeating: 0, count: rowLength)
        var position = 0
        while position < input.count {
            let tag = input[position]
            position += 1
            let available = min(rowLength, input.count - position)
            guard available > 0 else { break }
            for index in 0..<rowLength { row[index] = index < available ? input[position + index] : 0 }
            position += available
            switch tag {
            case 1:
                for index in pixelLength..<max(rowLength, pixelLength) { row[index] &+= row[index - pixelLength] }
            case 2:
                for index in 0..<rowLength { row[index] &+= previous[index] }
            case 3:
                for index in 0..<rowLength {
                    let left = index >= pixelLength ? Int(row[index - pixelLength]) : 0
                    row[index] &+= UInt8((left + Int(previous[index])) / 2)
                }
            case 4:
                for index in 0..<rowLength {
                    let left = index >= pixelLength ? Int(row[index - pixelLength]) : 0
                    let up = Int(previous[index])
                    let upLeft = index >= pixelLength ? Int(previous[index - pixelLength]) : 0
                    let estimate = left + up - upLeft
                    let (dl, du, dul) = (abs(estimate - left), abs(estimate - up), abs(estimate - upLeft))
                    row[index] &+= UInt8(dl <= du && dl <= dul ? left : du <= dul ? up : upLeft)
                }
            default:
                break
            }
            output.append(contentsOf: row[0..<available])
            previous = row
        }
        return Data(output)
    }

    // MARK: Text encodings and old compressors

    private static func asciiHex(_ data: Data) -> Data {
        var output = Data()
        var pending: UInt8?
        for byte in data {
            let digit: UInt8
            switch byte {
            case 0x30...0x39: digit = byte - 0x30
            case 0x41...0x46: digit = byte - 0x41 + 10
            case 0x61...0x66: digit = byte - 0x61 + 10
            case 0x3E:
                if let high = pending { output.append(high << 4) }
                return output
            default: continue
            }
            if let high = pending {
                output.append(high << 4 | digit)
                pending = nil
            } else {
                pending = digit
            }
        }
        if let high = pending { output.append(high << 4) }
        return output
    }

    private static func ascii85(_ data: Data) -> Data {
        var output = Data()
        var group: [UInt32] = []
        func flush(_ digits: [UInt32], count: Int) {
            var padded = digits
            while padded.count < 5 { padded.append(84) }
            var value: UInt64 = 0
            for digit in padded { value = value * 85 + UInt64(digit) }
            let word = UInt32(truncatingIfNeeded: value)
            let bytes = [UInt8(word >> 24), UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)]
            output.append(contentsOf: bytes.prefix(count))
        }
        for byte in data {
            if byte == 0x7E { break } // ~>
            if byte == 0x7A, group.isEmpty { // z
                output.append(contentsOf: [0, 0, 0, 0])
                continue
            }
            guard byte >= 0x21, byte <= 0x75 else { continue }
            group.append(UInt32(byte - 0x21))
            if group.count == 5 {
                flush(group, count: 4)
                group.removeAll(keepingCapacity: true)
            }
        }
        if group.count > 1 { flush(group, count: group.count - 1) }
        return output
    }

    private static func runLength(_ data: Data) -> Data {
        var output = Data()
        let input = [UInt8](data)
        var position = 0
        while position < input.count {
            let length = Int(input[position])
            position += 1
            if length == 128 { break }
            if length < 128 {
                let end = min(position + length + 1, input.count)
                output.append(contentsOf: input[position..<end])
                position = end
            } else if position < input.count {
                output.append(contentsOf: repeatElement(input[position], count: 257 - length))
                position += 1
            }
        }
        return output
    }

    private static func lzw(_ data: Data, earlyChange: Bool) -> Data {
        let input = [UInt8](data)
        var output = [UInt8]()
        // Each entry is its last byte plus a link to the entry holding the bytes before it.
        var prefixes = [Int](repeating: -1, count: 4096)
        var suffixes = [UInt8](repeating: 0, count: 4096)
        for code in 0..<256 { suffixes[code] = UInt8(code) }
        var nextCode = 258
        var codeLength = 9
        var previous = -1
        var bitBuffer = 0
        var bitCount = 0
        var position = 0
        var scratch = [UInt8]()

        func expand(_ code: Int, into bytes: inout [UInt8]) {
            bytes.removeAll(keepingCapacity: true)
            var current = code
            while current >= 0, bytes.count < 4096 {
                bytes.append(suffixes[current])
                current = prefixes[current]
            }
            bytes.reverse()
        }

        while true {
            while bitCount < codeLength, position < input.count {
                bitBuffer = bitBuffer << 8 | Int(input[position])
                bitCount += 8
                position += 1
            }
            guard bitCount >= codeLength else { break }
            let code = bitBuffer >> (bitCount - codeLength) & ((1 << codeLength) - 1)
            bitCount -= codeLength

            if code == 257 { break }
            if code == 256 {
                nextCode = 258
                codeLength = 9
                previous = -1
                continue
            }
            if previous < 0 {
                guard code < 256 else { break }
                output.append(UInt8(code))
            } else if code < nextCode {
                expand(code, into: &scratch)
                output.append(contentsOf: scratch)
                if nextCode < 4096 {
                    prefixes[nextCode] = previous
                    suffixes[nextCode] = scratch[0]
                    nextCode += 1
                }
            } else {
                // The code being defined right now: the previous entry plus its own first byte.
                expand(previous, into: &scratch)
                guard let first = scratch.first else { break }
                output.append(contentsOf: scratch)
                output.append(first)
                if nextCode < 4096 {
                    prefixes[nextCode] = previous
                    suffixes[nextCode] = first
                    nextCode += 1
                }
            }
            previous = code
            let threshold = nextCode + (earlyChange ? 1 : 0)
            if threshold > 2047 { codeLength = 12 } else if threshold > 1023 { codeLength = 11 } else if threshold > 511 { codeLength = 10 } else { codeLength = 9 }
        }
        return Data(output)
    }
}
