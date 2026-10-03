import Foundation

/// What an encrypted document lets someone do who opened it with the user password.
public struct Permissions: OptionSet, Sendable, Hashable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let print = Permissions(rawValue: 1 << 2)
    public static let modify = Permissions(rawValue: 1 << 3)
    public static let copy = Permissions(rawValue: 1 << 4)
    public static let annotate = Permissions(rawValue: 1 << 5)
    public static let fillForms = Permissions(rawValue: 1 << 8)
    public static let extractForAccessibility = Permissions(rawValue: 1 << 9)
    public static let assemble = Permissions(rawValue: 1 << 10)
    public static let printHighQuality = Permissions(rawValue: 1 << 11)

    public static let all: Permissions = [
        .print, .modify, .copy, .annotate, .fillForms, .extractForAccessibility, .assemble, .printHighQuality,
    ]

    /// The value for `/P`: the chosen bits plus the reserved bits the format requires.
    var fieldValue: Int32 {
        Int32(bitPattern: 0xFFFF_F0C0) | (rawValue & Permissions.all.rawValue)
    }
}

/// The cipher a document is, or will be, encrypted with.
public enum EncryptionAlgorithm: Sendable, Equatable {
    case rc4(bits: Int)
    case aes128
    case aes256
}

/// The standard password-based security handler: checks a password, then decrypts and
/// encrypts strings and streams.
struct SecurityHandler: Sendable {
    enum Method: Sendable {
        case none, rc4, aesV2, aesV3
    }

    let revision: Int
    let fileKey: Data
    let stringMethod: Method
    let streamMethod: Method
    let encryptMetadata: Bool
    let permissions: Permissions
    /// True when the password given was the owner password, which lifts the permissions.
    let isOwner: Bool

    var algorithm: EncryptionAlgorithm {
        switch streamMethod {
        case .aesV3: .aes256
        case .aesV2: .aes128
        case .rc4, .none: .rc4(bits: fileKey.count * 8)
        }
    }

    // MARK: Opening

    /// - Parameters:
    ///   - dictionary: The `/Encrypt` dictionary with nothing left as a reference.
    ///   - documentID: The first string of the trailer's `/ID`.
    init(dictionary: PDFDictionary, documentID: Data, password: String) throws {
        guard dictionary["Filter"]?.nameValue == "Standard" else {
            throw SheafError.unsupported("encryption handler \(dictionary["Filter"]?.nameValue?.rawValue ?? "unknown")")
        }
        let version = dictionary["V"]?.intValue ?? 0
        let revision = dictionary["R"]?.intValue ?? 2
        guard let owner = dictionary["O"]?.stringValue, let user = dictionary["U"]?.stringValue else {
            throw SheafError.malformed("encryption dictionary has no password entries")
        }
        let field = Int32(truncatingIfNeeded: dictionary["P"]?.intValue ?? 0)
        self.revision = revision
        permissions = Permissions(rawValue: field & Permissions.all.rawValue)
        encryptMetadata = dictionary["EncryptMetadata"]?.boolValue ?? true

        func method(_ key: PDFName) -> Method {
            guard let name = dictionary[key]?.nameValue, name != "Identity" else { return .none }
            switch dictionary["CF"]?.dictionaryValue?[name]?.dictionaryValue?["CFM"]?.nameValue {
            case "AESV2": return .aesV2
            case "AESV3": return .aesV3
            case "None": return .none
            default: return .rc4
            }
        }
        switch version {
        case 1, 2, 3:
            stringMethod = .rc4
            streamMethod = .rc4
        case 4, 5:
            stringMethod = method("StrF")
            streamMethod = method("StmF")
        default:
            throw SheafError.unsupported("encryption version \(version)")
        }

        let encryptMetadata = encryptMetadata
        if revision >= 5 {
            guard owner.count >= 48, user.count >= 48,
                  let ownerKey = dictionary["OE"]?.stringValue, let userKey = dictionary["UE"]?.stringValue
            else { throw SheafError.malformed("encryption dictionary is incomplete") }
            (fileKey, isOwner) = try Self.authenticateModern(
                password: password, owner: Data(owner), user: Data(user.prefix(48)),
                ownerKey: ownerKey, userKey: userKey, revision: revision
            )
        } else {
            let declaredBits = dictionary["Length"]?.intValue ?? 40
            (fileKey, isOwner) = try Self.authenticateLegacy(
                password: password, owner: owner, user: user, field: field, documentID: documentID, revision: revision,
                keyLength: version == 1 ? 5 : version == 4 ? 16 : min(max(declaredBits / 8, 5), 16),
                encryptMetadata: encryptMetadata
            )
        }
    }

    private static func authenticateModern(
        password: String, owner: Data, user: Data, ownerKey: Data, userKey: Data, revision: Int
    ) throws -> (Data, Bool) {
        let bytes = Data(password.utf8.prefix(127))
        func hash(_ salt: Data, _ userEntry: Data) -> Data {
            revision == 5 ? Hash.sha256(bytes + salt + userEntry) : hardenedHash(bytes, salt, userEntry)
        }
        func unwrap(_ wrapped: Data, with key: Data) throws -> Data {
            guard let fileKey = AES.cbc(Data(wrapped.prefix(32)), key: key, iv: Data(count: 16), encrypt: false) else {
                throw SheafError.malformed("encryption key could not be unwrapped")
            }
            return fileKey
        }
        if hash(owner[32..<40], user) == owner[0..<32] {
            return (try unwrap(ownerKey, with: hash(owner[40..<48], user)), true)
        }
        if hash(user[32..<40], Data()) == user[0..<32] {
            return (try unwrap(userKey, with: hash(user[40..<48], Data())), false)
        }
        throw SheafError.incorrectPassword
    }

    private static func authenticateLegacy(
        password: String, owner: Data, user: Data, field: Int32, documentID: Data,
        revision: Int, keyLength: Int, encryptMetadata: Bool
    ) throws -> (Data, Bool) {
        func key(forUserPassword padded: Data) -> Data {
            fileKey(
                paddedUserPassword: padded, owner: owner, field: field, documentID: documentID,
                revision: revision, keyLength: keyLength, encryptMetadata: encryptMetadata
            )
        }
        func unlocks(_ key: Data) -> Bool {
            let expected = userEntry(key: key, documentID: documentID, revision: revision)
            return revision == 2 ? expected == user : expected.prefix(16) == user.prefix(16)
        }
        let padded = padded(legacyBytes(password))
        let asUser = key(forUserPassword: padded)
        if unlocks(asUser) { return (asUser, false) }
        // Writers disagree on one detail of the owner key when it is shorter than 16 bytes,
        // so both readings are tried. Core Graphics uses the second for 40-bit keys.
        for hashesWholeDigest in [true, false] {
            let recovered = userPassword(
                fromOwnerPassword: padded, owner: owner, revision: revision, keyLength: keyLength, hashesWholeDigest: hashesWholeDigest
            )
            let asOwner = key(forUserPassword: recovered)
            if unlocks(asOwner) { return (asOwner, true) }
        }
        throw SheafError.incorrectPassword
    }

    private init(
        revision: Int, fileKey: Data, method: Method, permissions: Permissions, isOwner: Bool
    ) {
        self.revision = revision
        self.fileKey = fileKey
        stringMethod = method
        streamMethod = method
        encryptMetadata = true
        self.permissions = permissions
        self.isOwner = isOwner
    }

    // MARK: Creating

    /// Builds the `/Encrypt` dictionary and handler for protecting a document.
    ///
    /// - Parameters:
    ///   - ownerPassword: Defaults to the user password, as other apps do.
    ///   - documentID: The first string of the `/ID` the file will be written with.
    static func make(
        userPassword: String, ownerPassword: String?, permissions: Permissions,
        algorithm: EncryptionAlgorithm, documentID: Data
    ) throws -> (dictionary: PDFDictionary, handler: SecurityHandler) {
        let ownerPassword = ownerPassword.flatMap { $0.isEmpty ? nil : $0 } ?? userPassword
        let field = permissions.fieldValue

        switch algorithm {
        case .aes256:
            let fileKey = RandomBytes.make(32)
            let userBytes = Data(userPassword.utf8.prefix(127)), ownerBytes = Data(ownerPassword.utf8.prefix(127))
            let zeroIV = Data(count: 16)

            let userSalts = RandomBytes.make(16)
            let user = hardenedHash(userBytes, userSalts[0..<8], Data()) + userSalts
            let userWrapping = hardenedHash(userBytes, userSalts[8..<16], Data())
            let ownerSalts = RandomBytes.make(16)
            let owner = hardenedHash(ownerBytes, ownerSalts[0..<8], user) + ownerSalts
            let ownerWrapping = hardenedHash(ownerBytes, ownerSalts[8..<16], user)

            var check = Data()
            withUnsafeBytes(of: field.littleEndian) { check.append(contentsOf: $0) }
            check.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0x54, 0x61, 0x64, 0x62]) // metadata is encrypted, then "adb"
            check.append(RandomBytes.make(4))

            guard let userKey = AES.cbc(fileKey, key: userWrapping, iv: zeroIV, encrypt: true),
                  let ownerKey = AES.cbc(fileKey, key: ownerWrapping, iv: zeroIV, encrypt: true),
                  let permissionCheck = AES.ecb(check, key: fileKey, encrypt: true)
            else { throw SheafError.generationFailed }

            let dictionary: PDFDictionary = [
                "Filter": .name("Standard"), "V": 5, "R": 6, "Length": 256, "P": .integer(Int(field)),
                "O": .string(owner), "U": .string(user), "OE": .string(ownerKey), "UE": .string(userKey),
                "Perms": .string(permissionCheck),
                "CF": ["StdCF": ["AuthEvent": .name("DocOpen"), "CFM": .name("AESV3"), "Length": 32]],
                "StmF": .name("StdCF"), "StrF": .name("StdCF"),
            ]
            return (dictionary, SecurityHandler(revision: 6, fileKey: fileKey, method: .aesV3, permissions: permissions, isOwner: true))

        case .aes128, .rc4:
            let revision: Int, keyLength: Int, method: Method
            switch algorithm {
            case .rc4(let bits):
                keyLength = min(max(bits / 8, 5), 16)
                revision = keyLength == 5 ? 2 : 3
                method = .rc4
            default:
                keyLength = 16
                revision = 4
                method = .aesV2
            }
            let paddedUser = padded(legacyBytes(userPassword))
            // The owner entry is the user password, encrypted under a key made from the owner password.
            var digest = Hash.md5(padded(legacyBytes(ownerPassword)))
            if revision >= 3 { for _ in 0..<50 { digest = Hash.md5(digest) } }
            let ownerKey = digest.prefix(keyLength)
            var owner = RC4.apply(paddedUser, key: ownerKey)
            if revision >= 3 {
                for round in 1...19 { owner = RC4.apply(owner, key: Data(ownerKey.map { $0 ^ UInt8(round) })) }
            }
            let fileKey = fileKey(
                paddedUserPassword: paddedUser, owner: owner, field: field, documentID: documentID,
                revision: revision, keyLength: keyLength, encryptMetadata: true
            )
            let user = userEntry(key: fileKey, documentID: documentID, revision: revision)

            var dictionary: PDFDictionary = [
                "Filter": .name("Standard"), "R": .integer(revision), "Length": .integer(keyLength * 8),
                "P": .integer(Int(field)), "O": .string(owner), "U": .string(user),
            ]
            if method == .aesV2 {
                dictionary["V"] = 4
                dictionary["CF"] = ["StdCF": ["AuthEvent": .name("DocOpen"), "CFM": .name("AESV2"), "Length": 16]]
                dictionary["StmF"] = .name("StdCF")
                dictionary["StrF"] = .name("StdCF")
            } else {
                dictionary["V"] = keyLength == 5 ? 1 : 2
            }
            return (dictionary, SecurityHandler(revision: revision, fileKey: fileKey, method: method, permissions: permissions, isOwner: true))
        }
    }

    // MARK: Per-object work

    func decrypt(string: Data, id: ObjectID) -> Data { apply(string, id: id, method: stringMethod, encrypt: false) }
    func decrypt(streamData: Data, id: ObjectID) -> Data { apply(streamData, id: id, method: streamMethod, encrypt: false) }
    func encrypt(string: Data, id: ObjectID) -> Data { apply(string, id: id, method: stringMethod, encrypt: true) }
    func encrypt(streamData: Data, id: ObjectID) -> Data { apply(streamData, id: id, method: streamMethod, encrypt: true) }

    private func apply(_ data: Data, id: ObjectID, method: Method, encrypt: Bool) -> Data {
        switch method {
        case .none: return data
        case .rc4: return RC4.apply(data, key: objectKey(id, forAES: false))
        case .aesV2: return aes(data, key: objectKey(id, forAES: true), encrypt: encrypt)
        case .aesV3: return aes(data, key: fileKey, encrypt: encrypt)
        }
    }

    private func objectKey(_ id: ObjectID, forAES: Bool) -> Data {
        var input = fileKey
        input.append(contentsOf: [
            UInt8(id.number & 0xFF), UInt8(id.number >> 8 & 0xFF), UInt8(id.number >> 16 & 0xFF),
            UInt8(id.generation & 0xFF), UInt8(id.generation >> 8 & 0xFF),
        ])
        if forAES { input.append(contentsOf: [0x73, 0x41, 0x6C, 0x54]) } // "sAlT"
        return Hash.md5(input).prefix(min(fileKey.count + 5, 16))
    }

    /// AES in CBC mode. The stored form is a random block followed by the padded ciphertext.
    private func aes(_ data: Data, key: Data, encrypt: Bool) -> Data {
        let block = AES.blockSize
        if encrypt {
            let iv = RandomBytes.make(block)
            let padding = block - data.count % block
            let padded = data + Data(repeating: UInt8(padding), count: padding)
            return iv + (AES.cbc(padded, key: key, iv: iv, encrypt: true) ?? Data())
        }
        guard data.count >= 2 * block else { return Data() }
        let iv = Data(data.prefix(block))
        var body = Data(data.dropFirst(block))
        body = Data(body.prefix(body.count - body.count % block))
        guard var plain = AES.cbc(body, key: key, iv: iv, encrypt: false) else { return Data() }
        if let padding = plain.last, padding >= 1, Int(padding) <= block, plain.count >= Int(padding) {
            plain.removeLast(Int(padding))
        }
        return plain
    }

    // MARK: Key derivation, revisions 2 to 4

    private static let padding = Data([
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ])

    private static func legacyBytes(_ password: String) -> Data {
        password.data(using: .isoLatin1) ?? Data(password.utf8)
    }

    private static func padded(_ password: Data) -> Data {
        Data((password + padding).prefix(32))
    }

    private static func fileKey(
        paddedUserPassword: Data, owner: Data, field: Int32, documentID: Data,
        revision: Int, keyLength: Int, encryptMetadata: Bool
    ) -> Data {
        var input = paddedUserPassword + owner.prefix(32)
        withUnsafeBytes(of: field.littleEndian) { input.append(contentsOf: $0) }
        input.append(documentID)
        if revision >= 4, !encryptMetadata { input.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) }
        var digest = Hash.md5(input)
        if revision >= 3 {
            for _ in 0..<50 { digest = Hash.md5(digest.prefix(keyLength)) }
        }
        return Data(digest.prefix(keyLength))
    }

    private static func userEntry(key: Data, documentID: Data, revision: Int) -> Data {
        if revision == 2 { return RC4.apply(padding, key: key) }
        var value = RC4.apply(Hash.md5(padding + documentID), key: key)
        for round in 1...19 { value = RC4.apply(value, key: Data(key.map { $0 ^ UInt8(round) })) }
        return value + Data(count: 16)
    }

    private static func userPassword(
        fromOwnerPassword padded: Data, owner: Data, revision: Int, keyLength: Int, hashesWholeDigest: Bool
    ) -> Data {
        var digest = Hash.md5(padded)
        if revision >= 3 {
            for _ in 0..<50 { digest = Hash.md5(hashesWholeDigest ? digest : Data(digest.prefix(keyLength))) }
        }
        let key = Data(digest.prefix(keyLength))
        var value = Data(owner.prefix(32))
        if revision == 2 { return RC4.apply(value, key: key) }
        for round in stride(from: 19, through: 0, by: -1) {
            value = RC4.apply(value, key: Data(key.map { $0 ^ UInt8(round) }))
        }
        return value
    }

    // MARK: Key derivation, revision 6

    /// The iterated hash that makes guessing passwords slow.
    private static func hardenedHash(_ password: Data, _ salt: Data, _ userEntry: Data) -> Data {
        var key = Hash.sha256(password + salt + userEntry)
        var round = 0
        while true {
            let block = password + key + userEntry
            var repeated = Data(capacity: block.count * 64)
            for _ in 0..<64 { repeated.append(block) }
            guard let encrypted = AES.cbc(repeated, key: Data(key.prefix(16)), iv: Data(key[key.startIndex + 16..<key.startIndex + 32]), encrypt: true)
            else { return Data(key.prefix(32)) }
            let remainder = encrypted.prefix(16).reduce(0) { ($0 + Int($1)) % 3 }
            key = remainder == 0 ? Hash.sha256(encrypted) : remainder == 1 ? Hash.sha384(encrypted) : Hash.sha512(encrypted)
            round += 1
            if round >= 64, Int(encrypted.last ?? 0) <= round - 32 { break }
        }
        return Data(key.prefix(32))
    }
}
