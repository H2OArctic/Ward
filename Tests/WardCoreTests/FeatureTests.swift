import XCTest
@testable import WardCore

final class FeatureTests: XCTestCase {
    // MARK: - Дополнительные поля

    func testCustomFieldsRoundTripAndOldEntries() throws {
        var entry = Entry(title: "Карта")
        entry.fields = [CustomField(name: "Номер", value: "4111 1111 1111 1111"), CustomField(name: "CVV", value: "123", hidden: true)]
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.fields, entry.fields)
        let old = try JSONDecoder().decode(Entry.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        XCTAssertEqual(old.fields, [])
    }

    func testSearchCoversNotesAndVisibleFieldsButNotHidden() {
        var card = Entry(title: "Карта Т-Банк")
        card.fields = [CustomField(name: "Номер", value: "4111 2222"), CustomField(name: "PIN", value: "9876", hidden: true)]
        var note = Entry(title: "Роутер")
        note.notes = "Серийный номер SN-555"
        XCTAssertEqual(EntrySearch.search([card, note], query: "4111").map(\.title), ["Карта Т-Банк"])
        XCTAssertEqual(EntrySearch.search([card, note], query: "sn-555").map(\.title), ["Роутер"])
        XCTAssertEqual(EntrySearch.search([card, note], query: "9876"), [], "скрытые поля не ищутся")
    }

    // MARK: - Гигиена

    func testHygieneIssues() {
        let now = Date()
        var entry = Entry(title: "Сайт", now: now)
        entry.secret = "Vk7#qP2m!xR9tL"
        entry.url = "https://example.com"
        XCTAssertNil(entry.hygieneIssue(at: now))

        entry.url = "http://example.com"
        XCTAssertEqual(entry.hygieneIssue(at: now), "Сайт без HTTPS — пароль уходит открытым текстом")
        entry.url = "example.com"
        XCTAssertNil(entry.hygieneIssue(at: now), "без схемы — не значит http")

        let later = Calendar.current.date(byAdding: .month, value: 13, to: now)!
        XCTAssertEqual(entry.hygieneIssue(at: later), "Пароль не меняли больше года")
        entry.history = [PasswordChange(value: "old", changedAt: Calendar.current.date(byAdding: .month, value: 6, to: now)!)]
        XCTAssertNil(entry.hygieneIssue(at: later), "смена по истории считается")
    }

    // MARK: - Утечки

    private actor Requests {
        var prefixes: [String] = []
        func add(_ prefix: String) { prefixes.append(prefix) }
    }

    func testPwnedPasswordsKAnonymity() async throws {
        // SHA-1("password") = 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8
        let log = Requests()
        let result = try await PwnedPasswords.check(["password", "другой-пароль-Ward"]) { prefix in
            await log.add(prefix)
            return prefix == "5BAA6"
                ? "1E4C9B93F3F0682250B6CF8331B7EE68FD8:9659365\r\n0000000000000000000000000000000000A:0\r\n"
                : "0000000000000000000000000000000000B:0\r\n"
        }
        XCTAssertEqual(result["password"], 9659365)
        XCTAssertEqual(result["другой-пароль-Ward"], 0)
        let requested = await log.prefixes
        XCTAssertTrue(requested.allSatisfy { $0.count == 5 }, "наружу уходят только 5 символов хеша")
        XCTAssertTrue(requested.contains("5BAA6"))
        XCTAssertEqual(requested.count, 2)
    }

    func testPwnedManyPrefixesInParallelKeepEveryResult() async throws {
        let passwords = Set((0..<60).map { "пароль-\($0)" })
        let result = try await PwnedPasswords.check(passwords, concurrency: 8) { prefix in
            // Для каждого префикса «утёк» каждый пароль с ним — проверяем, что ни один ответ не потерялся.
            let suffixes = passwords.map(PwnedPasswords.sha1).filter { $0.hasPrefix(prefix) }.map { $0.dropFirst(5) }
            return suffixes.map { "\($0):7" }.joined(separator: "\r\n")
        }
        XCTAssertEqual(result.count, 60)
        XCTAssertTrue(result.values.allSatisfy { $0 == 7 })
    }

    func testPasswordAddedLaterIsNotStale() {
        let created = Date(timeIntervalSinceNow: -3 * 365 * 86400)
        var vault = Vault()
        var entry = Entry(title: "Сервер", now: created)
        vault.upsert(entry, now: created)
        entry = vault.entries[0]
        entry.secret = "Vk7#qP2m!xR9tL"
        vault.upsert(entry, now: Date())
        XCTAssertNil(vault.entries[0].hygieneIssue(), "пароль задан сегодня, хоть запись и старая")
        XCTAssertEqual(vault.entries[0].history, [], "пустой прежний пароль в историю не пишется")
    }

    func testCSVFormulaNeutralisedOnlyInTextColumns() {
        var e = Entry(title: "=HYPERLINK(\"x\")")
        e.login = "+7 900 000-00-00"
        e.secret = "=secret"
        e.notes = "@note"
        let back = CSVImport.entries(from: CSVExport.export([e]), space: .personal).first
        XCTAssertEqual(back?.title, "'=HYPERLINK(\"x\")")
        XCTAssertEqual(back?.notes, "'@note")
        XCTAssertEqual(back?.login, "+7 900 000-00-00", "логин без искажений")
        XCTAssertEqual(back?.secret, "=secret", "пароль без искажений")
    }

    func testPwnedPasswordsOneRequestPerPrefixAndErrorsPropagate() async {
        struct Offline: Error {}
        do {
            _ = try await PwnedPasswords.check(["x"]) { _ in throw Offline() }
            XCTFail("ошибка сети не должна превращаться в «утечек нет»")
        } catch {
            XCTAssertTrue(error is Offline)
        }
    }

    // MARK: - Экспорт

    func testCSVExportRoundTripsThroughImport() {
        var a = Entry(title: "GitHub, личный")
        a.url = "https://github.com"
        a.login = "you@example.com"
        a.secret = " p\"a,ss "
        a.notes = "строка 1\nстрока 2"
        a.totp = TOTPConfig(secret: Data("12345678901234567890".utf8), issuer: "GitHub", account: "you")
        a.fields = [CustomField(name: "PIN", value: "1234", hidden: true)]
        var sso = Entry(title: "Grafana")
        sso.authKind = .sso
        sso.secret = "не должен уйти"
        var trashed = Entry(title: "Удалённая")
        trashed.deletedAt = Date()

        let csv = CSVExport.export([a, sso, trashed])
        XCTAssertFalse(csv.contains("Удалённая"))
        XCTAssertFalse(csv.contains("не должен уйти"))

        let back = CSVImport.entries(from: csv, space: .personal)
        XCTAssertEqual(back.count, 1, "запись без логина, пароля, адреса и 2FA импорт пропускает")
        let first = back[0]
        XCTAssertEqual(first.title, a.title)
        XCTAssertEqual(first.secret, a.secret, "пароль с пробелами, кавычкой и запятой — без искажений")
        XCTAssertEqual(first.login, a.login)
        XCTAssertEqual(first.totp?.secret, a.totp?.secret)
        XCTAssertEqual(first.notes, "строка 1\nстрока 2\nPIN: 1234")
    }
}
