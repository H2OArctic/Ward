import Foundation
import CryptoKit

/// Кадр native messaging (Chrome): длина — uint32 в порядке байтов машины (little-endian на Mac), затем JSON.
/// Тот же кадр идёт и по сокету между помощником браузера и Ward.
public enum NativeMessaging {
    /// Chrome не принимает от помощника сообщения больше 1 МБ; от Chrome приходит до 64 МБ, нам столько не нужно.
    public static let maxMessage = 1 << 20

    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) } + json
    }

    /// Длина из заголовка; `nil` — кадр больше допустимого.
    public static func length(ofHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        return Int(value) <= maxMessage ? Int(value) : nil
    }
}

/// Что расширение браузера может спросить у Ward и что получает в ответ. Адрес страницы и происхождение
/// берутся расширением у самого браузера (sender), а не со страницы, — страница их подделать не может.
public enum BrowserRequest: Equatable {
    case hello
    case logins(url: String)
    case fill(entryID: UUID, url: String)
    case createPasskey(PasskeyCreation)
    case getPasskey(PasskeyRequest)

    public struct PasskeyCreation: Equatable {
        public var origin: String
        public var rpID: String
        public var rpName: String
        public var userHandle: Data
        public var userName: String
        public var userDisplayName: String
        public var challenge: Data
        public var algorithms: [Int]
        public var excludeCredentials: [Data]
    }

    public struct PasskeyRequest: Equatable {
        public var origin: String
        public var rpID: String
        public var challenge: Data
        public var allowCredentials: [Data]
    }

    public enum ParseError: Error, Equatable { case malformed(String) }

    /// Разбор JSON от расширения: `{"type": "...", ...}`. Двоичные поля — base64url, как в WebAuthn JSON.
    public static func parse(_ object: [String: Any]) throws -> BrowserRequest {
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw ParseError.malformed(key) }
            return value
        }
        func bytes(_ key: String) throws -> Data {
            guard let value = WebAuthn.fromBase64url(try string(key)) else { throw ParseError.malformed(key) }
            return value
        }
        func byteList(_ key: String) throws -> [Data] {
            guard let list = object[key] as? [String] ?? (object[key] == nil ? [] : nil) else { throw ParseError.malformed(key) }
            return try list.map { guard let data = WebAuthn.fromBase64url($0) else { throw ParseError.malformed(key) }; return data }
        }
        switch object["type"] as? String {
        case "hello": return .hello
        case "logins": return .logins(url: try string("url"))
        case "fill":
            guard let id = UUID(uuidString: try string("entryID")) else { throw ParseError.malformed("entryID") }
            return .fill(entryID: id, url: try string("url"))
        case "passkey.create":
            return .createPasskey(PasskeyCreation(
                origin: try string("origin"), rpID: try string("rpID"), rpName: object["rpName"] as? String ?? "",
                userHandle: try bytes("userHandle"), userName: try string("userName"),
                userDisplayName: object["userDisplayName"] as? String ?? "", challenge: try bytes("challenge"),
                algorithms: object["algorithms"] as? [Int] ?? [], excludeCredentials: try byteList("excludeCredentials")))
        case "passkey.get":
            return .getPasskey(PasskeyRequest(origin: try string("origin"), rpID: try string("rpID"),
                                              challenge: try bytes("challenge"),
                                              allowCredentials: try byteList("allowCredentials")))
        default:
            throw ParseError.malformed("type")
        }
    }
}

/// Решения моста, которые не требуют человека: какие учётки подходят странице, что можно отдать, какой ответ
/// получит сайт. Подтверждения и разблокировку делает приложение.
public enum BrowserBridge {
    public struct Login: Equatable, Sendable {
        public let entryID: UUID
        public let title: String
        public let login: String
        public let hasPassword: Bool
        public let hasCode: Bool
    }

    public struct Fill: Equatable, Sendable {
        public let login: String
        public let password: String
        public let code: String?
    }

    public enum Failure: LocalizedError, Equatable {
        case siteMismatch
        case noSuchEntry
        case alreadyRegistered

        public var errorDescription: String? {
            switch self {
            case .siteMismatch: return "Запись не для этого сайта"
            case .noSuchEntry: return "Записи нет"
            case .alreadyRegistered: return "Для этого сайта passkey уже сохранён"
            }
        }
    }

    /// Хост страницы, если это обычный сайт (http/https).
    public static func pageHost(_ url: String) -> String? {
        guard let comps = URLComponents(string: url), ["http", "https"].contains(comps.scheme?.lowercased()),
              let host = comps.host, !host.isEmpty else { return nil }
        return host
    }

    /// Живые записи с логином или паролем для сайта этой страницы — по той же сверке, что у автовставки.
    public static func logins(for url: String, in vault: Vault) -> [Login] {
        guard let host = pageHost(url) else { return [] }
        return vault.entries
            .filter { !$0.isDeleted && ($0.authKind == .password || $0.authKind == .token) && (!$0.secret.isEmpty || !$0.login.isEmpty) }
            .filter { entry in
                guard let address = entry.address, address.isWeb,
                      SiteMatch.matches(pageHost: host, entryHost: address.host) else { return false }
                return address.webURL(original: entry.url)?.scheme?.lowercased() != "https" || URLComponents(string: url)?.scheme?.lowercased() == "https"
            }
            .sorted { $0.useCount != $1.useCount ? $0.useCount > $1.useCount : $0.title < $1.title }
            .map { Login(entryID: $0.id, title: $0.title, login: $0.login, hasPassword: !$0.secret.isEmpty, hasCode: $0.totp != nil) }
    }

    /// Данные для заполнения — только если запись по-прежнему подходит этой странице (сверка ещё раз, на выдаче).
    public static func fill(entryID: UUID, url: String, in vault: Vault, now: Date = Date()) throws -> Fill {
        guard let entry = vault.entries.first(where: { $0.id == entryID && !$0.isDeleted }) else { throw Failure.noSuchEntry }
        guard logins(for: url, in: vault).contains(where: { $0.entryID == entryID }) else { throw Failure.siteMismatch }
        return Fill(login: entry.login, password: entry.secret, code: entry.totp.map { TOTP.code($0, at: now) })
    }

    /// Ответ сайту на создание passkey — в JSON-форме WebAuthn (двоичное — base64url), готовой для расширения.
    public struct Created: Codable, Equatable, Sendable {
        public let id: String
        public let rawId: String
        public let clientDataJSON: String
        public let attestationObject: String
        public let authenticatorData: String
        public let publicKey: String
        public let publicKeyAlgorithm: Int
    }

    public static func createPasskey(_ request: BrowserRequest.PasskeyCreation, in vault: Vault,
                                     now: Date = Date()) throws -> (passkey: Passkey, response: Created) {
        // Сайт перечислил уже известные ему ключи — повторно для того же аккаунта не создаём (§5.1.3, excludeCredentials).
        if request.excludeCredentials.contains(where: { vault.passkey(id: $0) != nil }) { throw Failure.alreadyRegistered }
        let registration = try WebAuthn.register(rpID: request.rpID, origin: request.origin, userHandle: request.userHandle,
                                                 userName: request.userName, userDisplayName: request.userDisplayName,
                                                 algorithms: request.algorithms, now: now)
        let clientData = WebAuthn.clientData(type: "webauthn.create", challenge: request.challenge, origin: request.origin)
        let b = WebAuthn.base64url
        return (registration.passkey, Created(
            id: b(registration.passkey.id), rawId: b(registration.passkey.id), clientDataJSON: b(clientData),
            attestationObject: b(registration.attestationObject), authenticatorData: b(registration.authenticatorData),
            publicKey: b(registration.publicKeyDER), publicKeyAlgorithm: WebAuthn.es256))
    }

    /// Passkey, которыми можно войти: того же rpId и, если сайт назвал конкретные, — только они.
    public static func candidates(_ request: BrowserRequest.PasskeyRequest, in vault: Vault) throws -> [(entry: Entry, passkey: Passkey)] {
        try WebAuthn.validate(rpID: request.rpID, origin: request.origin)
        let all = vault.passkeys(forRPID: request.rpID)
        guard !request.allowCredentials.isEmpty else { return all }
        return all.filter { request.allowCredentials.contains($0.passkey.id) }
    }

    public struct Asserted: Codable, Equatable, Sendable {
        public let id: String
        public let rawId: String
        public let clientDataJSON: String
        public let authenticatorData: String
        public let signature: String
        public let userHandle: String
    }

    public static func assertion(_ passkey: Passkey, request: BrowserRequest.PasskeyRequest) throws -> Asserted {
        let clientData = WebAuthn.clientData(type: "webauthn.get", challenge: request.challenge, origin: request.origin)
        let assertion = try WebAuthn.assert(passkey, origin: request.origin, clientDataHash: Data(SHA256.hash(data: clientData)))
        let b = WebAuthn.base64url
        return Asserted(id: b(passkey.id), rawId: b(passkey.id), clientDataJSON: b(clientData),
                        authenticatorData: b(assertion.authenticatorData), signature: b(assertion.signature),
                        userHandle: b(passkey.userHandle))
    }
}
