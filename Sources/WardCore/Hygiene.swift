import Foundation
import CryptoKit

extension Entry {
    /// Когда пароль последний раз менялся: по истории, иначе — с создания записи.
    public var passwordChangedAt: Date { passwordUpdatedAt ?? history.first?.changedAt ?? createdAt }

    /// Не слабость пароля, а гигиена: сайт без шифрования, пароль давно не менялся.
    public func hygieneIssue(at date: Date = Date()) -> String? {
        if address?.scheme == "http", !secret.isEmpty, authKind != .sso {
            return "Сайт без HTTPS — пароль уходит открытым текстом"
        }
        if authKind == .password, !secret.isEmpty,
           let years = Calendar.current.dateComponents([.year], from: passwordChangedAt, to: date).year, years >= 1 {
            return "Пароль не меняли больше года"
        }
        return nil
    }
}

/// Проверка по базе утечек Have I Been Pwned (k-анонимность): наружу уходят только первые 5 символов SHA-1,
/// сам пароль и даже его полный хеш не покидают Mac. Сеть — снаружи, чтобы ядро оставалось без неё.
public enum PwnedPasswords {
    public static func rangeURL(prefix: String) -> URL {
        URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!
    }

    public static func sha1(_ password: String) -> String {
        Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// `fetch(prefix)` возвращает ответ сервиса для префикса. Результат — сколько раз каждый пароль встречался в утечках
    /// (0 — не встречался). Один запрос на префикс, даже если паролей с ним несколько.
    public static func check(_ passwords: Set<String>, concurrency: Int = 8,
                             fetch: @escaping @Sendable (String) async throws -> String) async throws -> [String: Int] {
        var byPrefix: [String: [(password: String, suffix: String)]] = [:]
        for password in passwords where !password.isEmpty {
            let hash = sha1(password)
            byPrefix[String(hash.prefix(5)), default: []].append((password, String(hash.dropFirst(5))))
        }
        // Несколько запросов параллельно: сотни паролей по одному ждали бы минуты.
        var counts: [String: [String: Int]] = [:]
        try await withThrowingTaskGroup(of: (String, [String: Int]).self) { group in
            var pending = byPrefix.keys.sorted().makeIterator()
            for _ in 0..<max(concurrency, 1) {
                guard let prefix = pending.next() else { break }
                group.addTask { (prefix, parse(try await fetch(prefix))) }
            }
            while let (prefix, parsed) = try await group.next() {
                counts[prefix] = parsed
                if let next = pending.next() { group.addTask { (next, parse(try await fetch(next))) } }
            }
        }
        var result: [String: Int] = [:]
        for (prefix, items) in byPrefix {
            for item in items { result[item.password] = counts[prefix]?[item.suffix] ?? 0 }
        }
        return result
    }

    /// Строки «SUFFIX:COUNT». С заголовком Add-Padding сервис добавляет фиктивные строки с нулём — они не мешают.
    static func parse(_ body: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            guard parts.count == 2, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            counts[parts[0].trimmingCharacters(in: .whitespaces).uppercased()] = count
        }
        return counts
    }
}

/// Экспорт в CSV в раскладке Паролей Apple — его читают Apple, Chrome, Bitwarden, 1Password и сам Ward.
public enum CSVExport {
    public static func export(_ entries: [Entry]) -> String {
        var lines = [row(["Title", "URL", "Username", "Password", "Notes", "OTPAuth"])]
        for entry in entries where !entry.isDeleted {
            var notes = entry.notes
            let extra = entry.fields.filter { !$0.name.isEmpty || !$0.value.isEmpty }.map { "\($0.name): \($0.value)" }
            if !extra.isEmpty { notes += (notes.isEmpty ? "" : "\n") + extra.joined(separator: "\n") }
            lines.append(row([neutralized(entry.title), entry.url, entry.login, entry.authKind == .sso ? "" : entry.secret,
                              neutralized(notes),
                              entry.totp.map(OTPAuthURI.build) ?? ""]))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Текст, который Excel и Numbers приняли бы за формулу («=HYPERLINK(…)»), экранируется апострофом.
    /// Только в названии и заметках: логин «+7…» и пароль «=…» обязаны остаться точными для импорта.
    static func neutralized(_ text: String) -> String {
        guard let first = text.first, "=+-@\t\r".contains(first) else { return text }
        return "'" + text
    }

    static func row(_ fields: [String]) -> String {
        fields.map { field in
            guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) || field.hasPrefix(" ") || field.hasSuffix(" ")
            else { return field }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
    }
}
