import Foundation
import CryptoKit

/// Passkey (учётные данные WebAuthn) сайта: ключ P-256, которым Ward подписывает вход вместо пароля.
/// Живёт в записи этого сайта; закрытый ключ — только внутри зашифрованного хранилища.
public struct Passkey: Codable, Hashable, Sendable, Identifiable {
    /// Credential ID — по нему сайт узнаёт свой passkey.
    public var id: Data
    /// Relying party: домен, для которого создан passkey («github.com»).
    public var rpID: String
    public var userHandle: Data
    public var userName: String
    public var userDisplayName: String
    /// Закрытый ключ P-256 (32 байта).
    public var privateKey: Data
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: Data, rpID: String, userHandle: Data, userName: String, userDisplayName: String,
                privateKey: Data, createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.rpID = rpID
        self.userHandle = userHandle
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.privateKey = privateKey
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// Минимальный CBOR (RFC 8949) — ровно то, что нужно WebAuthn: целые, байты, строки, массивы и карты.
enum CBOR {
    indirect enum Value {
        case unsigned(UInt64)
        case negative(Int64)
        case bytes(Data)
        case text(String)
        case array([Value])
        /// Порядок ключей задаёт вызывающий: для COSE и attestationObject он — канонический (RFC 8949 §4.2.1).
        case map([(Value, Value)])

        static func int(_ value: Int64) -> Value { value >= 0 ? .unsigned(UInt64(value)) : .negative(value) }
    }

    static func encode(_ value: Value) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func head(_ major: UInt8, _ argument: UInt64, into out: inout Data) {
        let type = major << 5
        switch argument {
        case 0..<24: out.append(type | UInt8(argument))
        case 24...0xFF: out.append(contentsOf: [type | 24, UInt8(argument)])
        case 0x100...0xFFFF: out.append(type | 25); out.append(contentsOf: bigEndian(argument, 2))
        case 0x1_0000...0xFFFF_FFFF: out.append(type | 26); out.append(contentsOf: bigEndian(argument, 4))
        default: out.append(type | 27); out.append(contentsOf: bigEndian(argument, 8))
        }
    }

    private static func bigEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    private static func write(_ value: Value, into out: inout Data) {
        switch value {
        case .unsigned(let n): head(0, n, into: &out)
        case .negative(let n): head(1, UInt64(-1 - n), into: &out)
        case .bytes(let data):
            head(2, UInt64(data.count), into: &out)
            out.append(data)
        case .text(let string):
            let utf8 = Data(string.utf8)
            head(3, UInt64(utf8.count), into: &out)
            out.append(utf8)
        case .array(let items):
            head(4, UInt64(items.count), into: &out)
            for item in items { write(item, into: &out) }
        case .map(let pairs):
            head(5, UInt64(pairs.count), into: &out)
            for (key, item) in pairs {
                write(key, into: &out)
                write(item, into: &out)
            }
        }
    }
}

/// Сторона аутентификатора WebAuthn (https://www.w3.org/TR/webauthn-3/): создание passkey и подпись входа.
/// Аттестация — «none»: Ward не доказывает сайту модель устройства, как и остальные менеджеры паролей.
public enum WebAuthn {
    public enum Failure: LocalizedError, Equatable {
        case insecureOrigin(String)
        case rpIDMismatch(rpID: String, origin: String)
        case unsupportedAlgorithm

        public var errorDescription: String? {
            switch self {
            case .insecureOrigin(let origin): return "Passkey только для https-сайтов, а не \(origin)"
            case .rpIDMismatch(let rpID, let origin): return "Сайт \(origin) просит passkey чужого домена \(rpID)"
            case .unsupportedAlgorithm: return "Сайт не принимает ключи ES256 (P-256)"
            }
        }
    }

    /// COSE: ES256 — ECDSA на P-256 с SHA-256.
    public static let es256: Int = -7
    /// Ward — «менеджер паролей без аттестации»: AAGUID из нулей.
    static let aaguid = Data(count: 16)

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let userPresent = Flags(rawValue: 0x01)
        static let userVerified = Flags(rawValue: 0x04)
        /// Backup eligible / backed up: passkey синхронизируемый (копии хранилища), а не привязан к железу.
        static let backupEligible = Flags(rawValue: 0x08)
        static let backedUp = Flags(rawValue: 0x10)
        static let attestedData = Flags(rawValue: 0x40)
    }

    /// Хост происхождения («https://login.github.com» → «login.github.com»), если оно безопасное:
    /// https или http на localhost — как требует браузер для WebAuthn.
    public static func host(ofOrigin origin: String) throws -> String {
        guard let comps = URLComponents(string: origin), let host = comps.host?.lowercased(), !host.isEmpty else {
            throw Failure.insecureOrigin(origin)
        }
        let local = host == "localhost" || host.hasSuffix(".localhost")
        guard comps.scheme == "https" || (comps.scheme == "http" && local) else { throw Failure.insecureOrigin(origin) }
        return host
    }

    /// rpId сайта: сам хост или его родительский домен, но не общий суффикс («com», «github.io»).
    /// Иначе фишинговая страница могла бы попросить passkey чужого сайта.
    public static func validate(rpID: String, origin: String) throws {
        let host = try Self.host(ofOrigin: origin)
        let rp = rpID.lowercased()
        let suffixOK = host == rp || host.hasSuffix("." + rp)
        let notPublicSuffix = rp == "localhost" || PublicSuffix.registrableDomain(rp) != nil
        guard !rp.isEmpty, suffixOK, notPublicSuffix else { throw Failure.rpIDMismatch(rpID: rpID, origin: origin) }
    }

    /// clientDataJSON, как его собирает браузер: поля в порядке спецификации (§5.8.1.1), challenge — base64url.
    public static func clientData(type: String, challenge: Data, origin: String, crossOrigin: Bool = false) -> Data {
        func quoted(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
        let json = "{\"type\":\(quoted(type)),\"challenge\":\(quoted(base64url(challenge))),"
            + "\"origin\":\(quoted(origin)),\"crossOrigin\":\(crossOrigin ? "true" : "false")}"
        return Data(json.utf8)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// Результат создания passkey: сам passkey для хранилища и то, что браузер вернёт сайту.
    public struct Registration: Sendable {
        public let passkey: Passkey
        public let attestationObject: Data
        public let authenticatorData: Data
        /// Открытый ключ в SubjectPublicKeyInfo (DER) — для `getPublicKey()` в браузере.
        public let publicKeyDER: Data
    }

    /// Аттестация «none» ничего не подписывает, поэтому хэш clientDataJSON при создании не нужен (§8.7).
    public static func register(rpID: String, origin: String, userHandle: Data, userName: String, userDisplayName: String,
                                algorithms: [Int], now: Date = Date()) throws -> Registration {
        try validate(rpID: rpID, origin: origin)
        guard algorithms.isEmpty || algorithms.contains(es256) else { throw Failure.unsupportedAlgorithm }
        let key = P256.Signing.PrivateKey()
        let credentialID = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let passkey = Passkey(id: credentialID, rpID: rpID.lowercased(), userHandle: userHandle, userName: userName,
                              userDisplayName: userDisplayName, privateKey: key.rawRepresentation, createdAt: now)
        let x963 = key.publicKey.x963Representation
        let cose = CBOR.encode(.map([
            (.int(1), .int(2)),        // kty: EC2
            (.int(3), .int(Int64(es256))),
            (.int(-1), .int(1)),       // crv: P-256
            (.int(-2), .bytes(x963.subdata(in: 1..<33))),
            (.int(-3), .bytes(x963.subdata(in: 33..<65))),
        ]))
        var attested = aaguid
        attested.append(contentsOf: [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xFF)])
        attested.append(credentialID)
        attested.append(cose)
        let authData = authenticatorData(rpID: passkey.rpID,
                                         flags: [.userPresent, .userVerified, .backupEligible, .backedUp, .attestedData]) + attested
        let attestation = CBOR.encode(.map([
            (.text("fmt"), .text("none")),
            (.text("attStmt"), .map([])),
            (.text("authData"), .bytes(authData)),
        ]))
        return Registration(passkey: passkey, attestationObject: attestation, authenticatorData: authData,
                            publicKeyDER: key.publicKey.derRepresentation)
    }

    public struct Assertion: Sendable {
        public let authenticatorData: Data
        /// ECDSA в DER — такую подпись ES256 ждёт WebAuthn.
        public let signature: Data
    }

    public static func assert(_ passkey: Passkey, origin: String, clientDataHash: Data) throws -> Assertion {
        try validate(rpID: passkey.rpID, origin: origin)
        let key = try P256.Signing.PrivateKey(rawRepresentation: passkey.privateKey)
        let authData = authenticatorData(rpID: passkey.rpID, flags: [.userPresent, .userVerified, .backupEligible, .backedUp])
        let signature = try key.signature(for: authData + clientDataHash).derRepresentation
        return Assertion(authenticatorData: authData, signature: signature)
    }

    /// rpIdHash ‖ flags ‖ signCount. Счётчик — всегда 0: у синхронизируемых passkey он не растёт (§6.1.1).
    static func authenticatorData(rpID: String, flags: Flags) -> Data {
        Data(SHA256.hash(data: Data(rpID.utf8))) + [flags.rawValue, 0, 0, 0, 0]
    }
}

extension Vault {
    /// Passkey сайта для входа: только того же rpId и из живых записей.
    public func passkeys(forRPID rpID: String) -> [(entry: Entry, passkey: Passkey)] {
        let rp = rpID.lowercased()
        return entries.filter { !$0.isDeleted }.flatMap { entry in
            entry.passkeys.filter { $0.rpID == rp }.map { (entry, $0) }
        }
    }

    public func passkey(id: Data) -> (entry: Entry, passkey: Passkey)? {
        for entry in entries where !entry.isDeleted {
            if let passkey = entry.passkeys.first(where: { $0.id == id }) { return (entry, passkey) }
        }
        return nil
    }
}
