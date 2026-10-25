import XCTest
import CryptoKit
@testable import WardCore

final class VaultMigrationTests: XCTestCase {
    private func sample() throws -> Data {
        var entry = Entry(title: "Test server")
        entry.secret = "migration-test-password"
        var vault = Vault(entries: [entry])
        var security = SecuritySettings()
        security.autoLockMinutes = 7
        security.sshAgentEnabled = true
        security.browserEnabled = true
        vault.security = security
        var draftEntry = entry
        draftEntry.secret = "migration-test-draft"
        vault.saveDraft(EntryDraft(entry: draftEntry, isNew: false, reminderOn: false,
                                   reminder: Reminder(task: "", dayFrom: 1, dayTo: 1)))
        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: "migration-test-master", iterations: 1000)
        var envelope = try VaultCrypto.encode(vault, key: key, slot: slot)
        envelope.failedUnlocks = 4
        envelope.sshAgent = true
        envelope.browser = true
        return try JSONEncoder().encode(envelope)
    }

    func testCopyPreservesEncryptedBytesDraftsSettingsAndUnlockState() throws {
        let original = try sample()
        let source = MemoryStorage(original)
        let destination = MemoryStorage()
        XCTAssertTrue(try VaultMigration.copy(from: source, to: destination))
        XCTAssertEqual(source.data, original)
        XCTAssertEqual(source.writes, 0)
        XCTAssertEqual(destination.data, original)
        XCTAssertEqual(destination.writes, 1)
        let session = VaultSession(storage: destination, backups: nil)
        XCTAssertEqual(session.failedUnlocks, 4)
        XCTAssertTrue(session.sshAgentEnabled)
        XCTAssertTrue(session.browserEnabled)
        let key = try VaultCrypto.openSlot(XCTUnwrap(session.slot), password: "migration-test-master")
        try session.unlock(key: key)
        XCTAssertEqual(session.vault.entries.first?.secret, "migration-test-password")
        XCTAssertEqual(session.vault.drafts.first?.entry.secret, "migration-test-draft")
        XCTAssertEqual(session.vault.security?.autoLockMinutes, 7)
        XCTAssertTrue(session.vault.security?.sshAgentEnabled == true)
    }

    func testExistingDifferentDestinationIsNeverOverwritten() throws {
        let source = MemoryStorage(try sample())
        let existing = try sample()
        let destination = MemoryStorage(existing)
        XCTAssertThrowsError(try VaultMigration.copy(from: source, to: destination)) {
            XCTAssertEqual($0 as? VaultMigration.Failure, .destinationExists)
        }
        XCTAssertEqual(destination.data, existing)
        XCTAssertEqual(destination.writes, 0)
        XCTAssertEqual(source.writes, 0)
    }

    func testIdenticalDestinationIsAnIdempotentNoOp() throws {
        let data = try sample()
        let destination = MemoryStorage(data)
        XCTAssertFalse(try VaultMigration.copy(from: MemoryStorage(data), to: destination))
        XCTAssertEqual(destination.writes, 0)
    }

    func testMissingMalformedAndNewerSourcesDoNotCreateDestination() throws {
        var newer = try JSONDecoder().decode(VaultEnvelope.self, from: sample())
        newer.format = VaultEnvelope.currentFormat + 1
        for data in [nil, Data("not a vault".utf8), try JSONEncoder().encode(newer)] {
            let destination = MemoryStorage()
            XCTAssertThrowsError(try VaultMigration.copy(from: MemoryStorage(data), to: destination))
            XCTAssertNil(destination.data)
            XCTAssertEqual(destination.writes, 0)
        }
    }

    func testReadFailuresLeaveBothStoresUntouched() throws {
        for sourceFailure in [true, false] {
            let data = try sample()
            let source = MemoryStorage(data)
            let destination = MemoryStorage()
            source.failReads = sourceFailure
            destination.failReads = !sourceFailure
            XCTAssertThrowsError(try VaultMigration.copy(from: source, to: destination))
            XCTAssertEqual(source.data, data)
            XCTAssertEqual(source.writes, 0)
            XCTAssertNil(destination.data)
            XCTAssertEqual(destination.writes, 0)
        }
    }

    func testInvalidEncryptionParametersDoNotCreateDestination() throws {
        let valid = try JSONDecoder().decode(VaultEnvelope.self, from: sample())
        let corruptions: [(inout VaultEnvelope) -> Void] = [
            { $0.format = -1 },
            { $0.slot.kdf = "unsupported" },
            { $0.slot.salt = Data() },
            { $0.slot.iterations = 0 },
            { $0.slot.iterations = VaultCrypto.maxIterations + 1 },
            { $0.slot.wrappedKey = Data([1, 2, 3]) },
            { $0.slot.wrappedKey = Data(repeating: 0, count: 29) },
            { $0.payload = Data([1, 2, 3]) },
        ]
        for corrupt in corruptions {
            var envelope = valid
            corrupt(&envelope)
            let raw = try JSONEncoder().encode(envelope)
            let source = MemoryStorage(raw)
            let destination = MemoryStorage()
            XCTAssertThrowsError(try VaultMigration.copy(from: source, to: destination))
            XCTAssertEqual(source.data, raw)
            XCTAssertEqual(source.writes, 0)
            XCTAssertNil(destination.data)
            XCTAssertEqual(destination.writes, 0)
        }
    }

    func testFailedCreationKeepsSourceAndConcurrentDestination() throws {
        let original = try sample()
        let source = MemoryStorage(original)
        let concurrent = try sample()
        let destination = RacingStorage(concurrent: concurrent)
        XCTAssertThrowsError(try VaultMigration.copy(from: source, to: destination))
        XCTAssertEqual(source.data, original)
        XCTAssertEqual(source.writes, 0)
        XCTAssertEqual(destination.data, concurrent)
    }
}

private final class RacingStorage: VaultStorage {
    private(set) var data: Data?
    private let concurrent: Data

    init(concurrent: Data) { self.concurrent = concurrent }

    func read() throws -> Data? { nil }

    func create(_ data: Data) throws {
        self.data = concurrent
        throw KeychainStorage.Failure(status: errSecDuplicateItem)
    }

    func update(_ data: Data) throws { XCTFail("Migration must never update an existing vault") }
}
