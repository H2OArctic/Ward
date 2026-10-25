import XCTest
import CryptoKit
@testable import WardCore

/// Регрессии аудита надёжности: недоверенный ввод не роняет приложение.
final class HardeningTests: XCTestCase {
    func testPuTTYHugeLineCountDoesNotOverflow() {
        let text = "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nPublic-Lines: \(Int.max)\nAAAA\n"
        XCTAssertEqual(SSHKeyParser.privateKey(text)?.format, "PuTTY")
    }

    func testProtobufWithManyFixedFieldsDoesNotExhaustStack() {
        // 400 тысяч полей fixed32 подряд: рекурсивный разбор переполнял стек.
        let field: [UInt8] = [0x0D, 0, 0, 0, 0]
        var reader = ProtoReader(Array([[UInt8]](repeating: field, count: 400_000).joined()) + [0x08, 0x2A])
        let last = reader.next()
        XCTAssertEqual(last?.number, 1)
        if case .varint(let value)? = last?.value { XCTAssertEqual(value, 42) } else { XCTFail("нет поля") }
        XCTAssertNil(reader.next())
    }

    func testAddressCannotSmuggleSSHOptions() {
        XCTAssertNil(EntryAddress.parse("-oProxyCommand=reboot:22"))
        XCTAssertNil(EntryAddress.parse("ssh://-oProxyCommand=reboot@host"))
        let address = EntryAddress.parse("10.0.0.5:22")!
        XCTAssertEqual(address.sshCommand(login: "-oProxyCommand=reboot"), "ssh -- -oProxyCommand=reboot@10.0.0.5")
    }

    private func makeSession(_ storage: MemoryStorage, password: String = "пароль-хранилища") throws -> (VaultSession, SymmetricKey) {
        let session = VaultSession(storage: storage, backups: nil)
        let key = VaultCrypto.newVaultKey()
        try session.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: password, iterations: 1000))
        return (session, key)
    }

    private func unlock(_ session: VaultSession, _ storage: MemoryStorage, password: String) throws {
        let envelope = try JSONDecoder().decode(VaultEnvelope.self, from: XCTUnwrap(storage.data))
        try session.unlock(key: VaultCrypto.openSlot(envelope.slot, password: password))
    }

    /// Две копии Ward над одной связкой ключей: вторая не затирает изменения первой, а узнаёт о них.
    func testWriteOverForeignChangeIsRefused() throws {
        let storage = MemoryStorage()
        let (first, _) = try makeSession(storage)
        let second = VaultSession(storage: storage, backups: nil)
        try unlock(second, storage, password: "пароль-хранилища")

        try first.update { $0.upsert(Entry(title: "из первой")) }
        XCTAssertThrowsError(try second.update { $0.upsert(Entry(title: "из второй")) }) {
            XCTAssertEqual($0 as? VaultSessionError, .changedElsewhere)
        }
        XCTAssertEqual(second.vault.entries.count, 0, "память не ушла вперёд связки")

        second.lock()
        second.reload()
        try unlock(second, storage, password: "пароль-хранилища")
        XCTAssertEqual(second.vault.entries.map(\.title), ["из первой"])
        XCTAssertNoThrow(try second.update { $0.upsert(Entry(title: "из второй")) })
    }

    func testRekeyRetiresOldVaultKey() throws {
        let storage = MemoryStorage()
        let (session, oldKey) = try makeSession(storage)
        try session.update { $0.upsert(Entry(title: "A")) }
        let newKey = VaultCrypto.newVaultKey()
        try session.rekey(key: newKey, slot: VaultCrypto.makeSlot(for: newKey, password: "новый-пароль", iterations: 1000))
        try session.update { $0.upsert(Entry(title: "B")) }

        let envelope = try JSONDecoder().decode(VaultEnvelope.self, from: XCTUnwrap(storage.data))
        XCTAssertThrowsError(try VaultCrypto.decode(envelope, key: oldKey), "старый ключ хранилища больше ничего не открывает")
        XCTAssertEqual(try VaultCrypto.decode(envelope, key: newKey).entries.count, 2)
    }

    func testDamagedSlotIsNotReportedAsWrongPassword() throws {
        let key = VaultCrypto.newVaultKey()
        var slot = try VaultCrypto.makeSlot(for: key, password: "пароль", iterations: 1000)
        slot.wrappedKey = Data([1, 2, 3])
        XCTAssertThrowsError(try VaultCrypto.openSlot(slot, password: "пароль")) {
            XCTAssertEqual($0 as? VaultCryptoError, .corrupted)
        }
    }

    func testGeneratorIgnoresTamperedLength() {
        XCTAssertEqual(PasswordGenerator.generate(GeneratorOptions(length: 2)).count, 8)
        XCTAssertEqual(PasswordGenerator.generate(GeneratorOptions(length: 1_000_000_000)).count, 64)
        XCTAssertEqual(PasswordGenerator.generate(GeneratorOptions(length: -5)).count, 8)
    }

    func testKeyDerivationStopsWhenCancelled() async {
        let task = Task.detached {
            BcryptPBKDF.derive(password: Array("фраза".utf8), salt: Array(repeating: 1, count: 16), length: 48, rounds: 1 << 16)
        }
        task.cancel()
        let started = Date()
        let derived = await task.value
        XCTAssertNil(derived)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "65 536 раундов без отмены шли бы минуты")
    }

    /// Счётчик промахов и признак агента — в той же записи связки, что и хранилище, а не в UserDefaults.
    func testLockedStateLivesNextToVault() throws {
        let storage = MemoryStorage()
        let (session, _) = try makeSession(storage)
        try session.update { $0.security = { var s = SecuritySettings(); s.sshAgentEnabled = true; return s }() }
        session.lock()

        try session.recordUnlock(succeeded: false)
        try session.recordUnlock(succeeded: false)
        let reopened = VaultSession(storage: storage, backups: nil)
        XCTAssertEqual(reopened.failedUnlocks, 2, "переживает перезапуск")
        XCTAssertTrue(reopened.sshAgentEnabled, "известно до разблокировки")

        try unlock(reopened, storage, password: "пароль-хранилища")
        try reopened.recordUnlock(succeeded: true)
        XCTAssertEqual(VaultSession(storage: storage, backups: nil).failedUnlocks, 0)
        XCTAssertEqual(reopened.vault.security?.sshAgentEnabled, true)
    }

    func testOlderSecuritySettingsDecodeWithoutNewFields() throws {
        let settings = try JSONDecoder().decode(SecuritySettings.self, from: Data(#"{"autoLockMinutes":7}"#.utf8))
        XCTAssertEqual(settings.autoLockMinutes, 7)
        XCTAssertNil(settings.backupsToKeep, "признак «ещё не перенесено» — приложение возьмёт прежнее значение")
        XCTAssertNil(settings.mirrorBackupPath)
    }
}
