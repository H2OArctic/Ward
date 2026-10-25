import Foundation

/// Экспорт Google Authenticator: `otpauth-migration://offline?data=<base64 protobuf>`.
/// Один QR переносит до ~10 кодов; при большем числе приложение показывает несколько QR.
public enum GoogleAuthMigration {
    public struct Result: Equatable {
        public var codes: [TOTPConfig]
        /// HOTP и MD5 — Ward их не поддерживает, пропускаем и сообщаем.
        public var skipped: Int
    }

    public static func isMigrationLink(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth-migration://")
    }

    public static func parse(_ string: String) -> Result? {
        guard isMigrationLink(string),
              let comps = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = comps.queryItems?.first(where: { $0.name == "data" })?.value,
              let payload = decodeBase64(raw) else { return nil }

        var reader = ProtoReader(payload)
        var result = Result(codes: [], skipped: 0)
        while let field = reader.next() {
            guard field.number == 1, case .bytes(let otp) = field.value else { continue }
            if let config = parseOTP(otp) {
                result.codes.append(config)
            } else {
                result.skipped += 1
            }
        }
        return result.codes.isEmpty && result.skipped == 0 ? nil : result
    }

    private static func parseOTP(_ bytes: [UInt8]) -> TOTPConfig? {
        var reader = ProtoReader(bytes)
        var secret: [UInt8] = []
        var name = "", issuer = ""
        var algorithm: UInt64 = 0, digits: UInt64 = 0, type: UInt64 = 0
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .bytes(let b)): secret = b
            case (2, .bytes(let b)): name = String(decoding: b, as: UTF8.self)
            case (3, .bytes(let b)): issuer = String(decoding: b, as: UTF8.self)
            case (4, .varint(let v)): algorithm = v
            case (5, .varint(let v)): digits = v
            case (6, .varint(let v)): type = v
            default: break
            }
        }
        // type: 1 — HOTP (счётчик), 2 — TOTP, 0 — не указан (старые экспорты, это TOTP).
        guard type != 1, !secret.isEmpty else { return nil }
        let alg: OTPAlgorithm
        switch algorithm {
        case 0, 1: alg = .sha1
        case 2: alg = .sha256
        case 3: alg = .sha512
        default: return nil
        }
        var account = name
        if let colon = name.firstIndex(of: ":") {
            let prefix = String(name[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if issuer.isEmpty { issuer = prefix }
        }
        return TOTPConfig(secret: Data(secret), algorithm: alg, digits: digits == 2 ? 8 : 6, period: 30,
                          issuer: issuer.isEmpty ? nil : issuer, account: account.isEmpty ? nil : account)
    }

    /// Сканеры отдают base64 то с URL-безопасным алфавитом, то без паддинга.
    private static func decodeBase64(_ text: String) -> [UInt8]? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).map(Array.init)
    }
}

/// Минимальный разбор protobuf: только то, что есть в экспорте Google Authenticator.
struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
    }

    private let data: [UInt8]
    private var index = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    /// Поля fixed32/fixed64 пропускаются циклом, а не рекурсией: файл из тысяч таких полей переполнил бы стек.
    mutating func next() -> (number: Int, value: Value)? {
        while index < data.count, let key = varint() {
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                return (number, .varint(v))
            case 2:
                guard let length = varint(), length <= UInt64(data.count - index) else { return nil }
                let bytes = Array(data[index..<index + Int(length)])
                index += Int(length)
                return (number, .bytes(bytes))
            case 1:
                guard data.count - index >= 8 else { return nil }
                index += 8
            case 5:
                guard data.count - index >= 4 else { return nil }
                index += 4
            default:
                return nil
            }
        }
        return nil
    }

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

extension TOTPConfig {
    /// Всё, что можно вытащить из строки: `otpauth://`, экспорт Google Authenticator или голый ключ.
    public static func parseAll(_ input: String) -> [TOTPConfig] {
        if GoogleAuthMigration.isMigrationLink(input) {
            return GoogleAuthMigration.parse(input)?.codes ?? []
        }
        return parse(input).map { [$0] } ?? []
    }
}

extension Vault {
    /// Каждый код — отдельная запись без пароля. Коды, чей секрет уже есть в хранилище, пропускаются.
    public mutating func importCodes(_ codes: [TOTPConfig], space: VaultSpace, now: Date = Date())
        -> (added: Int, duplicates: Int) {
        var known = Set(entries.filter { !$0.isDeleted }.compactMap { $0.totp?.secret })
        var added = 0, duplicates = 0
        for code in codes {
            guard !known.contains(code.secret) else {
                duplicates += 1
                continue
            }
            known.insert(code.secret)
            var entry = Entry(title: code.issuer ?? code.account ?? "Код 2FA", space: space, now: now)
            if let account = code.account {
                entry.login = account
                entry.loginKind = LoginKind.detect(account)
            }
            entry.totp = code
            entries.append(entry)
            added += 1
        }
        return (added, duplicates)
    }
}
