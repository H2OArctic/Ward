import Foundation

/// Экспорт Паролей Apple/Safari, Chrome, Firefox, Bitwarden: колонки узнаются по заголовку.
public enum CSVImport {
    public static func parse(_ text: String, delimiter: Unicode.Scalar = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        var isFirst = true

        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return iterator.next()
        }

        while let c = next() {
            if isFirst {
                isFirst = false
                if c == "\u{FEFF}" { continue }
            }
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = n
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
            case delimiter:
                row.append(String(field))
                field = String.UnicodeScalarView()
            case "\r":
                continue
            case "\n":
                row.append(String(field))
                field = String.UnicodeScalarView()
                rows.append(row)
                row = []
            default:
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }

    public static func entries(from text: String, space: VaultSpace, now: Date = Date()) -> [Entry] {
        // Excel с русской локалью сохраняет CSV через «;».
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let delimiter: Unicode.Scalar = firstLine.contains(";") && !firstLine.contains(",") ? ";" : ","
        let rows = parse(text, delimiter: delimiter)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return [] }
        func column(_ names: [String]) -> Int? { header.firstIndex(where: names.contains) }
        let titleCol = column(["title", "name"])
        let urlCol = column(["url", "website", "login_uri", "web site"])
        let userCol = column(["username", "login", "login_username", "user name", "email"])
        let passCol = column(["password", "login_password"])
        let notesCol = column(["notes", "note", "extra", "comments"])
        let otpCol = column(["otpauth", "totp", "login_totp", "otp"])

        return rows.dropFirst().compactMap { row in
            func raw(_ col: Int?) -> String {
                guard let col, col < row.count else { return "" }
                return row[col]
            }
            func value(_ col: Int?) -> String { raw(col).trimmingCharacters(in: .whitespacesAndNewlines) }
            let login = value(userCol)
            // Пробелы по краям пароля — часть пароля, их не обрезаем.
            let password = raw(passCol)
            let url = value(urlCol)
            let otp = value(otpCol)
            guard !(login.isEmpty && password.isEmpty && url.isEmpty && otp.isEmpty) else { return nil }

            var entry = Entry(space: space, now: now)
            entry.login = login
            entry.loginKind = LoginKind.detect(login)
            entry.secret = password
            entry.url = url
            entry.notes = value(notesCol)
            entry.totp = otp.isEmpty ? nil : TOTPConfig.parse(otp)
            let title = value(titleCol)
            entry.title = !title.isEmpty ? title : (entry.host ?? (login.isEmpty ? "Без названия" : login))
            return entry
        }
    }
}
