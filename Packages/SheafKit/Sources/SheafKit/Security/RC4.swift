import Foundation

/// The RC4 stream cipher, which older PDF encryption uses. Encrypting and decrypting are
/// the same operation.
enum RC4 {
    static func apply(_ data: Data, key: Data) -> Data {
        guard !key.isEmpty else { return data }
        var state = [UInt8](0...255)
        let keyBytes = [UInt8](key)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(state[i]) + Int(keyBytes[i % keyBytes.count])) & 0xFF
            state.swapAt(i, j)
        }
        var output = [UInt8](data)
        var i = 0
        j = 0
        for index in output.indices {
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            output[index] ^= state[(Int(state[i]) + Int(state[j])) & 0xFF]
        }
        return Data(output)
    }
}
