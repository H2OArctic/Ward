// Обновляет встроенный Public Suffix List: swift tools/update-psl.swift [файл .dat]
// Без аргумента скачивает список с publicsuffix.org. Правила сразу переводятся в punycode —
// в той же форме, в какой SiteMatch сравнивает адреса.
import Foundation

let source = "https://publicsuffix.org/list/public_suffix_list.dat"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Sources/WardCore/PublicSuffixList.swift")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let data: Data
if CommandLine.arguments.count > 1 {
    guard let file = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
        fail("Не прочитать \(CommandLine.arguments[1])")
    }
    data = file
} else {
    guard let url = URL(string: source), let downloaded = try? Data(contentsOf: url) else { fail("Не скачать \(source)") }
    data = downloaded
}
guard let text = String(data: data, encoding: .utf8) else { fail("Список не в UTF-8") }

func punycode(_ label: String) -> String {
    guard label != "*", !label.allSatisfy(\.isASCII) else { return label.lowercased() }
    var comps = URLComponents()
    comps.host = label
    guard let encoded = comps.encodedHost, encoded.allSatisfy(\.isASCII) else { fail("Не перевести в punycode: \(label)") }
    return encoded.lowercased()
}

var version = ""
var rules: [String] = []
var seen = Set<String>()
for line in text.split(whereSeparator: \.isNewline) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("// VERSION:") { version = String(trimmed.dropFirst("// VERSION:".count)).trimmingCharacters(in: .whitespaces) }
    // Правило — до первого пробела (так требует формат).
    guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), let token = trimmed.split(whereSeparator: \.isWhitespace).first else { continue }
    var rule = String(token)
    let exception = rule.hasPrefix("!")
    if exception { rule.removeFirst() }
    let converted = (exception ? "!" : "") + rule.split(separator: ".", omittingEmptySubsequences: false)
        .map { punycode(String($0)) }.joined(separator: ".")
    guard converted.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.*!".contains($0)) }),
          !converted.contains(".."), !converted.hasPrefix("."), !converted.hasSuffix(".") else {
        fail("Неожиданное правило: \(token)")
    }
    if seen.insert(converted).inserted { rules.append(converted) }
}
guard rules.count > 5000, !version.isEmpty else { fail("Список подозрительно мал или без версии (\(rules.count))") }

let swift = """
// Сгенерировано tools/update-psl.swift — не править руками.
// Public Suffix List \(version), https://publicsuffix.org
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

extension PublicSuffix {
    static let version = "\(version)"

    static let rules = \"\"\"
\(rules.joined(separator: "\n"))
\"\"\"
}

"""
do {
    try swift.write(to: output, atomically: true, encoding: .utf8)
} catch {
    fail("Не записать \(output.path): \(error)")
}
print("\(output.path): \(rules.count) правил, версия \(version)")
