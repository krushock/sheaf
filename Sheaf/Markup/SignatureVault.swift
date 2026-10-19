import CryptoKit
import Foundation
import Security

/// Encrypts saved signatures. A copy of someone's signature is worth stealing, so the
/// file on disk is sealed with AES-GCM, and the key lives in the person's login Keychain,
/// where other apps cannot read it without asking.
nonisolated enum SignatureVault {
    enum Failure: LocalizedError {
        case keychain(OSStatus)
        case notASignatureFile

        var errorDescription: String? {
            switch self {
            case .keychain(let status): (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            case .notASignatureFile: "Not a file of Sheaf signatures"
            }
        }
    }

    private static let service = "com.valeryburtsev.Sheaf"
    /// What every sealed file starts with, so an older or foreign file is told apart.
    private static let magic = Data("SHEAFSIG1".utf8)

    /// The key from the Keychain. `nil` when there is none yet and `create` is false.
    static func key(account: String, create: Bool) throws -> SymmetricKey? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw Failure.keychain(status) }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        query[kSecReturnData] = nil
        query[kSecMatchLimit] = nil
        query[kSecValueData] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrLabel] = "Sheaf signatures"
        query[kSecAttrDescription] = "Key for the signatures saved in Sheaf"
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
        return key
    }

    static func deleteKey(account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }

    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw Failure.notASignatureFile }
        return magic + combined
    }

    static func open(_ file: Data, with key: SymmetricKey) throws -> Data {
        guard file.starts(with: magic) else { throw Failure.notASignatureFile }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: file.dropFirst(magic.count)), using: key)
    }
}
