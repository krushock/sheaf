import CommonCrypto
import CryptoKit
import Foundation

/// Hashes, AES and random bytes from the system. RC4 is in `Security/RC4.swift`.
enum Hash {
    static func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha384(_ data: Data) -> Data { Data(SHA384.hash(data: data)) }
    static func sha512(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }
}

enum AES {
    static let blockSize = kCCBlockSizeAES128

    /// CBC without padding. The input must be a whole number of blocks.
    static func cbc(_ data: Data, key: Data, iv: Data, encrypt: Bool) -> Data? {
        crypt(data, key: key, iv: iv, operation: encrypt ? kCCEncrypt : kCCDecrypt, options: 0)
    }

    /// One or more blocks in ECB mode, without padding.
    static func ecb(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        crypt(data, key: key, iv: nil, operation: encrypt ? kCCEncrypt : kCCDecrypt, options: kCCOptionECBMode)
    }

    private static func crypt(_ data: Data, key: Data, iv: Data?, operation: Int, options: Int) -> Data? {
        guard data.count % blockSize == 0, [16, 24, 32].contains(key.count) else { return nil }
        if data.isEmpty { return Data() }
        var output = [UInt8](repeating: 0, count: data.count + blockSize)
        var written = 0
        let status = data.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                (iv ?? Data(count: blockSize)).withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(options),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                        input.baseAddress, data.count, &output, output.count, &written
                    )
                }
            }
        }
        return status == kCCSuccess ? Data(output.prefix(written)) : nil
    }
}

enum RandomBytes {
    static func make(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
