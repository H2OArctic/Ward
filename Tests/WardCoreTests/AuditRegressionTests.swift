import XCTest
import CryptoKit
@testable import WardCore

final class AuditRegressionTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for dir in directories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        directories = []
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ward-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        return dir
    }

    private func makeSession(_ storage: MemoryStorage, backups: BackupStore?, password: String) throws -> (VaultSession, SymmetricKey) {
        let session = VaultSession(storage: storage, backups: backups)
        let key = VaultCrypto.newVaultKey()
        try session.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: password, iterations: 1000))
        return (session, key)
    }

    private func reopen(_ storage: MemoryStorage, password: String) throws -> VaultSession {
        let session = VaultSession(storage: storage, backups: nil)
        try session.unlock(key: VaultCrypto.openSlot(XCTUnwrap(session.slot), password: password))
        return session
    }

    // MARK: - Сбой копии не расходит память и связку ключей

    func testBackupFailureKeepsSavedChange() throws {
        let dir = try makeDirectory()
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage, backups: BackupStore(directory: dir, keep: { 0 }), password: "old-password")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        var entry = Entry(title: "A")
        entry.secret = "x"
        XCTAssertNoThrow(try session.update { $0.upsert(entry) }, "изменение в связке — значит сохранено")
        XCTAssertNotNil(session.backupError)
        XCTAssertEqual(session.vault.entries.count, 1, "память не должна отстать от связки ключей")
        XCTAssertEqual(try reopen(storage, password: "old-password").vault.entries.count, 1)

        try session.update { $0.upsert(Entry(title: "B")) }
        XCTAssertEqual(try reopen(storage, password: "old-password").vault.entries.map(\.title), ["A", "B"],
                       "следующее изменение не должно затереть предыдущее")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try session.update { $0.upsert(Entry(title: "C")) }
        XCTAssertNil(session.backupError, "после починки диска предупреждение уходит")
    }

    func testPasswordChangeWithFailingBackupReportsSuccess() throws {
        let dir = try makeDirectory()
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage, backups: BackupStore(directory: dir, keep: { 0 }), password: "old-password")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        let newKey = VaultCrypto.newVaultKey()
        XCTAssertNoThrow(try session.rekey(key: newKey, slot: VaultCrypto.makeSlot(for: newKey, password: "new-password", iterations: 1000)))
        XCTAssertNoThrow(try reopen(storage, password: "new-password"))
        XCTAssertThrowsError(try reopen(storage, password: "old-password"))
    }

    // MARK: - Порядок и чистка копий

    func testBackupsInSameMillisecondKeepOrder() throws {
        let dir = try makeDirectory()
        let store = BackupStore(directory: dir, keep: { 0 })
        let now = Date()
        for i in 0...11 { try store.write(Data("\(i)".utf8), now: now) }
        let newest = try XCTUnwrap(store.all().first)
        XCTAssertEqual(String(decoding: try Data(contentsOf: newest), as: UTF8.self), "11", "«-11» новее «-2» и «без суффикса»")
        XCTAssertEqual(store.all().map { String(decoding: try! Data(contentsOf: $0), as: UTF8.self) },
                       (0...11).reversed().map(String.init))
    }

    func testPruneKeepsNewestAndForeignFiles() throws {
        let dir = try makeDirectory()
        let store = BackupStore(directory: dir, keep: { 2 })
        let manual = dir.appendingPathComponent("Ward 26 сентября 2026.wardbackup")
        try Data("manual".utf8).write(to: manual)
        let now = Date()
        try store.write(Data("1".utf8), now: now)
        try store.write(Data("2".utf8), now: now)
        try store.write(Data("3".utf8), now: now.addingTimeInterval(1))

        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path), "ручной экспорт в той же папке не удаляется")
        XCTAssertEqual(store.all().map { String(decoding: try! Data(contentsOf: $0), as: UTF8.self) }, ["3", "2"])
    }

    func testBackupFilesArePrivateFromTheStart() throws {
        let dir = try makeDirectory().appendingPathComponent("nested/Backups")
        let store = BackupStore(directory: dir, keep: { 0 })
        try store.write(Data("x".utf8))
        let file = try XCTUnwrap(store.all().first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testWritePrivateReplacesExistingFile() throws {
        let url = try makeDirectory().appendingPathComponent("export.wardbackup")
        try Data("old".utf8).write(to: url)
        try BackupStore.writePrivate(Data("new".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Вывод ключа

    func testNulDoesNotTruncatePassword() throws {
        let salt = Data(repeating: 7, count: 16)
        let full = try VaultCrypto.deriveKey(password: "abc\u{0}XYZ", salt: salt, iterations: 10)
        let cut = try VaultCrypto.deriveKey(password: "abc", salt: salt, iterations: 10)
        XCTAssertNotEqual(full, cut)
    }

    func testUntrustedSlotParametersAreRejected() throws {
        let key = VaultCrypto.newVaultKey()
        var slot = try VaultCrypto.makeSlot(for: key, password: "пароль", iterations: 1000)
        XCTAssertEqual(slot.kdf, "pbkdf2-sha256")

        var huge = slot
        huge.iterations = .max
        XCTAssertThrowsError(try VaultCrypto.openSlot(huge, password: "пароль"), "4 млрд итераций не считаем — это зависание")

        slot.kdf = "argon2id"
        XCTAssertThrowsError(try VaultCrypto.openSlot(slot, password: "пароль")) {
            XCTAssertEqual($0 as? VaultCryptoError, .unsupportedKDF("argon2id"))
        }
    }

    // MARK: - Модель

    func testEnvironmentRenameMovesEntries() {
        var project = Project(name: "Биллинг", space: .work, environments: ["Stage", "Production"])
        var vault = Vault(projects: [project])
        for env in ["Stage", "Production", "Stage"] {
            var e = Entry(title: env, space: .work)
            e.projectID = project.id
            e.environment = env
            vault.entries.append(e)
        }
        var other = Entry(title: "Чужой", space: .work)
        other.environment = "Stage"
        vault.entries.append(other)

        project.environments = ["Test", "Prod"]
        vault.upsert(project, renamingEnvironments: ["Stage": "Test", "Production": "Prod"])
        XCTAssertEqual(vault.entries.map(\.environment), ["Test", "Prod", "Test", "Stage"], "записи других проектов не трогаются")
        XCTAssertEqual(vault.projects.first?.environments, ["Test", "Prod"])
    }

    func testCSVImportSkipsDuplicates() {
        let csv = "Title,URL,Username,Password\nA,https://a.com,u,p\nA2,https://a.com,u,p\nB,https://b.com,u,p\n"
        var vault = Vault()
        let first = vault.importEntries(CSVImport.entries(from: csv, space: .personal))
        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(first.duplicates, 1, "дубль внутри файла")
        let second = vault.importEntries(CSVImport.entries(from: csv, space: .personal))
        XCTAssertEqual(second.added, 0, "повторный импорт того же файла ничего не удваивает")
        XCTAssertEqual(vault.entries.count, 2)
    }

    func testSecuritySettingsLiveInVaultAndOldVaultsStillOpen() throws {
        let fixture = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vault-v1", withExtension: "json",
                                                                       subdirectory: "Fixtures")))
        let old = try reopen(MemoryStorage(fixture), password: CompatibilityTests.fixturePassword)
        XCTAssertNil(old.vault.security, "у старого хранилища настроек нет — возьмутся из UserDefaults")

        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage, backups: nil, password: "new-vault-password")
        var settings = SecuritySettings()
        settings.autoLockMinutes = 1
        settings.concealClipboard = false
        try session.update { $0.security = settings }
        XCTAssertEqual(try reopen(storage, password: "new-vault-password").vault.security, settings)

        let partial = try JSONDecoder().decode(SecuritySettings.self, from: Data(#"{"autoLockMinutes":15}"#.utf8))
        XCTAssertEqual(partial.autoLockMinutes, 15)
        XCTAssertTrue(partial.lockOnSleep, "незнакомые поля получают безопасные значения по умолчанию")
    }

    func testOTPAuthRejectsTooShortSecret() {
        XCTAssertNil(OTPAuthURI.parse("otpauth://totp/x?secret=AA"))
        XCTAssertNotNil(OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"))
    }

    // MARK: - Политика паролей и сверка сайта

    func testMasterPasswordPolicy() {
        XCTAssertNotNil(MasterPasswordPolicy.problem("12345678"))
        XCTAssertNotNil(MasterPasswordPolicy.problem("qwertyuiop12"), "шаблон с клавиатуры")
        XCTAssertNotNil(MasterPasswordPolicy.problem("aaaaaaaaaaaaaaaa"))
        XCTAssertNil(MasterPasswordPolicy.problem("корова-лампа-окно-7"))
        XCTAssertNil(MasterPasswordPolicy.problem("Vk7#qP2m!xR9tL"))
    }

    func testSiteMatch() {
        XCTAssertTrue(SiteMatch.matches(pageHost: "github.com", entryHost: "github.com"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "www.github.com", entryHost: "github.com"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "login.example.com", entryHost: "admin.example.com"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "a.bank.co.uk", entryHost: "bank.co.uk"))
        XCTAssertTrue(SiteMatch.matches(pageHost: "192.168.1.1", entryHost: "192.168.1.1"))

        XCTAssertFalse(SiteMatch.matches(pageHost: "github.com.evil.io", entryHost: "github.com"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "evilgithub.com", entryHost: "github.com"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "other.co.uk", entryHost: "bank.co.uk"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "192.168.1.2", entryHost: "192.168.1.1"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "localhost", entryHost: "example.com"))

        XCTAssertFalse(SiteMatch.matches(pageHost: "attacker.github.io", entryHost: "victim.github.io"), "общий хостинг")
        XCTAssertFalse(SiteMatch.matches(pageHost: "docs.victim.github.io", entryHost: "victim.github.io"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "evil.up.railway.app", entryHost: "good.up.railway.app"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "github.io", entryHost: "victim.github.io"))
    }

    func testCSVKeepsPasswordSpaces() {
        let csv = "name,url,username,password\nA,https://a.com, u ,\" p a s s \"\n"
        let entry = CSVImport.entries(from: csv, space: .personal).first
        XCTAssertEqual(entry?.secret, " p a s s ")
        XCTAssertEqual(entry?.login, "u")
    }

    func testMergingEnvironmentsByRenameMovesEntries() {
        var project = Project(name: "P", space: .work, environments: ["Prod", "Production"])
        var vault = Vault(projects: [project])
        var e = Entry(title: "x", space: .work)
        e.projectID = project.id
        e.environment = "Production"
        vault.entries.append(e)
        project.environments = ["Prod"]
        vault.upsert(project, renamingEnvironments: ["Production": "Prod"])
        XCTAssertEqual(vault.entries.first?.environment, "Prod")
    }
}
