import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Приватный SSH-ключ, готовый подписывать: для SSH-агента Ward.
public struct SSHSigningKey {
    enum Backing {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        case rsa(SecKey)
    }

    public let type: String
    public let publicBlob: Data
    let backing: Backing

    public enum Failure: LocalizedError, Equatable {
        case unsupported(String)
        case needsPassphrase
        case wrongPassphrase
        case corrupted

        public var errorDescription: String? {
            switch self {
            case .unsupported(let what): return "Не поддерживается: \(what)"
            case .needsPassphrase: return "Ключ зашифрован — нужна его фраза-пароль"
            case .wrongPassphrase: return "Фраза-пароль ключа не подходит"
            case .corrupted: return "Ключ повреждён"
            }
        }
    }

    public static let supportedTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    // SSH_AGENT_RSA_SHA2_256 / SSH_AGENT_RSA_SHA2_512 из draft-miller-ssh-agent.
    public static let rsaSHA256: UInt32 = 2
    public static let rsaSHA512: UInt32 = 4

    /// Подпись в формате SSH: `string алгоритм, string подпись`.
    public func sign(_ data: Data, flags: UInt32 = 0) throws -> Data {
        var w = SSHWriter()
        switch backing {
        case .ed25519(let key):
            w.string("ssh-ed25519")
            w.string(try key.signature(for: data))
        case .p256(let key):
            w.string(type)
            w.string(Self.ecdsaSignature(try key.signature(for: data).rawRepresentation))
        case .p384(let key):
            w.string(type)
            w.string(Self.ecdsaSignature(try key.signature(for: data).rawRepresentation))
        case .p521(let key):
            w.string(type)
            w.string(Self.ecdsaSignature(try key.signature(for: data).rawRepresentation))
        case .rsa(let key):
            let (name, algorithm): (String, SecKeyAlgorithm)
            if flags & Self.rsaSHA512 != 0 {
                (name, algorithm) = ("rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)
            } else if flags & Self.rsaSHA256 != 0 {
                (name, algorithm) = ("rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256)
            } else {
                (name, algorithm) = ("ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1)
            }
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, algorithm, data as CFData, &error) as Data? else {
                throw error?.takeRetainedValue() ?? Failure.corrupted
            }
            w.string(name)
            w.string(signature)
        }
        return w.data
    }

    /// r‖s фиксированной длины → `mpint r, mpint s`.
    private static func ecdsaSignature(_ raw: Data) -> Data {
        let half = raw.count / 2
        var w = SSHWriter()
        w.mpint(raw.prefix(half))
        w.mpint(raw.suffix(half))
        return w.data
    }
}

// MARK: - Загрузка

public enum SSHPrivateKeyLoader {
    public static func load(_ text: String, passphrase: String) throws -> SSHSigningKey {
        let blocks = PEM.blocks(in: text)
        if let block = blocks.first(where: { $0.label == "OPENSSH PRIVATE KEY" }) {
            return try openSSH(Array(block.der), passphrase: passphrase)
        }
        if let block = blocks.first(where: { $0.label == "RSA PRIVATE KEY" || $0.label == "EC PRIVATE KEY" || $0.label == "PRIVATE KEY" }) {
            if block.headers["Proc-Type"]?.contains("ENCRYPTED") == true {
                throw SSHSigningKey.Failure.unsupported("зашифрованный PEM — пересохраните ключ: ssh-keygen -p -f <файл>")
            }
            switch block.label {
            case "RSA PRIVATE KEY": return try pkcs1(Array(block.der))
            case "EC PRIVATE KEY": return try sec1(Array(block.der))
            default: return try pkcs8(Array(block.der))
            }
        }
        if blocks.contains(where: { $0.label == "ENCRYPTED PRIVATE KEY" }) {
            throw SSHSigningKey.Failure.unsupported("зашифрованный PKCS#8 — пересохраните ключ: ssh-keygen -p -f <файл>")
        }
        if text.hasPrefix("PuTTY-User-Key-File") {
            throw SSHSigningKey.Failure.unsupported("ключ PuTTY — сохраните его в формате OpenSSH (PuTTYgen → Export OpenSSH key)")
        }
        throw SSHSigningKey.Failure.unsupported("формат ключа не распознан")
    }

    /// openssh-key-v1: заголовок открыт, приватная часть — возможно, зашифрована (bcrypt_pbkdf + AES).
    static func openSSH(_ data: [UInt8], passphrase: String) throws -> SSHSigningKey {
        let magic = Array("openssh-key-v1\0".utf8)
        guard data.starts(with: magic) else { throw SSHSigningKey.Failure.corrupted }
        var r = SSHReader(data.dropFirst(magic.count))
        guard let cipherData = r.string(), let kdfData = r.string(), let kdfOptions = r.string(),
              let count = r.uint32(), count == 1, let publicBlob = r.string(), let encrypted = r.string() else {
            throw SSHSigningKey.Failure.corrupted
        }
        let cipher = String(decoding: cipherData, as: UTF8.self)
        let kdf = String(decoding: kdfData, as: UTF8.self)
        var section = Array(encrypted)
        if cipher != "none" {
            guard kdf == "bcrypt" else { throw SSHSigningKey.Failure.unsupported("KDF \(kdf)") }
            guard !passphrase.isEmpty else { throw SSHSigningKey.Failure.needsPassphrase }
            var options = SSHReader(kdfOptions)
            guard let salt = options.string(), let rounds = options.uint32(), rounds >= 1, rounds <= 1 << 16 else {
                throw SSHSigningKey.Failure.corrupted
            }
            let spec = try CipherSpec(cipher)
            guard let derived = BcryptPBKDF.derive(password: Array(passphrase.utf8), salt: Array(salt),
                                                    length: spec.keyLength + spec.ivLength, rounds: Int(rounds)) else {
                try Task.checkCancellation()
                throw SSHSigningKey.Failure.corrupted
            }
            let key = Array(derived.prefix(spec.keyLength)), iv = Array(derived.suffix(spec.ivLength))
            // У AES-GCM тег (16 байт) лежит сразу после зашифрованной строки.
            let tag = spec.isGCM ? Array(r.rest.prefix(16)) : []
            section = try spec.decrypt(section, key: key, iv: iv, tag: tag)
        }
        var p = SSHReader(section)
        // Два одинаковых случайных числа в начале: не совпали — фраза-пароль неверна.
        guard let check1 = p.uint32(), let check2 = p.uint32() else { throw SSHSigningKey.Failure.corrupted }
        guard check1 == check2 else {
            throw cipher == "none" ? SSHSigningKey.Failure.corrupted : SSHSigningKey.Failure.wrongPassphrase
        }
        guard let typeData = p.string() else { throw SSHSigningKey.Failure.corrupted }
        let type = String(decoding: typeData, as: UTF8.self)
        let signing: SSHSigningKey
        switch type {
        case "ssh-ed25519":
            guard let pk = p.string(), let sk = p.string(), sk.count == 64 else { throw SSHSigningKey.Failure.corrupted }
            signing = try ed25519(seed: sk.prefix(32), expectedPublic: pk)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard p.string() != nil, let q = p.string(), let d = p.string() else { throw SSHSigningKey.Failure.corrupted }
            let size = type.hasSuffix("256") ? 32 : type.hasSuffix("384") ? 48 : 66
            signing = try ecdsa(d: Array(d), size: size, expectedPoint: q)
        case "ssh-rsa":
            guard let n = p.string(), let e = p.string(), let d = p.string(), let iqmp = p.string(),
                  let pp = p.string(), let q = p.string() else { throw SSHSigningKey.Failure.corrupted }
            signing = try rsa(n: Array(n), e: Array(e), d: Array(d), p: Array(pp), q: Array(q), iqmp: Array(iqmp))
        default:
            throw SSHSigningKey.Failure.unsupported("тип ключа \(type)")
        }
        guard signing.publicBlob == publicBlob else { throw SSHSigningKey.Failure.corrupted }
        return signing
    }

    // MARK: Типы ключей

    static func ed25519<D: DataProtocol>(seed: D, expectedPublic: Data? = nil) throws -> SSHSigningKey {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)) else {
            throw SSHSigningKey.Failure.corrupted
        }
        let pk = key.publicKey.rawRepresentation
        if let expectedPublic, expectedPublic != pk { throw SSHSigningKey.Failure.corrupted }
        var w = SSHWriter()
        w.string("ssh-ed25519")
        w.string(pk)
        return SSHSigningKey(type: "ssh-ed25519", publicBlob: w.data, backing: .ed25519(key))
    }

    /// `size` — длина секрета кривой: 32 — P-256, 48 — P-384, 66 — P-521. Секрет может прийти как mpint
    /// (с нулём впереди) — лишние нули срезаются, недостающие добавляются.
    static func ecdsa(d rawD: [UInt8], size: Int, expectedPoint: Data? = nil) throws -> SSHSigningKey {
        let d = Array(rawD.drop { $0 == 0 })
        guard [32, 48, 66].contains(size), !d.isEmpty, d.count <= size else { throw SSHSigningKey.Failure.corrupted }
        let padded = Data(repeating: 0, count: size - d.count) + d
        let backing: SSHSigningKey.Backing, point: Data, curve: String
        do {
            switch size {
            case 32:
                let key = try P256.Signing.PrivateKey(rawRepresentation: padded)
                (backing, point, curve) = (.p256(key), key.publicKey.x963Representation, "nistp256")
            case 48:
                let key = try P384.Signing.PrivateKey(rawRepresentation: padded)
                (backing, point, curve) = (.p384(key), key.publicKey.x963Representation, "nistp384")
            default:
                let key = try P521.Signing.PrivateKey(rawRepresentation: padded)
                (backing, point, curve) = (.p521(key), key.publicKey.x963Representation, "nistp521")
            }
        } catch {
            throw SSHSigningKey.Failure.corrupted
        }
        if let expectedPoint, expectedPoint != point { throw SSHSigningKey.Failure.corrupted }
        let type = "ecdsa-sha2-" + curve
        var w = SSHWriter()
        w.string(type)
        w.string(curve)
        w.string(point)
        return SSHSigningKey(type: type, publicBlob: w.data, backing: backing)
    }

    /// OpenSSH хранит n, e, d, p, q и q⁻¹ mod p; для PKCS#1 не хватает d mod (p−1) и d mod (q−1) — досчитываем.
    static func rsa(n: [UInt8], e: [UInt8], d: [UInt8], p: [UInt8], q: [UInt8], iqmp: [UInt8]) throws -> SSHSigningKey {
        let bigD = BigUInt(bytes: d)
        let dp = bigD.mod(BigUInt(bytes: p).subtractingOne()).bytes
        let dq = bigD.mod(BigUInt(bytes: q).subtractingOne()).bytes
        let der = DERWriter.sequence([[0], n, e, d, p, q, dp, dq, iqmp].map(DERWriter.integer).joined())
        return try rsa(pkcs1: der, n: n, e: e)
    }

    static func rsa(pkcs1 der: [UInt8], n: [UInt8], e: [UInt8]) throws -> SSHSigningKey {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else {
            throw SSHSigningKey.Failure.corrupted
        }
        var w = SSHWriter()
        w.string("ssh-rsa")
        w.mpint(e)
        w.mpint(n)
        return SSHSigningKey(type: "ssh-rsa", publicBlob: w.data, backing: .rsa(key))
    }

    // MARK: PEM

    /// RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }
    static func pkcs1(_ der: [UInt8]) throws -> SSHSigningKey {
        guard let seq = DER.parse(der).first, seq.tag == 0x30 else { throw SSHSigningKey.Failure.corrupted }
        let ints = DER.parse(seq.content).filter { $0.tag == 0x02 }
        guard ints.count >= 9 else { throw SSHSigningKey.Failure.corrupted }
        return try rsa(pkcs1: der, n: ints[1].content, e: ints[2].content)
    }

    /// ECPrivateKey ::= SEQUENCE { version, privateKey OCTET STRING, [0] параметры, [1] публичный ключ }
    static func sec1(_ der: [UInt8]) throws -> SSHSigningKey {
        guard let seq = DER.parse(der).first, seq.tag == 0x30,
              let d = DER.parse(seq.content).first(where: { $0.tag == 0x04 }) else { throw SSHSigningKey.Failure.corrupted }
        // RFC 5915: секрет фиксированной длины для кривой — по ней кривую и узнаём.
        let n = d.content.count
        return try ecdsa(d: d.content, size: [32, 48, 66].contains(n) ? n : n <= 32 ? 32 : n <= 48 ? 48 : 66)
    }

    private static let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let ecOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let ed25519OID: [UInt8] = [0x2B, 0x65, 0x70]

    /// PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, privateKey OCTET STRING }
    static func pkcs8(_ der: [UInt8]) throws -> SSHSigningKey {
        guard let seq = DER.parse(der).first, seq.tag == 0x30 else { throw SSHSigningKey.Failure.corrupted }
        let items = DER.parse(seq.content)
        guard items.count >= 3, items[1].tag == 0x30, items[2].tag == 0x04,
              let oid = DER.parse(items[1].content).first(where: { $0.tag == 0x06 })?.content else {
            throw SSHSigningKey.Failure.corrupted
        }
        switch oid {
        case rsaOID: return try pkcs1(items[2].content)
        case ecOID: return try sec1(items[2].content)
        case ed25519OID:
            guard let seed = DER.parse(items[2].content).first, seed.tag == 0x04, seed.content.count == 32 else {
                throw SSHSigningKey.Failure.corrupted
            }
            return try ed25519(seed: seed.content)
        default:
            throw SSHSigningKey.Failure.unsupported("алгоритм ключа PKCS#8")
        }
    }
}

// MARK: - Шифры приватной части OpenSSH

struct CipherSpec {
    let keyLength: Int
    let ivLength: Int
    let mode: CCMode?
    let isGCM: Bool

    init(_ name: String) throws {
        switch name {
        case "aes128-ctr": (keyLength, ivLength, mode, isGCM) = (16, 16, CCMode(kCCModeCTR), false)
        case "aes192-ctr": (keyLength, ivLength, mode, isGCM) = (24, 16, CCMode(kCCModeCTR), false)
        case "aes256-ctr": (keyLength, ivLength, mode, isGCM) = (32, 16, CCMode(kCCModeCTR), false)
        case "aes128-cbc": (keyLength, ivLength, mode, isGCM) = (16, 16, CCMode(kCCModeCBC), false)
        case "aes192-cbc": (keyLength, ivLength, mode, isGCM) = (24, 16, CCMode(kCCModeCBC), false)
        case "aes256-cbc": (keyLength, ivLength, mode, isGCM) = (32, 16, CCMode(kCCModeCBC), false)
        case "aes128-gcm@openssh.com": (keyLength, ivLength, mode, isGCM) = (16, 12, nil, true)
        case "aes256-gcm@openssh.com": (keyLength, ivLength, mode, isGCM) = (32, 12, nil, true)
        default:
            throw SSHSigningKey.Failure.unsupported("шифр \(name) — пересохраните ключ: ssh-keygen -p -Z aes256-ctr -f <файл>")
        }
    }

    func decrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8], tag: [UInt8]) throws -> [UInt8] {
        if isGCM {
            guard tag.count == 16, let nonce = try? AES.GCM.Nonce(data: iv),
                  let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: data, tag: tag) else {
                throw SSHSigningKey.Failure.corrupted
            }
            guard let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else {
                throw SSHSigningKey.Failure.wrongPassphrase
            }
            return Array(plain)
        }
        guard let mode, data.count % 16 == 0 else { throw SSHSigningKey.Failure.corrupted }
        var cryptor: CCCryptorRef?
        let options = mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0
        guard CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                      iv, key, key.count, nil, 0, 0, options, &cryptor) == kCCSuccess, let cryptor else {
            throw SSHSigningKey.Failure.corrupted
        }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved) == kCCSuccess, moved == data.count else {
            throw SSHSigningKey.Failure.corrupted
        }
        return out
    }
}

// MARK: - Кодирование

struct SSHWriter {
    private(set) var data = Data()

    mutating func byte(_ value: UInt8) { data.append(value) }

    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func string<D: DataProtocol>(_ bytes: D) {
        uint32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func string(_ text: String) { string(Data(text.utf8)) }

    /// mpint (RFC 4251): без лишних нулей впереди, с нулём, если старший бит установлен.
    mutating func mpint<D: DataProtocol>(_ bytes: D) {
        var value = Array(bytes.drop { $0 == 0 })
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        string(value)
    }
}

enum DERWriter {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var value = n
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func integer(_ raw: [UInt8]) -> [UInt8] {
        var value = Array(raw.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return [0x02] + length(value.count) + value
    }

    static func sequence<S: Sequence>(_ content: S) -> [UInt8] where S.Element == UInt8 {
        let bytes = Array(content)
        return [0x30] + length(bytes.count) + bytes
    }
}

/// Длинное неотрицательное целое — ровно столько, сколько нужно для d mod (p−1) у RSA.
struct BigUInt: Comparable {
    /// Младшие 32 бита первыми, без старших нулей.
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init<C: Collection>(bytes: C) where C.Element == UInt8 {
        var limbs: [UInt32] = []
        var current: UInt32 = 0, shift: UInt32 = 0
        for byte in bytes.reversed() {
            current |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { limbs.append(current) }
        self.init(limbs: limbs)
    }

    private mutating func normalize() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    /// Big-endian, без ведущих нулей; ноль — `[0]`.
    var bytes: [UInt8] {
        var out: [UInt8] = []
        for limb in limbs.reversed() {
            out += [UInt8(limb >> 24), UInt8(limb >> 16 & 0xff), UInt8(limb >> 8 & 0xff), UInt8(limb & 0xff)]
        }
        let trimmed = Array(out.drop { $0 == 0 })
        return trimmed.isEmpty ? [0] : trimmed
    }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool { limbs[i / 32] >> UInt32(i % 32) & 1 == 1 }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    /// self − other при self ≥ other.
    func subtracting(_ other: BigUInt) -> BigUInt {
        var result = limbs
        var borrow: UInt64 = 0
        for i in 0..<result.count {
            let rhs = UInt64(i < other.limbs.count ? other.limbs[i] : 0) + borrow
            let lhs = UInt64(result[i])
            if lhs >= rhs {
                result[i] = UInt32(lhs - rhs)
                borrow = 0
            } else {
                result[i] = UInt32(lhs + (1 << 32) - rhs)
                borrow = 1
            }
        }
        return BigUInt(limbs: result)
    }

    func subtractingOne() -> BigUInt { subtracting(BigUInt(limbs: [1])) }

    /// Остаток сдвигом и вычитанием — медленно, но хватает для чисел в 2–8 тысяч бит.
    func mod(_ m: BigUInt) -> BigUInt {
        guard !m.isZero else { return self }
        var r = BigUInt(limbs: [])
        for i in stride(from: bitWidth - 1, through: 0, by: -1) {
            r = r.shiftedLeftOne(orBit: bit(i))
            if !(r < m) { r = r.subtracting(m) }
        }
        return r
    }

    private func shiftedLeftOne(orBit: Bool) -> BigUInt {
        var result: [UInt32] = []
        var carry: UInt32 = orBit ? 1 : 0
        for limb in limbs {
            result.append(limb << 1 | carry)
            carry = limb >> 31
        }
        if carry != 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }
}
