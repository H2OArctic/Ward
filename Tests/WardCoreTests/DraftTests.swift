import XCTest
import CryptoKit
@testable import WardCore

final class DraftTests: XCTestCase {
    private func draft(_ entry: Entry, secret: String) -> EntryDraft {
        var edited = entry
        edited.secret = secret
        return EntryDraft(entry: edited, isNew: false, reminderOn: false, reminder: Reminder(task: "", dayFrom: 1, dayTo: 1))
    }

    func testSaveReplaceRemove() {
        let entry = Entry(title: "GitHub")
        var vault = Vault(entries: [entry])
        vault.saveDraft(draft(entry, secret: "первый"))
        vault.saveDraft(draft(entry, secret: "второй"))
        XCTAssertEqual(vault.drafts.count, 1, "один черновик на запись")
        XCTAssertEqual(vault.draft(entry.id)?.entry.secret, "второй")
        XCTAssertEqual(vault.entries[0].secret, "", "сама запись не меняется")
        vault.removeDraft(entry.id)
        XCTAssertTrue(vault.drafts.isEmpty)
    }

    func testPurgeRemovesDraftWithSecret() {
        let entry = Entry(title: "Банк")
        var vault = Vault(entries: [entry])
        vault.saveDraft(draft(entry, secret: "новый-пароль"))
        vault.purge([entry.id])
        XCTAssertTrue(vault.drafts.isEmpty, "удалённая навсегда запись не живёт дальше в черновике")
    }

    /// Черновик переживает перезапуск: лежит в зашифрованном хранилище, а не рядом открытым текстом.
    func testDraftSurvivesReopenAndIsEncrypted() throws {
        let storage = MemoryStorage()
        let session = VaultSession(storage: storage, backups: nil)
        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: "пароль-хранилища", iterations: 1000)
        try session.create(key: key, slot: slot)
        let entry = Entry(title: "Почта")
        try session.update { $0.upsert(entry) }
        try session.update(backup: false) { $0.saveDraft(self.draft(entry, secret: "черновой-секрет-123")) }

        let raw = try XCTUnwrap(storage.data)
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "черновой-секрет-123"))
        let reopened = VaultSession(storage: storage, backups: nil)
        try reopened.unlock(key: VaultCrypto.openSlot(XCTUnwrap(reopened.slot), password: "пароль-хранилища"))
        XCTAssertEqual(reopened.vault.draft(entry.id)?.entry.secret, "черновой-секрет-123")
    }

    func testDraftsStayOutOfMergeAndExport() {
        let entry = Entry(title: "Сервис")
        var source = Vault(entries: [entry])
        source.saveDraft(draft(entry, secret: "черновик"))
        var target = Vault()
        target.merge(source)
        XCTAssertTrue(target.drafts.isEmpty, "восстановление из копии не приносит чужие черновики")
        XCTAssertFalse(CSVExport.export(source.entries).contains("черновик"))
    }

    func testOldVaultHasNoDrafts() throws {
        let vault = try JSONDecoder().decode(Vault.self, from: Data(#"{"format":1,"projects":[],"entries":[]}"#.utf8))
        XCTAssertTrue(vault.drafts.isEmpty)
    }
}

final class ConnectionTests: XCTestCase {
    func testOldTextStepsDecodeAndLinksRoundTrip() throws {
        let old = #"{"id":"7F9619FF-8B86-D011-B42D-00CF4FC964FF","preSteps":["VPN «Офис»","Basic auth"]}"#
        let entry = try JSONDecoder().decode(Entry.self, from: Data(old.utf8))
        XCTAssertEqual(entry.preSteps, [.text("VPN «Офис»"), .text("Basic auth")], "старые шаги-строки читаются как есть")
        XCTAssertFalse(entry.isConnection)

        var linked = entry
        let vpn = UUID()
        linked.preSteps = [.entry(vpn), .text("Basic auth")]
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(linked))
        XCTAssertEqual(decoded.preSteps, [.entry(vpn), .text("Basic auth")])
    }

    func testConnectionsScopeTitlesAndPurge() {
        let company = Company(name: "Ромашка")
        let other = Company(name: "Клиент")
        var vpnA = Entry(title: "VPN A", space: .work)
        vpnA.isConnection = true
        vpnA.companyID = company.id
        var vpnB = Entry(title: "VPN B", space: .work)
        vpnB.isConnection = true
        vpnB.companyID = other.id
        var admin = Entry(title: "Админка", space: .work)
        admin.companyID = company.id
        admin.preSteps = [.entry(vpnA.id), .text("Basic auth")]
        var vault = Vault(companies: [company, other], entries: [vpnA, vpnB, admin])

        XCTAssertEqual(vault.connections(for: admin).map(\.title), ["VPN A"], "только подключения своей компании")
        XCTAssertEqual(vault.title(of: admin.preSteps[0]), "VPN A")
        XCTAssertEqual(vault.entriesUsing(connection: vpnA.id).map(\.title), ["Админка"])

        vault.purge([vpnA.id])
        XCTAssertEqual(vault.entries.first { $0.id == admin.id }?.preSteps, [.text("Basic auth")],
                       "удалённое навсегда подключение снимается с шагов, ссылок в никуда нет")
    }
}
