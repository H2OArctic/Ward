import XCTest
import CryptoKit
@testable import Ward
import WardCore

final class AppLifecycleTests: XCTestCase {
    @MainActor
    private func store(_ vault: Vault = Vault()) async -> VaultStore {
        let store = VaultStore(storage: AppMemoryStorage(),
            backups: BackupStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), keep: { 1 }))
        await store.loadDemo(vault)
        return store
    }

    private func passkey() throws -> Passkey {
        try WebAuthn.register(rpID: "example.com", origin: "https://example.com", userHandle: Data([1]),
            userName: "alice", userDisplayName: "Alice", algorithms: [-7]).passkey
    }

    private func request(_ type: String) throws -> Data {
        var object: [String: Any] = ["id": 1, "type": type, "rpID": "example.com", "origin": "https://example.com", "challenge": "Ag"]
        if type == "passkey.create" {
            object["userHandle"] = "AQ"
            object["userName"] = "alice"
            object["algorithms"] = [-7]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func response(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func testPasskeyApprovalCannotSurviveVaultLock() async throws {
        var entry = Entry(title: "Account")
        entry.passkeys = [try passkey()]
        let store = await store(Vault(entries: [entry]))
        let displayed = expectation(description: "approval")
        var approve: CheckedContinuation<Int?, Never>?
        let browser = BrowserController(store: store, approval: { _, _, _, _ in
            await withCheckedContinuation { approve = $0; displayed.fulfill() }
        })
        let data = try request("passkey.get")
        let task = Task { await browser.respond(to: data) }
        await fulfillment(of: [displayed], timeout: 1)
        store.lock(reason: .manual)
        approve?.resume(returning: 0)
        let reply = try response(await task.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "locked")
        XCTAssertNil(reply["result"])
        XCTAssertTrue(store.vault.entries.isEmpty)
    }

    @MainActor
    func testCancelledPasskeyRequestCannotReturnSignature() async throws {
        var entry = Entry(title: "Account")
        entry.passkeys = [try passkey()]
        let store = await store(Vault(entries: [entry]))
        let displayed = expectation(description: "approval")
        var approve: CheckedContinuation<Int?, Never>?
        let browser = BrowserController(store: store, approval: { _, _, _, _ in
            await withCheckedContinuation { approve = $0; displayed.fulfill() }
        })
        let data = try request("passkey.get")
        let task = Task { await browser.respond(to: data) }
        await fulfillment(of: [displayed], timeout: 1)
        task.cancel()
        approve?.resume(returning: 0)
        let reply = try response(await task.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "cancelled")
        XCTAssertNil(reply["result"])
    }

    @MainActor
    func testDeletedPasskeyIsRecheckedAfterApproval() async throws {
        var entry = Entry(title: "Account")
        let key = try passkey()
        entry.passkeys = [key]
        let store = await store(Vault(entries: [entry]))
        let displayed = expectation(description: "approval")
        var approve: CheckedContinuation<Int?, Never>?
        let browser = BrowserController(store: store, approval: { _, _, _, _ in
            await withCheckedContinuation { approve = $0; displayed.fulfill() }
        })
        let data = try request("passkey.get")
        let task = Task { await browser.respond(to: data) }
        await fulfillment(of: [displayed], timeout: 1)
        await store.removePasskey(key.id, from: entry.id)
        approve?.resume(returning: 0)
        let reply = try response(await task.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "noPasskey")
        XCTAssertNil(reply["result"])
    }

    @MainActor
    func testDeletedDestinationCannotProduceRegistrationSuccess() async throws {
        var entry = Entry(title: "Account")
        entry.url = "https://example.com"
        let store = await store(Vault(entries: [entry]))
        let displayed = expectation(description: "approval")
        var approve: CheckedContinuation<Int?, Never>?
        let browser = BrowserController(store: store, approval: { _, _, _, _ in
            await withCheckedContinuation { approve = $0; displayed.fulfill() }
        })
        let data = try request("passkey.create")
        let task = Task { await browser.respond(to: data) }
        await fulfillment(of: [displayed], timeout: 1)
        await store.purge(entry.id)
        approve?.resume(returning: 0)
        let reply = try response(await task.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "saveFailed")
        XCTAssertTrue(store.vault.entries.isEmpty)
        XCTAssertNil(reply["result"])
    }

    @MainActor
    func testEditorSavePreservesConcurrentPasskeyAndUsageUpdates() async throws {
        let entry = Entry(title: "Original")
        let store = await store(Vault(entries: [entry]))
        var edited = entry
        edited.title = "Edited"
        let key = try passkey()
        let added = await store.addPasskey(key, to: entry.id)
        XCTAssertTrue(added)
        await store.markUsed(entry.id)
        let saved = await store.save(edited)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.entry(entry.id)?.title, "Edited")
        XCTAssertEqual(store.entry(entry.id)?.passkeys.map(\.id), [key.id])
        XCTAssertEqual(store.entry(entry.id)?.useCount, 1)
    }

    @MainActor
    func testConcurrentServiceLinksDoNotOverwriteEachOther() async {
        let first = Project(name: "First", space: .personal)
        let second = Project(name: "Second", space: .personal)
        let service = Service(name: "Service", space: .personal)
        let store = await store(Vault(projects: [first, second], services: [service]))
        async let a: Void = store.linkService(service.id, to: first.id)
        async let b: Void = store.linkService(service.id, to: second.id)
        _ = await (a, b)
        XCTAssertEqual(Set(store.service(service.id)?.projectIDs ?? []), [first.id, second.id])
    }

    @MainActor
    func testLockDuringBackgroundWriteNeverPublishesLateUnlock() async throws {
        let storage = AppMemoryStorage()
        let session = VaultSession(storage: storage, backups: nil)
        let key = VaultCrypto.newVaultKey()
        try session.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: "demo", iterations: 1))
        let store = VaultStore(storage: storage, backups: BackupStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), keep: { 1 }))
        try await store.unlock(password: "demo")
        let writing = expectation(description: "background write")
        let gate = DispatchSemaphore(value: 0)
        storage.beforeUpdate = { XCTAssertFalse(Thread.isMainThread); writing.fulfill(); gate.wait() }
        let entry = Entry(title: "Saved before lock")
        let task = Task { await store.save(entry) }
        await fulfillment(of: [writing], timeout: 1)
        store.lock(reason: .manual)
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.vault.entries.isEmpty)
        storage.beforeUpdate = nil
        gate.signal()
        let result = await task.value
        XCTAssertFalse(result)
        await store.flushDraft()
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.vault.entries.isEmpty)
        try await store.unlock(password: "demo")
        XCTAssertEqual(store.entry(entry.id)?.title, entry.title)
    }

    @MainActor
    func testFailedStoreWriteRetainsPublishedVault() async throws {
        let storage = AppMemoryStorage()
        let session = VaultSession(storage: storage, backups: nil)
        let key = VaultCrypto.newVaultKey()
        try session.create(key: key, slot: VaultCrypto.makeSlot(for: key, password: "demo", iterations: 1))
        let store = VaultStore(storage: storage, backups: BackupStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), keep: { 1 }))
        try await store.unlock(password: "demo")
        storage.failUpdates = true
        let saved = await store.save(Entry(title: "Unsaved"))
        XCTAssertFalse(saved)
        XCTAssertTrue(store.vault.entries.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testFlushAfterLockWaitsForDraftPersistence() async throws {
        let entry = Entry(title: "Draft")
        let draft = EntryDraft(entry: entry, isNew: true, reminderOn: false, reminder: Reminder(task: "", dayFrom: 1, dayTo: 1))
        let store = await store()
        store.setDraftSaver(id: entry.id) { draft }
        store.lock(reason: .manual)
        await store.flushDraft()
        try await store.unlock(password: "demo")
        XCTAssertEqual(store.drafts.map(\.id), [entry.id])
    }

    @MainActor
    func testTerminationLocksImmediatelyAndDrainsDraftWrite() async throws {
        let store = await store()
        let entry = Entry(title: "Before quit")
        let draft = EntryDraft(entry: entry, isNew: true, reminderOn: false, reminder: Reminder(task: "", dayFrom: 1, dayTo: 1))
        store.setDraftSaver(id: entry.id) { draft }
        let flushed = expectation(description: "termination flushed")
        store.prepareForTermination { flushed.fulfill() }
        XCTAssertEqual(store.state, .locked)
        await fulfillment(of: [flushed], timeout: 1)
        try await store.unlock(password: "demo")
        XCTAssertEqual(store.drafts.map(\.id), [entry.id])
    }

    func testSSHRevocationWhileApprovalIsPendingSuppressesSignature() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("key").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let privateKey = try String(contentsOfFile: path, encoding: .utf8)
        let publicKey = try String(contentsOfFile: path + ".pub", encoding: .utf8)
        let blob = try XCTUnwrap(SSHKeyParser.publicKey(publicKey)?.blob)
        let candidate = AgentController.Candidate(entryID: UUID(), title: "Test", blob: blob, privateKey: privateKey, passphrase: "")
        let client = SSHAgentClient(pid: getpid(), executable: "/usr/bin/ssh", parentExecutable: nil)
        let allowed = WardAgentBackend(approval: { _, _, _ in .once })
        allowed.update(unlocked: true, enabled: true, candidates: [candidate], confirm: true)
        XCTAssertNotNil(allowed.sign(blob: blob, data: Data([1, 2]), flags: 0, client: client))
        let displayed = expectation(description: "approval")
        let gate = DispatchSemaphore(value: 0)
        let revoked = WardAgentBackend(approval: { _, _, _ in displayed.fulfill(); gate.wait(); return .once })
        revoked.update(unlocked: true, enabled: true, candidates: [candidate], confirm: true)
        let task = Task.detached { revoked.sign(blob: blob, data: Data([1, 2]), flags: 0, client: client) }
        await fulfillment(of: [displayed], timeout: 1)
        revoked.update(unlocked: true, enabled: true, candidates: [], confirm: true)
        gate.signal()
        let signature = await task.value
        XCTAssertNil(signature)
    }
}

private final class AppMemoryStorage: VaultStorage {
    var data: Data?
    var failUpdates = false
    var beforeUpdate: (() -> Void)?
    struct Failure: Error {}
    func read() throws -> Data? { data }
    func create(_ data: Data) throws { self.data = data }
    func update(_ data: Data) throws {
        beforeUpdate?()
        if failUpdates { throw Failure() }
        self.data = data
    }
}
