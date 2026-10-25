import Foundation
import CryptoKit

public enum OTPAlgorithm: String, Codable, CaseIterable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

public struct TOTPConfig: Codable, Hashable, Sendable {
    public var secret: Data
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int
    public var issuer: String?
    public var account: String?

    public init(secret: Data, algorithm: OTPAlgorithm = .sha1, digits: Int = 6, period: Int = 30,
                issuer: String? = nil, account: String? = nil) {
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.issuer = issuer
        self.account = account
    }

    /// Принимает и `otpauth://totp/...`, и голый base32-ключ.
    public static func parse(_ input: String) -> TOTPConfig? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") {
            return OTPAuthURI.parse(trimmed)
        }
        guard let secret = Base32.decode(trimmed), secret.count >= 5 else { return nil }
        return TOTPConfig(secret: secret)
    }
}

public enum TOTP {
    public static func code(_ config: TOTPConfig, at date: Date = Date()) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(max(config.period, 1)))
        return hotp(secret: config.secret, counter: counter, digits: config.digits, algorithm: config.algorithm)
    }

    public static func hotp(secret: Data, counter: UInt64, digits: Int, algorithm: OTPAlgorithm) -> String {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        let digits = min(max(digits, 6), 8)
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: digits - value.count) + value
    }

    public static func secondsRemaining(period: Int, at date: Date = Date()) -> Int {
        let period = max(period, 1)
        return period - Int(date.timeIntervalSince1970) % period
    }

    /// «482913» → «482 913», «12345678» → «1234 5678».
    public static func formatted(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }
}

public enum OTPAuthURI {
    public static func parse(_ string: String) -> TOTPConfig? {
        guard let comps = URLComponents(string: string),
              comps.scheme?.lowercased() == "otpauth",
              comps.host?.lowercased() == "totp" else { return nil }
        var items: [String: String] = [:]
        for item in comps.queryItems ?? [] where items[item.name.lowercased()] == nil {
            items[item.name.lowercased()] = item.value ?? ""
        }
        guard let secretText = items["secret"], let secret = Base32.decode(secretText), secret.count >= 5 else { return nil }

        var label = comps.path
        if label.hasPrefix("/") { label.removeFirst() }
        var issuer = items["issuer"].flatMap { $0.isEmpty ? nil : $0 }
        var account: String? = label.isEmpty ? nil : label
        if let colon = label.firstIndex(of: ":") {
            let prefix = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if issuer == nil, !prefix.isEmpty { issuer = prefix }
        }

        let algorithm = OTPAlgorithm(rawValue: (items["algorithm"] ?? "SHA1").uppercased()) ?? .sha1
        var digits = Int(items["digits"] ?? "") ?? 6
        if !(6...8).contains(digits) { digits = 6 }
        var period = Int(items["period"] ?? "") ?? 30
        if period <= 0 { period = 30 }
        return TOTPConfig(secret: secret, algorithm: algorithm, digits: digits, period: period,
                          issuer: issuer, account: account)
    }

    public static func build(_ config: TOTPConfig) -> String {
        var comps = URLComponents()
        comps.scheme = "otpauth"
        comps.host = "totp"
        let label = [config.issuer, config.account]
            .compactMap { value -> String? in (value?.isEmpty ?? true) ? nil : value }
            .joined(separator: ":")
        comps.path = "/" + label
        var items = [URLQueryItem(name: "secret", value: Base32.encode(config.secret))]
        if let issuer = config.issuer, !issuer.isEmpty { items.append(URLQueryItem(name: "issuer", value: issuer)) }
        items.append(URLQueryItem(name: "algorithm", value: config.algorithm.rawValue))
        items.append(URLQueryItem(name: "digits", value: String(config.digits)))
        items.append(URLQueryItem(name: "period", value: String(config.period)))
        comps.queryItems = items
        return comps.string ?? ""
    }
}
