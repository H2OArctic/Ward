import Foundation

public enum EntrySearch {
    /// `context` добавляет к поиску то, чего нет в самой записи (название проекта, «Работа»).
    /// Запрос, набранный не в той раскладке («пшерги»), тоже находит «github».
    public static func search(_ entries: [Entry], query: String, context: (Entry) -> String = { _ in "" }) -> [Entry] {
        let tokens = tokenize(query)
        let swapped = tokenize(KeyboardLayout.swap(query))
        let scored: [(Entry, Int)] = entries.compactMap { entry in
            let title = entry.title.lowercased()
            // Скрытые поля (PIN, CVV) в поиск не попадают — иначе по ним можно было бы подбирать значение.
            let visibleFields = entry.fields.filter { !$0.hidden }.map { "\($0.name) \($0.value)" }
            let haystack = ([title, context(entry), entry.environments.joined(separator: " "), entry.login, entry.url, entry.notes]
                + visibleFields).joined(separator: " ").lowercased()
            let active: [String]
            if tokens.allSatisfy(haystack.contains) {
                active = tokens
            } else if !swapped.isEmpty, swapped.allSatisfy(haystack.contains) {
                active = swapped
            } else {
                return nil
            }
            var score = min(entry.useCount, 50)
            if let first = active.first {
                if title.hasPrefix(first) { score += 100 } else if title.contains(first) { score += 40 }
            }
            if entry.favorite { score += 10 }
            return (entry, score)
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }.map(\.0)
    }

    private static func tokenize(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

public enum KeyboardLayout {
    private static let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    private static let ru = Array("йцукенгшщзхъфывапролджэячсмитьбюё")
    private static let map: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (a, b) in zip(en, ru) {
            map[a] = b
            map[b] = a
        }
        return map
    }()

    public static func swap(_ text: String) -> String {
        String(text.lowercased().map { map[$0] ?? $0 })
    }
}
