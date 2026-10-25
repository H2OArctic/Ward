import Foundation

public struct PasswordStrength: Equatable, Sendable {
    /// 0 — пусто, 1 — слабый, 2 — средний, 3 — хороший, 4 — надёжный.
    public let score: Int
    public let bits: Double

    private static let patterns = [
        "qwerty", "йцукен", "asdf", "zxcv", "1234", "2345", "3456", "4567", "5678", "6789", "0000", "1111",
        "password", "passw0rd", "пароль", "admin", "letmein", "welcome", "iloveyou", "monkey", "dragon", "abc123",
    ]

    public static func evaluate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return PasswordStrength(score: 0, bits: 0) }
        var hasLower = false, hasUpper = false, hasDigit = false, hasSymbol = false, hasOther = false
        for scalar in password.unicodeScalars {
            switch scalar {
            case "a"..."z": hasLower = true
            case "A"..."Z": hasUpper = true
            case "0"..."9": hasDigit = true
            case "!"..."~": hasSymbol = true
            default: hasOther = true
            }
        }
        var pool = 0
        if hasLower { pool += 26 }
        if hasUpper { pool += 26 }
        if hasDigit { pool += 10 }
        if hasSymbol { pool += 33 }
        if hasOther { pool += 100 }
        var bits = Double(password.count) * log2(Double(max(pool, 2)))
        if Set(password).count <= 2 { bits = min(bits, 10) }
        let lowered = password.lowercased()
        if patterns.contains(where: lowered.contains) { bits = min(bits, 30) }
        let characters = Array(lowered)
        if characters.count >= 6 {
            for suffix in 0...min(2, characters.count - 6) {
                let count = characters.count - suffix
                var prefix = [Int](repeating: 0, count: count)
                for i in 1..<count {
                    var matched = prefix[i - 1]
                    while matched > 0 && characters[i] != characters[matched] { matched = prefix[matched - 1] }
                    if characters[i] == characters[matched] { matched += 1 }
                    prefix[i] = matched
                }
                let length = count - prefix[count - 1]
                if length <= count / 2 {
                    bits = min(bits, Double(length + suffix) * log2(Double(max(pool, 2))) + log2(Double(characters.count)))
                }
            }
            let sequences = ["abcdefghijklmnopqrstuvwxyz", "0123456789", "йцукенгшщзхъфывапролджэячсмитьбю", "qwertyuiopasdfghjklzxcvbnm"]
            if sequences.contains(where: { $0.contains(lowered) || String($0.reversed()).contains(lowered) }) {
                bits = min(bits, 20)
            }
        }
        let score = bits < 45 ? 1 : bits < 60 ? 2 : bits < 80 ? 3 : 4
        return PasswordStrength(score: score, bits: bits)
    }
}

public struct GeneratorOptions: Codable, Equatable, Sendable {
    /// Настройки лежат в UserDefaults, где их может переписать любой процесс: длина вне этих границ
    /// (2 символа или миллиард) при генерации не принимается.
    public static let lengths = 8...64

    public var length: Int
    public var digits: Bool
    public var symbols: Bool
    public var words: Bool

    public init(length: Int = 20, digits: Bool = true, symbols: Bool = true, words: Bool = false) {
        self.length = length
        self.digits = digits
        self.symbols = symbols
        self.words = words
    }
}

public enum PasswordGenerator {
    // Без l/I/O/0/1 — чтобы пароль можно было продиктовать и перепечатать.
    private static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    private static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digitChars = Array("23456789")
    private static let symbolChars = Array("!#$%&*+-=?@^_")
    private static let consonants = Array("bdfghklmnprstvz")
    private static let vowels = Array("aeiou")

    public static func generate(_ options: GeneratorOptions) -> String {
        var options = options
        options.length = min(max(options.length, GeneratorOptions.lengths.lowerBound), GeneratorOptions.lengths.upperBound)
        var rng = SystemRandomNumberGenerator()
        return options.words ? phrase(options, using: &rng) : characters(options, using: &rng)
    }

    private static func characters<R: RandomNumberGenerator>(_ options: GeneratorOptions, using rng: inout R) -> String {
        var classes = [lower, upper]
        if options.digits { classes.append(digitChars) }
        if options.symbols { classes.append(symbolChars) }
        let length = max(options.length, classes.count)
        var chars = classes.map { $0.randomElement(using: &rng)! }
        let all = classes.flatMap { $0 }
        while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }

    /// Слова из трёх слогов «согласная+гласная» (~18 бит на слово), без словаря.
    private static func phrase<R: RandomNumberGenerator>(_ options: GeneratorOptions, using rng: inout R) -> String {
        let count = min(max(options.length / 5, 3), 10)
        var words: [String] = (0..<count).map { _ in
            String((0..<3).flatMap { _ in
                [consonants.randomElement(using: &rng)!, vowels.randomElement(using: &rng)!]
            })
        }
        if options.digits {
            words.append(String((0..<2).map { _ in digitChars.randomElement(using: &rng)! }))
        }
        return words.joined(separator: options.symbols ? "-" : ".")
    }
}

public enum PasswordAudit {
    /// Сколько раз встречается каждый пароль среди живых записей с паролем.
    public static func reuseCounts(_ entries: [Entry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.isDeleted && entry.authKind == .password && !entry.secret.isEmpty {
            counts[entry.secret, default: 0] += 1
        }
        return counts
    }
}

/// Мастер-пароль защищает и копии, которые любой процесс пользователя может прочитать и перебирать офлайн.
public enum MasterPasswordPolicy {
    public static let minLength = 12

    /// `nil` — пароль подходит.
    public static func problem(_ password: String) -> String? {
        if password.count < minLength { return "Минимум \(minLength) символов" }
        if PasswordStrength.evaluate(password).score < 3 {
            return "Слишком простой — добавьте слов, цифр или символов"
        }
        return nil
    }
}

/// Сверка сайта, открытого в браузере, с сайтом записи — чтобы автовставка не отдала пароль фишинговой странице.
public enum SiteMatch {
    public static func matches(pageHost: String, entryHost: String) -> Bool {
        let page = normalize(pageHost), entry = normalize(entryHost)
        guard !page.isEmpty, !entry.isEmpty else { return false }
        return page == entry
    }

    private static func normalize(_ host: String) -> String {
        var host = host.lowercased().trimmingCharacters(in: .whitespaces)
        // Браузер сообщает «пример.рф» как «xn--e1afmkfd.xn--p1ai» — сравниваем в одной форме.
        if !host.allSatisfy(\.isASCII) {
            var comps = URLComponents()
            comps.host = host
            host = comps.encodedHost?.lowercased() ?? host
        }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }
}
