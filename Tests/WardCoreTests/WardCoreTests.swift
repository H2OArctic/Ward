import XCTest
@testable import WardCore

final class TOTPTests: XCTestCase {
    // RFC 6238, приложение B.
    func testRFC6238SHA1() {
        let secret = Data("12345678901234567890".utf8)
        let cases: [(TimeInterval, String)] = [
            (59, "94287082"), (1111111109, "07081804"), (1111111111, "14050471"),
            (1234567890, "89005924"), (2000000000, "69279037"), (20000000000, "65353130"),
        ]
        for (time, expected) in cases {
            let config = TOTPConfig(secret: secret, algorithm: .sha1, digits: 8, period: 30)
            XCTAssertEqual(TOTP.code(config, at: Date(timeIntervalSince1970: time)), expected, "t=\(time)")
        }
    }

    func testRFC6238SHA256AndSHA512() {
        let s256 = Data("12345678901234567890123456789012".utf8)
        let s512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        let t = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(TOTP.code(TOTPConfig(secret: s256, algorithm: .sha256, digits: 8), at: t), "46119246")
        XCTAssertEqual(TOTP.code(TOTPConfig(secret: s512, algorithm: .sha512, digits: 8), at: t), "90693936")
    }

    func testFormattingAndRemaining() {
        XCTAssertEqual(TOTP.formatted("482913"), "482 913")
        XCTAssertEqual(TOTP.formatted("12345678"), "1234 5678")
        XCTAssertEqual(TOTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 59)), 1)
        XCTAssertEqual(TOTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 60)), 30)
    }

    func testBase32RoundTripAndTolerance() {
        let data = Data("12345678901234567890".utf8)
        let encoded = Base32.encode(data)
        XCTAssertEqual(encoded, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(Base32.decode(encoded), data)
        XCTAssertEqual(Base32.decode("gezd gnbv-gy3t qojq gezd gnbv gy3t qojq===="), data)
        XCTAssertNil(Base32.decode("not base32!"))
    }

    func testOTPAuthURI() throws {
        let uri = "otpauth://totp/GitHub:you%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=8&period=60&algorithm=sha256"
        let config = try XCTUnwrap(OTPAuthURI.parse(uri))
        XCTAssertEqual(config.issuer, "GitHub")
        XCTAssertEqual(config.account, "you@example.com")
        XCTAssertEqual(config.digits, 8)
        XCTAssertEqual(config.period, 60)
        XCTAssertEqual(config.algorithm, .sha256)
        XCTAssertEqual(config.secret, Base32.decode("JBSWY3DPEHPK3PXP"))

        let rebuilt = try XCTUnwrap(OTPAuthURI.parse(OTPAuthURI.build(config)))
        XCTAssertEqual(rebuilt, config)
    }

    func testParseAcceptsRawSecretAndLabelIssuer() throws {
        XCTAssertNotNil(TOTPConfig.parse("JBSW Y3DP EHPK 3PXP"))
        let config = try XCTUnwrap(TOTPConfig.parse("otpauth://totp/Cloudflare:me?secret=JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(config.issuer, "Cloudflare")
        XCTAssertEqual(config.account, "me")
        XCTAssertEqual(config.digits, 6)
        XCTAssertNil(TOTPConfig.parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1"))
    }
}

final class VaultCryptoTests: XCTestCase {
    func testRoundTripAndWrongPassword() throws {
        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: "correct horse", iterations: 1000)
        var entry = Entry(title: "GitHub")
        entry.secret = "s3cret"
        let envelope = try VaultCrypto.encode(Vault(entries: [entry]), key: key, slot: slot)

        let reopened = try VaultCrypto.openSlot(slot, password: "correct horse")
        let vault = try VaultCrypto.decode(envelope, key: reopened)
        XCTAssertEqual(vault.entries.first?.secret, "s3cret")

        XCTAssertThrowsError(try VaultCrypto.openSlot(slot, password: "wrong")) { error in
            XCTAssertEqual(error as? VaultCryptoError, .wrongPassword)
        }
    }

    func testChangingPasswordKeepsPayload() throws {
        let key = VaultCrypto.newVaultKey()
        let old = try VaultCrypto.makeSlot(for: key, password: "old", iterations: 1000)
        let envelope = try VaultCrypto.encode(Vault(entries: [Entry(title: "A")]), key: key, slot: old)
        let new = try VaultCrypto.makeSlot(for: key, password: "new", iterations: 1000)
        let moved = VaultEnvelope(format: envelope.format, slot: new, payload: envelope.payload)
        let vault = try VaultCrypto.decode(moved, key: VaultCrypto.openSlot(new, password: "new"))
        XCTAssertEqual(vault.entries.map(\.title), ["A"])
    }

    func testEntryDecodesWithMissingFields() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","title":"Старое"}"#
        let entry = try JSONDecoder().decode(Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.title, "Старое")
        XCTAssertEqual(entry.authKind, .password)
        XCTAssertTrue(entry.preSteps.isEmpty)
    }
}

final class PasswordTests: XCTestCase {
    func testStrength() {
        XCTAssertEqual(PasswordStrength.evaluate("").score, 0)
        XCTAssertEqual(PasswordStrength.evaluate("Qwerty2024!").score, 1)
        XCTAssertEqual(PasswordStrength.evaluate("aaaaaaaaaaaaaaaa").score, 1)
        XCTAssertEqual(PasswordStrength.evaluate("Ty7!kP3q#Wm9").score, 3)
        XCTAssertEqual(PasswordStrength.evaluate("vK7#qP2m!xR9-tLw4zN8").score, 4)
    }

    func testGeneratorRespectsOptions() {
        let plain = PasswordGenerator.generate(GeneratorOptions(length: 32, digits: false, symbols: false))
        XCTAssertEqual(plain.count, 32)
        XCTAssertTrue(plain.allSatisfy(\.isLetter))

        let full = PasswordGenerator.generate(GeneratorOptions(length: 12))
        XCTAssertEqual(full.count, 12)
        XCTAssertTrue(full.contains(where: \.isNumber))
        XCTAssertTrue(full.contains { "!#$%&*+-=?@^_".contains($0) })

        let phrase = PasswordGenerator.generate(GeneratorOptions(length: 20, words: true))
        XCTAssertEqual(phrase.split(separator: "-").count, 5)
    }

    func testReuseCountsIgnoreTrashAndTokens() {
        var a = Entry(title: "A"); a.secret = "same"
        var b = Entry(title: "B"); b.secret = "same"
        var c = Entry(title: "C"); c.secret = "same"; c.deletedAt = Date()
        var d = Entry(title: "D"); d.secret = "same"; d.authKind = .token
        XCTAssertEqual(PasswordAudit.reuseCounts([a, b, c, d])["same"], 2)
    }
}

final class SearchTests: XCTestCase {
    func testMatchesAllTokensAndRanksTitlePrefix() {
        var admin = Entry(title: "Админка"); admin.environment = "Production"
        var github = Entry(title: "GitHub"); github.login = "you@example.com"
        let other = Entry(title: "My GitLab")
        let result = EntrySearch.search([admin, github, other], query: "git")
        XCTAssertEqual(result.map(\.title), ["GitHub", "My GitLab"])
        XCTAssertEqual(EntrySearch.search([admin, github], query: "адм prod").map(\.title), ["Админка"])
        XCTAssertEqual(EntrySearch.search([admin], query: "биллинг", context: { _ in "Работа Биллинг" }).count, 1)
    }

    func testWrongKeyboardLayout() {
        let github = Entry(title: "GitHub")
        XCTAssertEqual(EntrySearch.search([github], query: "пшерги").map(\.title), ["GitHub"])
    }
}

final class CSVTests: XCTestCase {
    func testSafariExportWithQuotesAndOTP() {
        let csv = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\n"
            + "github.com (you),https://github.com/,you@example.com,\"p,a\"\"ss\",\"line1\nline2\",otpauth://totp/GitHub:you?secret=JBSWY3DPEHPK3PXP\r\n"
            + ",,,,,\r\n"
            + "Router,http://192.168.1.1,admin,admin123,,\r\n"
        let entries = CSVImport.entries(from: csv, space: .personal)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "github.com (you)")
        XCTAssertEqual(entries[0].secret, "p,a\"ss")
        XCTAssertEqual(entries[0].notes, "line1\nline2")
        XCTAssertEqual(entries[0].loginKind, .email)
        XCTAssertEqual(entries[0].totp?.issuer, "GitHub")
        XCTAssertEqual(entries[1].loginKind, .username)
        XCTAssertNil(entries[1].totp)
    }

    func testBitwardenColumnsAndTitleFallback() {
        let csv = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
            + ",,login,,,,0,https://figma.com,+7 900 000-00-00,pw,JBSWY3DPEHPK3PXP\n"
        let entry = CSVImport.entries(from: csv, space: .work)[0]
        XCTAssertEqual(entry.title, "figma.com")
        XCTAssertEqual(entry.loginKind, .phone)
        XCTAssertEqual(entry.space, .work)
        XCTAssertNotNil(entry.totp)
    }
}

final class ReminderTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testWindowInsideMonth() {
        var r = Reminder(task: "Передать показания", dayFrom: 20, dayTo: 25)
        XCTAssertFalse(r.isDue(at: date(2026, 9, 19), calendar: calendar))
        XCTAssertTrue(r.isDue(at: date(2026, 9, 20), calendar: calendar))
        XCTAssertTrue(r.isDue(at: date(2026, 9, 25), calendar: calendar))
        XCTAssertFalse(r.isDue(at: date(2026, 9, 26), calendar: calendar))

        r.lastDoneAt = date(2026, 9, 21)
        XCTAssertFalse(r.isDue(at: date(2026, 9, 23), calendar: calendar))
        XCTAssertTrue(r.isDue(at: date(2026, 10, 21), calendar: calendar))
    }

    func testWindowAcrossMonthEnd() {
        var r = Reminder(task: "Оплатить", dayFrom: 28, dayTo: 5)
        XCTAssertTrue(r.isDue(at: date(2026, 2, 28), calendar: calendar))
        XCTAssertTrue(r.isDue(at: date(2026, 3, 3), calendar: calendar))
        XCTAssertFalse(r.isDue(at: date(2026, 3, 10), calendar: calendar))
        r.lastDoneAt = date(2026, 3, 1)
        XCTAssertFalse(r.isDue(at: date(2026, 3, 4), calendar: calendar))
    }
}
