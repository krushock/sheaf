import Foundation
import zlib

/// Deflate compression, through the system zlib.
enum Flate {
    static let maximumOutput = 1 << 30

    /// Decompresses zlib data. Damaged streams give back whatever could be recovered.
    static func inflate(_ data: Data) throws -> Data {
        if let output = inflate(data, windowBits: 15), !output.isEmpty || data.count <= 8 { return output }
        // Some writers leave out the zlib header.
        if let output = inflate(data, windowBits: -15), !output.isEmpty { return output }
        throw SheafError.malformed("compressed data could not be expanded")
    }

    private static func inflate(_ data: Data, windowBits: Int32) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = max(64 * 1024, min(data.count * 4, 4 * 1024 * 1024))
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        return data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data? in
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else { return output }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = UInt32(input.count)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                output.append(chunk, count: chunkSize - Int(stream.avail_out))
                // A few bytes can claim to expand into gigabytes. Stop well before memory runs out.
                if output.count > maximumOutput { return output }
                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK where stream.avail_out == 0 || stream.avail_in > 0:
                    continue
                default:
                    // Truncated or damaged: keep what was produced.
                    return output.isEmpty && status != Z_OK && status != Z_BUF_ERROR ? nil : output
                }
            }
        }
    }

    static func deflate(_ data: Data) -> Data {
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return data }
        defer { deflateEnd(&stream) }

        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(data.count))))
        let written = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            return output.withUnsafeMutableBufferPointer { buffer -> Int in
                stream.next_out = buffer.baseAddress
                stream.avail_out = UInt32(buffer.count)
                _ = zlib.deflate(&stream, Z_FINISH)
                return buffer.count - Int(stream.avail_out)
            }
        }
        return Data(output.prefix(written))
    }
}
