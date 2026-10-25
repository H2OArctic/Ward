import XCTest
import CryptoKit
@testable import WardCore

/// Хранилище в памяти с поломками по заказу — чтобы проверить, что сбой записи не теряет и не портит данные.
final class MemoryStorage: VaultStorage {
    var data: Data?
    var failReads = false
    var failUpdates = false
    private(set) var writes = 0

    struct Broken: Error {}

    init(_ data: Data? = nil) { self.data = data }

    func read() throws -> Data? {
        if failReads { throw Broken() }
        return data
    }

    func create(_ data: Data) throws {
        guard self.data == nil else { throw KeychainStorage.Failure(status: errSecDuplicateItem) }
        self.data = data
        writes += 1
    }

    func update(_ data: Data) throws {
        if failUpdates { throw Broken() }
        self.data = data
        writes += 1
    }
}

private let fastIterations: UInt32 = 1000

private func makeSession(_ storage: MemoryStorage, backups: BackupStore? = nil, password: String = "мастер-пароль")
    throws -> (VaultSession, SymmetricKey) {
    let session = VaultSession(storage: storage, backups: backups)
    let key = VaultCrypto.newVaultKey()
    try session.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: password, iterations: fastIterations))
    return (session, key)
}

private func reopen(_ storage: VaultStorage, password: String) throws -> VaultSession {
    let session = VaultSession(storage: storage, backups: nil)
    let key = try VaultCrypto.openSlot(XCTUnwrap(session.slot), password: password)
    try session.unlock(key: key)
    return session
}

private func sampleEntry(_ title: String = "GitHub", secret: String = "s3cret") -> Entry {
    var entry = Entry(title: title)
    entry.login = "you@example.com"
    entry.secret = secret
    entry.totp = TOTPConfig(secret: Data("12345678901234567890".utf8))
    return entry
}

final class VaultSessionTests: XCTestCase {
    func testFullLifecycleSurvivesRestart() throws {
        let storage = MemoryStorage()
        XCTAssertEqual(VaultSession(storage: storage, backups: nil).state, .needsSetup)

        let (session, _) = try makeSession(storage)
        try session.update { $0.upsert(sampleEntry()) }
        session.lock()
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.vault.entries.isEmpty, "после блокировки данных в памяти быть не должно")

        let restarted = try reopen(storage, password: "мастер-пароль")
        XCTAssertEqual(restarted.state, .unlocked)
        XCTAssertEqual(restarted.vault.entries.map(\.secret), ["s3cret"])
        XCTAssertNotNil(restarted.vault.entries.first?.totp)
    }

    func testStoredDataIsEncrypted() throws {
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage)
        try session.update { $0.upsert(sampleEntry(secret: "очень-секретный-пароль")) }
        let raw = String(decoding: try XCTUnwrap(storage.data), as: UTF8.self)
        XCTAssertFalse(raw.contains("очень-секретный-пароль"))
        XCTAssertFalse(raw.contains("GitHub"))
        XCTAssertFalse(raw.contains("you@example.com"))
    }

    func testCreateNeverOverwritesExistingVault() throws {
        let storage = MemoryStorage()
        _ = try makeSession(storage)
        let original = storage.data

        let second = VaultSession(storage: storage, backups: nil)
        XCTAssertEqual(second.state, .locked)
        let key = VaultCrypto.newVaultKey()
        XCTAssertThrowsError(try second.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: "x", iterations: fastIterations)))
        XCTAssertEqual(storage.data, original)
    }

    func testUnreadableStorageBlocksSetup() throws {
        let failing = MemoryStorage()
        failing.failReads = true
        let session = VaultSession(storage: failing, backups: nil)
        guard case .unavailable = session.state else { return XCTFail("ожидали .unavailable, а не \(session.state)") }
        let key = VaultCrypto.newVaultKey()
        XCTAssertThrowsError(try session.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: "x", iterations: fastIterations)))

        let garbage = MemoryStorage(Data("не json".utf8))
        guard case .unavailable = VaultSession(storage: garbage, backups: nil).state else { return XCTFail() }
        XCTAssertEqual(garbage.data, Data("не json".utf8), "испорченные данные нельзя затирать")
    }

    func testFailedWriteChangesNothing() throws {
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage)
        try session.update { $0.upsert(sampleEntry("Первая")) }
        let before = storage.data

        storage.failUpdates = true
        XCTAssertThrowsError(try session.update { $0.upsert(sampleEntry("Вторая")) })
        XCTAssertEqual(session.vault.entries.map(\.title), ["Первая"], "память не должна уйти вперёд диска")
        XCTAssertEqual(storage.data, before)

        storage.failUpdates = false
        try session.update { $0.upsert(sampleEntry("Вторая")) }
        XCTAssertEqual(try reopen(storage, password: "мастер-пароль").vault.entries.count, 2)
    }

    func testWrongPasswordAndTampering() throws {
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage)
        try session.update { $0.upsert(sampleEntry()) }

        let locked = VaultSession(storage: storage, backups: nil)
        XCTAssertThrowsError(try VaultCrypto.openSlot(XCTUnwrap(locked.slot), password: "мастер-парол")) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassword)
        }
        XCTAssertEqual(locked.state, .locked)

        var envelope = try JSONDecoder().decode(VaultEnvelope.self, from: XCTUnwrap(storage.data))
        envelope.payload[envelope.payload.count / 2] ^= 0x01
        let tampered = MemoryStorage(try JSONEncoder().encode(envelope))
        let victim = VaultSession(storage: tampered, backups: nil)
        let key = try VaultCrypto.openSlot(XCTUnwrap(victim.slot), password: "мастер-пароль")
        XCTAssertThrowsError(try victim.unlock(key: key)) { XCTAssertEqual($0 as? VaultCryptoError, .corrupted) }
        XCTAssertEqual(victim.state, .locked)

        var badSlot = try JSONDecoder().decode(VaultEnvelope.self, from: XCTUnwrap(storage.data))
        badSlot.slot.wrappedKey[0] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.openSlot(badSlot.slot, password: "мастер-пароль")) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassword)
        }
    }

    func testChangePassword() throws {
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage)
        try session.update { $0.upsert(sampleEntry()) }
        let newKey = VaultCrypto.newVaultKey()
        try session.rekey(key: newKey, slot: VaultCrypto.makeSlot(for: newKey, password: "новый пароль", iterations: fastIterations))

        XCTAssertEqual(try reopen(storage, password: "новый пароль").vault.entries.count, 1)
        XCTAssertThrowsError(try reopen(storage, password: "мастер-пароль"))
    }

    func testLockedSessionRejectsChanges() throws {
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage)
        session.lock()
        let writes = storage.writes
        XCTAssertThrowsError(try session.update { $0.upsert(sampleEntry()) })
        XCTAssertThrowsError(try session.exportData())
        XCTAssertEqual(storage.writes, writes)
    }

    func testBackupsAreWrittenPrunedAndOpenable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ward-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var keep = 0
        let backups = BackupStore(directory: dir, keep: { keep })
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage, backups: backups)

        for i in 1...3 { try session.update { $0.upsert(sampleEntry("Запись \(i)")) } }
        try session.update(backup: false) { $0.entries[0].useCount += 1 }
        XCTAssertEqual(backups.all().count, 3, "использование записи не должно плодить копии")

        let newest = try XCTUnwrap(backups.all().first)
        let attributes = try FileManager.default.attributesOfItem(atPath: newest.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let restored = try reopen(MemoryStorage(Data(contentsOf: newest)), password: "мастер-пароль")
        XCTAssertEqual(restored.vault.entries.count, 3)

        keep = 2
        try session.update { $0.upsert(sampleEntry("Запись 4")) }
        XCTAssertEqual(backups.all().count, 2)
    }

    func testExportedBackupMergesOnce() throws {
        let (source, _) = try makeSession(MemoryStorage())
        try source.update {
            $0.upsert(Project(name: "Биллинг", space: .work, environments: ["Stage", "Production"]))
            $0.upsert(sampleEntry("A"))
            $0.upsert(sampleEntry("B"))
        }
        let exported = try JSONDecoder().decode(VaultEnvelope.self, from: source.exportData())
        let incoming = try VaultCrypto.decode(exported, key: VaultCrypto.openSlot(exported.slot, password: "мастер-пароль"))

        var target = Vault(entries: [sampleEntry("Своя")])
        XCTAssertEqual(target.merge(incoming), 2)
        XCTAssertEqual(target.merge(incoming), 0, "повторное восстановление не должно дублировать")
        XCTAssertEqual(target.entries.count, 3)
        XCTAssertEqual(target.projects.count, 1)
    }

    func testNewerFormatsAreRefusedNotMisread() throws {
        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: "p", iterations: fastIterations)
        var envelope = try VaultCrypto.encode(Vault(), key: key, slot: slot)
        envelope.format = 99
        XCTAssertThrowsError(try VaultCrypto.decode(envelope, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .unsupportedFormat(99))
        }

        var future = Vault()
        future.format = 7
        let inner = try VaultCrypto.encode(future, key: key, slot: slot)
        XCTAssertThrowsError(try VaultCrypto.decode(inner, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .unsupportedFormat(7))
        }
    }
}

final class VaultMutationTests: XCTestCase {
    func testPasswordHistory() {
        var vault = Vault()
        var entry = sampleEntry(secret: "")
        vault.upsert(entry)
        entry.secret = "first"
        vault.upsert(entry)
        XCTAssertTrue(vault.entries[0].history.isEmpty, "пустой пароль в историю не пишется")

        entry = vault.entries[0]
        entry.notes = "без смены пароля"
        vault.upsert(entry)
        XCTAssertTrue(vault.entries[0].history.isEmpty)

        entry = vault.entries[0]
        entry.secret = "second"
        vault.upsert(entry)
        XCTAssertEqual(vault.entries[0].history.map(\.value), ["first"])
        XCTAssertEqual(vault.entries.count, 1)
    }

    func testRemovingProjectKeepsEntries() {
        let project = Project(name: "Биллинг", space: .work, environments: ["Production"])
        var entry = sampleEntry()
        entry.projectID = project.id
        entry.environment = "Production"
        var vault = Vault(projects: [project], entries: [entry])
        vault.removeProject(project.id)
        XCTAssertTrue(vault.projects.isEmpty)
        XCTAssertEqual(vault.entries.count, 1)
        XCTAssertNil(vault.entries[0].projectID)
        XCTAssertNil(vault.entries[0].environment)
    }
}

final class CryptoEdgeTests: XCTestCase {
    func testUnicodeNormalizationGivesSameKey() throws {
        let salt = Data(repeating: 7, count: 16)
        let composed = "пароль-йё"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let a = try VaultCrypto.deriveKey(password: composed, salt: salt, iterations: 1000)
        let b = try VaultCrypto.deriveKey(password: decomposed, salt: salt, iterations: 1000)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testUnusualPasswordsRoundTrip() throws {
        for password in ["🔑 ключ 🗝️", String(repeating: "очень длинный ", count: 200), "a", "\t tabs and  spaces "] {
            let key = VaultCrypto.newVaultKey()
            let slot = try VaultCrypto.makeSlot(for: key, password: password, iterations: fastIterations)
            let opened = try VaultCrypto.openSlot(slot, password: password)
            XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        }
    }

    func testSaltsAndNoncesAreFresh() throws {
        let key = VaultCrypto.newVaultKey()
        let a = try VaultCrypto.makeSlot(for: key, password: "same", iterations: fastIterations)
        let b = try VaultCrypto.makeSlot(for: key, password: "same", iterations: fastIterations)
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.wrappedKey, b.wrappedKey)
        XCTAssertNotEqual(try VaultCrypto.seal(Data("x".utf8), key: key), try VaultCrypto.seal(Data("x".utf8), key: key))
    }

    func testDefaultIterationsStayStrong() {
        XCTAssertGreaterThanOrEqual(VaultCrypto.defaultIterations, 600_000)
    }
}

/// Хранилище, сохранённое версией 0.1. Если тест упал — новая версия не откроет существующие данные пользователя.
final class CompatibilityTests: XCTestCase {
    static let fixturePassword = "Ward-fixture-пароль-1"

    func testOpensVaultFromVersion01() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vault-v1", withExtension: "json", subdirectory: "Fixtures"))
        let session = try reopen(MemoryStorage(Data(contentsOf: url)), password: Self.fixturePassword)
        let vault = session.vault
        XCTAssertEqual(vault.projects.map(\.name), ["Биллинг"])
        XCTAssertEqual(vault.projects.first?.environments, ["Stage", "Production"])
        let admin = try XCTUnwrap(vault.entries.first { $0.title == "Админка" })
        XCTAssertEqual(admin.secret, "vK7#qP2m!xR9-tLw4zN8")
        XCTAssertEqual(admin.environment, "Production")
        XCTAssertEqual(admin.preSteps, [.text("VPN «Офис»"), .text("Basic auth")])
        XCTAssertEqual(admin.history.map(\.value), ["old-password"])
        XCTAssertEqual(admin.totp.map { TOTP.code($0, at: Date(timeIntervalSince1970: 59)) }, "287082")
        let meters = try XCTUnwrap(vault.entries.first { $0.title == "Мосэнергосбыт" })
        XCTAssertEqual(meters.reminder?.task, "Передать показания")
        XCTAssertEqual(meters.loginKind, .phone)
        XCTAssertEqual(vault.entries.first { $0.title == "API" }?.authKind, .token)
    }

    /// Пересоздать эталон: `WARD_WRITE_FIXTURE=1 swift test --filter CompatibilityTests`.
    /// Делать это только при осознанной смене формата — вместе с кодом миграции.
    func testWriteFixture() throws {
        guard ProcessInfo.processInfo.environment["WARD_WRITE_FIXTURE"] == "1" else { throw XCTSkip("эталон не перезаписываем") }
        let project = Project(name: "Биллинг", space: .work, environments: ["Stage", "Production"])
        var admin = Entry(title: "Админка", space: .work)
        admin.projectID = project.id
        admin.environment = "Production"
        admin.login = "you@company.example"
        admin.secret = "vK7#qP2m!xR9-tLw4zN8"
        admin.preSteps = [.text("VPN «Офис»"), .text("Basic auth")]
        admin.history = [PasswordChange(value: "old-password", changedAt: Date(timeIntervalSince1970: 1_750_000_000))]
        admin.totp = TOTPConfig(secret: Data("12345678901234567890".utf8), issuer: "Billing", account: "you@company.example")
        var meters = Entry(title: "Мосэнергосбыт")
        meters.login = "+7 900 000-00-00"
        meters.loginKind = .phone
        meters.reminder = Reminder(task: "Передать показания", dayFrom: 20, dayTo: 25)
        var api = Entry(title: "API", space: .work)
        api.authKind = .token
        api.secret = "sk_live_123"

        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: Self.fixturePassword, iterations: fastIterations)
        let envelope = try VaultCrypto.encode(Vault(projects: [project], entries: [admin, meters, api]), key: key, slot: slot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/vault-v1.json")
        try encoder.encode(envelope).write(to: path)
    }
}

final class TOTPReferenceTests: XCTestCase {
    private struct Vector: Decodable {
        let secret: String
        let algorithm: String
        let digits: Int
        let period: Int
        let time: TimeInterval
        let code: String
    }

    /// 120 случайных векторов, посчитанных независимо (Python, стандартный hmac).
    func testMatchesIndependentImplementation() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "totp-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 120)
        for v in vectors {
            let config = TOTPConfig(secret: try XCTUnwrap(Base32.decode(v.secret)),
                                    algorithm: try XCTUnwrap(OTPAlgorithm(rawValue: v.algorithm)),
                                    digits: v.digits, period: v.period)
            XCTAssertEqual(TOTP.code(config, at: Date(timeIntervalSince1970: v.time)), v.code,
                           "\(v.algorithm) \(v.digits) цифр, период \(v.period), t=\(v.time)")
        }
    }

    func testBase32RoundTripAllLengths() {
        for length in 1...64 {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            XCTAssertEqual(Base32.decode(Base32.encode(data)), data, "длина \(length)")
            XCTAssertEqual(Base32.decode(Base32.encode(data).lowercased()), data)
        }
    }

    func testOTPAuthVariants() throws {
        let spaced = try XCTUnwrap(OTPAuthURI.parse("otpauth://totp/My%20Bank:ivan?secret=JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(spaced.issuer, "My Bank")
        XCTAssertEqual(spaced.account, "ivan")

        let overridden = try XCTUnwrap(OTPAuthURI.parse("otpauth://totp/Old:ivan?secret=JBSWY3DPEHPK3PXP&issuer=New"))
        XCTAssertEqual(overridden.issuer, "New")

        let bare = try XCTUnwrap(OTPAuthURI.parse("otpauth://totp/ivan?secret=JBSWY3DPEHPK3PXP&algorithm=sha512&digits=9&period=-5"))
        XCTAssertNil(bare.issuer)
        XCTAssertEqual(bare.account, "ivan")
        XCTAssertEqual(bare.algorithm, .sha512)
        XCTAssertEqual(bare.digits, 6)
        XCTAssertEqual(bare.period, 30)

        XCTAssertNil(TOTPConfig.parse("otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8"))
        XCTAssertNil(OTPAuthURI.parse("otpauth://totp/x?issuer=NoSecret"))
        XCTAssertNil(TOTPConfig.parse("AB"), "слишком короткий ключ — скорее опечатка")
    }

    func testRemainingSecondsAtBoundaries() {
        for t in stride(from: 0, through: 120, by: 1) {
            let left = TOTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: TimeInterval(t)))
            XCTAssertTrue((1...30).contains(left))
            XCTAssertEqual(left, 30 - t % 30)
        }
    }
}

final class ImportAndReminderEdgeTests: XCTestCase {
    func testSemicolonCSVFromRussianExcel() {
        let csv = "name;url;username;password\nПочта;mail.example;ivan;\"pa;ss\"\n"
        let entries = CSVImport.entries(from: csv, space: .personal)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Почта")
        XCTAssertEqual(entries.first?.secret, "pa;ss")
    }

    func testMalformedCSVDoesNotCrash() {
        let broken = ["", "\"", "title,password\n\"unterminated,x", ",,,,\n,,,", "\u{FEFF}", String(repeating: "\"\"", count: 1000)]
        for text in broken { _ = CSVImport.entries(from: text, space: .personal) }
        for _ in 0..<200 {
            let noise = String((0..<Int.random(in: 0...300)).map { _ in
                Character(UnicodeScalar(UInt8.random(in: 0...127)))
            })
            _ = CSVImport.entries(from: "title,url,username,password\n" + noise, space: .work)
        }
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testLastDayOfShortMonths() {
        let r = Reminder(task: "Оплатить", dayFrom: 31, dayTo: 31)
        XCTAssertTrue(r.isDue(at: date(2026, 2, 28), calendar: calendar))
        XCTAssertTrue(r.isDue(at: date(2028, 2, 29), calendar: calendar))
        XCTAssertFalse(r.isDue(at: date(2028, 2, 28), calendar: calendar))
        XCTAssertTrue(r.isDue(at: date(2026, 4, 30), calendar: calendar))
        XCTAssertTrue(r.isDue(at: date(2026, 5, 31), calendar: calendar))
    }

    func testDoneLastMonthDoesNotHideThisMonth() {
        var r = Reminder(task: "Показания", dayFrom: 20, dayTo: 25)
        r.lastDoneAt = date(2026, 8, 24)
        XCTAssertTrue(r.isDue(at: date(2026, 9, 20), calendar: calendar))
        r.lastDoneAt = date(2026, 9, 19)
        XCTAssertTrue(r.isDue(at: date(2026, 9, 20), calendar: calendar), "сделано до начала окна — не считается")
    }
}

final class GeneratorPropertyTests: XCTestCase {
    func testManySamples() {
        let ambiguous = Set("0O1lI")
        var seen = Set<String>()
        for length in [8, 12, 20, 32, 64] {
            for _ in 0..<200 {
                let p = PasswordGenerator.generate(GeneratorOptions(length: length))
                XCTAssertEqual(p.count, length)
                XCTAssertTrue(p.contains(where: \.isLowercase))
                XCTAssertTrue(p.contains(where: \.isUppercase))
                XCTAssertTrue(p.contains(where: \.isNumber))
                XCTAssertTrue(p.contains { "!#$%&*+-=?@^_".contains($0) })
                XCTAssertTrue(Set(p).isDisjoint(with: ambiguous))
                seen.insert(p)
            }
        }
        XCTAssertEqual(seen.count, 1000, "повторы — признак сломанного генератора случайных чисел")

        for _ in 0..<100 {
            let phrase = PasswordGenerator.generate(GeneratorOptions(length: 40, digits: false, symbols: false, words: true))
            XCTAssertEqual(phrase.split(separator: ".").count, 8)
            XCTAssertGreaterThanOrEqual(PasswordStrength.evaluate(phrase).score, 3)
        }
    }

    func testGeneratedPasswordsRateStrong() {
        for _ in 0..<100 {
            XCTAssertEqual(PasswordStrength.evaluate(PasswordGenerator.generate(GeneratorOptions(length: 20))).score, 4)
        }
    }
}

final class SearchEdgeTests: XCTestCase {
    func testLayoutSwapIsSymmetric() {
        let en = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`"
        XCTAssertEqual(KeyboardLayout.swap(KeyboardLayout.swap(en)), en)
        XCTAssertEqual(EntrySearch.search([Entry(title: "Госуслуги")], query: "ujcecke").map(\.title), ["Госуслуги"])
    }

    func testTokenOrderAndEmptyQuery() {
        var admin = Entry(title: "Админка")
        admin.environment = "Production"
        XCTAssertEqual(EntrySearch.search([admin], query: "prod адм").count, 1)
        XCTAssertEqual(EntrySearch.search([admin, Entry(title: "B")], query: "   ").count, 2)
        XCTAssertTrue(EntrySearch.search([admin], query: "[]().*+?").isEmpty)
    }
}

/// Настоящая связка ключей, отдельный сервис; после теста запись удаляется.
final class KeychainIntegrationTests: XCTestCase {
    func testCreateReadUpdateDelete() throws {
        let storage = KeychainStorage(service: "local.ward.tests.\(UUID().uuidString)", account: "vault")
        defer { try? storage.delete() }
        XCTAssertNil(try storage.read())
        try storage.create(Data("one".utf8))
        XCTAssertEqual(try storage.read(), Data("one".utf8))
        XCTAssertThrowsError(try storage.create(Data("two".utf8))) {
            XCTAssertEqual(($0 as? KeychainStorage.Failure)?.status, errSecDuplicateItem)
        }
        try storage.update(Data("three".utf8))
        XCTAssertEqual(try storage.read(), Data("three".utf8))
        try storage.delete()
        XCTAssertNil(try storage.read())
    }

    func testSessionOnRealKeychain() throws {
        let storage = KeychainStorage(service: "local.ward.tests.\(UUID().uuidString)", account: "vault")
        defer { try? storage.delete() }
        let session = VaultSession(storage: storage, backups: nil)
        let key = VaultCrypto.newVaultKey()
        try session.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: "p", iterations: fastIterations))
        try session.update { $0.upsert(sampleEntry()) }
        XCTAssertEqual(try reopen(storage, password: "p").vault.entries.first?.secret, "s3cret")
    }
}
