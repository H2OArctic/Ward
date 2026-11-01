import XCTest
@testable import WardCore

final class CryptoWalletTests: XCTestCase {
    private func entry() -> Entry {
        var entry = Entry(title: "Холодный кошелёк")
        entry.wallet = CryptoWallet(network: "Ethereum", address: "demo-address-only",
                                    seedPhrase: "demo-recovery-words-only", privateKey: "demo-private-value-only",
                                    passphrase: "demo-passphrase-only")
        return entry
    }

    func testOldEntryAndPartialWalletDecode() throws {
        let old = try JSONDecoder().decode(Entry.self, from: Data("{\"id\":\"\(UUID())\"}".utf8))
        XCTAssertNil(old.wallet)
        let partial = try JSONDecoder().decode(CryptoWallet.self, from: Data(#"{"network":"Bitcoin"}"#.utf8))
        XCTAssertEqual(partial.network, "Bitcoin")
        XCTAssertTrue(partial.seedPhrase.isEmpty)
        XCTAssertTrue(partial.privateKey.isEmpty)
        XCTAssertTrue(partial.passphrase.isEmpty)
    }

    func testWalletAndDraftSurviveEncryptedReopenAndMerge() throws {
        let storage = MemoryStorage()
        let session = VaultSession(storage: storage, backups: nil)
        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: "test-wallet-password", iterations: 1000)
        try session.create(key: key, slot: slot)
        let entry = entry()
        var edited = entry
        edited.wallet?.seedPhrase = "demo-edited-recovery-only"
        try session.update {
            $0.upsert(entry)
            $0.saveDraft(EntryDraft(entry: edited, isNew: false, reminderOn: false,
                                   reminder: Reminder(task: "", dayFrom: 1, dayTo: 1)))
        }
        let raw = try XCTUnwrap(storage.data)
        for secret in [entry.wallet!.seedPhrase, entry.wallet!.privateKey, entry.wallet!.passphrase, edited.wallet!.seedPhrase] {
            XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(secret))
        }
        let reopened = VaultSession(storage: storage, backups: nil)
        try reopened.unlock(key: key)
        XCTAssertEqual(reopened.vault.entries.first?.wallet, entry.wallet)
        XCTAssertEqual(reopened.vault.draft(entry.id)?.entry.wallet, edited.wallet)
        var merged = Vault()
        merged.merge(reopened.vault)
        XCTAssertEqual(merged.entries.first?.wallet, entry.wallet)
    }

    func testSearchAndCSVDoNotExposeWalletSecrets() throws {
        let entry = entry()
        for query in ["Ethereum", "demo-address-only"] {
            XCTAssertEqual(EntrySearch.search([entry], query: query).map(\.id), [entry.id])
        }
        let wallet = try XCTUnwrap(entry.wallet)
        for secret in [wallet.seedPhrase, wallet.privateKey, wallet.passphrase] {
            XCTAssertTrue(EntrySearch.search([entry], query: secret).isEmpty)
            XCTAssertFalse(CSVExport.export([entry]).contains(secret))
        }
    }
}
