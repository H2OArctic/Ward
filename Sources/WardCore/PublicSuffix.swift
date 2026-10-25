import Foundation

/// Алгоритм Public Suffix List (https://publicsuffix.org/list/): где кончается общий суффикс («co.uk», «github.io»)
/// и начинается сайт конкретного владельца. Список встроен (`PublicSuffixList.swift`), сеть не нужна.
public enum PublicSuffix {
    private struct Table {
        var rules = Set<String>()
        /// «*.ck» хранится как «ck».
        var wildcards = Set<String>()
        /// «!www.ck» хранится как «www.ck».
        var exceptions = Set<String>()
    }

    private static let table: Table = {
        var table = Table()
        for line in rules.split(separator: "\n") {
            if line.hasPrefix("!") {
                table.exceptions.insert(String(line.dropFirst()))
            } else if line.hasPrefix("*.") {
                table.wildcards.insert(String(line.dropFirst(2)))
            } else {
                table.rules.insert(String(line))
            }
        }
        return table
    }()

    /// Хост в нижнем регистре и punycode, без точки в конце: «www.example.co.uk» → «example.co.uk».
    /// `nil` — хост сам является общим суффиксом или не похож на доменное имя.
    public static func registrableDomain(_ host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return nil }
        let length = suffixLength(labels)
        guard labels.count > length else { return nil }
        return labels.suffix(length + 1).joined(separator: ".")
    }

    /// Сколько меток справа занимает общий суффикс. Без подходящего правила — одна (правило «*»).
    static func suffixLength(_ labels: [String]) -> Int {
        let t = table
        var longest = 1
        var exception: Int?
        for count in 1...labels.count {
            let candidate = labels.suffix(count).joined(separator: ".")
            if t.exceptions.contains(candidate) { exception = count - 1 }
            if t.rules.contains(candidate) { longest = max(longest, count) }
            if count < labels.count, t.wildcards.contains(candidate) { longest = max(longest, count + 1) }
        }
        // Исключение («!city.kobe.jp») важнее любого другого совпавшего правила.
        return exception ?? longest
    }
}
