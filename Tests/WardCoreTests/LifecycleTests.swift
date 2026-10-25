import XCTest
import CryptoKit
@testable import WardCore

final class LifecycleTests: XCTestCase {
    func testBrowserRejectsHTTPDowngradeAndSSHAddresses() throws {
        var secure = Entry(title: "HTTPS")
        secure.url = "https://example.com"
        secure.secret = "secret"
        var implicit = secure
        implicit.id = UUID()
        implicit.url = "example.com"
        var http = secure
        http.id = UUID()
        http.url = "http://example.com"
        var ssh = secure
        ssh.id = UUID()
        ssh.url = "ssh://example.com"
        let vault = Vault(entries: [secure, implicit, http, ssh])
        XCTAssertEqual(BrowserBridge.logins(for: "http://example.com", in: vault).map(\.entryID), [http.id])
        XCTAssertEqual(Set(BrowserBridge.logins(for: "https://example.com", in: vault).map(\.entryID)), [secure.id, implicit.id, http.id])
        XCTAssertThrowsError(try BrowserBridge.fill(entryID: secure.id, url: "http://example.com", in: vault))
        secure.url = "HTTPS://example.com"
        XCTAssertTrue(BrowserBridge.logins(for: "http://example.com", in: Vault(entries: [secure])).isEmpty)
        XCTAssertEqual(BrowserBridge.logins(for: "HTTPS://example.com", in: Vault(entries: [secure])).map(\.entryID), [secure.id])
    }

    func testPasskeyDestinationMustExistAndBeActive() throws {
        let passkey = try WebAuthn.register(rpID: "example.com", origin: "https://example.com",
            userHandle: Data([1]), userName: "alice", userDisplayName: "Alice", algorithms: [-7]).passkey
        var entry = Entry(title: "Account")
        var vault = Vault(entries: [entry])
        XCTAssertThrowsError(try vault.addPasskey(passkey, to: UUID()))
        try vault.addPasskey(passkey, to: entry.id)
        XCTAssertThrowsError(try vault.addPasskey(passkey, to: entry.id))
        entry.deletedAt = Date()
        vault = Vault(entries: [entry])
        XCTAssertThrowsError(try vault.addPasskey(passkey, to: entry.id))
        XCTAssertTrue(vault.entries[0].passkeys.isEmpty)
    }

    func testRepeatedAndSequentialMasterPasswordsAreWeak() {
        for password in ["abcabcabcabcabcabc", "AbcAbcAbcAbcAbcAbc!", "xyzxyzxyzxyzxyzxyz12", "abcdefghijklmnopqrstuvwxyz", "zyxwvutsrqponmlkjihgfedcba"] {
            XCTAssertLessThan(PasswordStrength.evaluate(password).score, 3, password)
            XCTAssertNotNil(MasterPasswordPolicy.problem(password), password)
        }
        XCTAssertNil(MasterPasswordPolicy.problem("R7!mW2@kF9#tZ4$pL6%q"))
        XCTAssertLessThan(PasswordStrength.evaluate(String(repeating: "abc", count: 30_000)).score, 3)
    }

    @MainActor
    func testApprovalQueueCancelsActiveAndIgnoresLateCallbacks() async {
        let queue = ApprovalQueue<Int>()
        var choices: [(Int?) -> Void] = []
        var closed = 0
        let shown = expectation(description: "first shown")
        let first = Task { await queue.ask(show: { choices.append($0); shown.fulfill() }, close: { closed += 1 }) }
        await fulfillment(of: [shown], timeout: 1)
        let secondShown = expectation(description: "second shown")
        let second = Task { await queue.ask(show: { choices.append($0); secondShown.fulfill() }, close: { closed += 1 }) }
        first.cancel()
        await fulfillment(of: [secondShown], timeout: 1)
        choices[0](99)
        choices[1](7)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(secondResult, 7)
        XCTAssertEqual(closed, 2)
    }

    @MainActor
    func testApprovalQueueBoundsAndCancelsQueuedRequests() async {
        let queue = ApprovalQueue<Int>(limit: 1)
        let shown = expectation(description: "shown")
        let first = Task { await queue.ask(show: { _ in shown.fulfill() }, close: {}) }
        await fulfillment(of: [shown], timeout: 1)
        let rejected = await queue.ask(show: { _ in XCTFail("overflow displayed") }, close: {})
        XCTAssertNil(rejected)
        queue.cancelAll()
        let firstResult = await first.value
        XCTAssertNil(firstResult)
    }

    @MainActor
    func testApprovalQueueTimeoutIncludesTimeWaitingInQueue() async {
        let queue = ApprovalQueue<Int>(timeout: .milliseconds(50))
        let shown = expectation(description: "shown")
        let first = Task { await queue.ask(show: { _ in shown.fulfill() }, close: {}) }
        await fulfillment(of: [shown], timeout: 1)
        let second = Task { await queue.ask(show: { _ in }, close: {}) }
        let started = Date()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    private func worker() async throws -> VaultWorker {
        let worker = VaultWorker(storage: MemoryStorage(), backups: nil)
        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: "demo", iterations: 1)
        _ = try await worker.perform(generation: worker.generation) { try $0.create(key: key, slot: slot) }
        return worker
    }

    @MainActor
    func testWorkerSerializesWritesOutsideMainThread() async throws {
        let worker = try await worker()
        let generation = worker.generation
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    _ = try await worker.perform(generation: generation) { session in
                        XCTAssertFalse(Thread.isMainThread)
                        try session.update(backup: false) { $0.upsert(Entry(title: String(i))) }
                    }
                }
            }
            try await group.waitForAll()
        }
        let result = try await worker.perform(generation: generation) { $0.vault.entries.count }
        XCTAssertEqual(result.value, 20)
        XCTAssertEqual(result.snapshot.vault.entries.count, 20)
    }

    func testWorkerRejectsInvalidatedQueuedOperationAndLocksWithDraft() async throws {
        let worker = try await worker()
        let generation = worker.generation
        let started = expectation(description: "started")
        let gate = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await worker.perform(generation: generation) { _ in started.fulfill(); gate.wait() }
        }
        await fulfillment(of: [started], timeout: 1)
        let queued = Task {
            try await worker.perform(generation: generation) { _ in XCTFail("stale operation executed") }
        }
        let current = worker.invalidate()
        let entry = Entry(title: "Draft")
        let draft = EntryDraft(entry: entry, isNew: true, reminderOn: false, reminder: Reminder(task: "", dayFrom: 1, dayTo: 1))
        let locked = expectation(description: "locked")
        worker.lock(draft: draft, removingDraft: nil) { snapshot, error in
            XCTAssertEqual(snapshot.state, .locked)
            XCTAssertTrue(snapshot.vault.entries.isEmpty)
            XCTAssertNil(error)
            locked.fulfill()
        }
        gate.signal()
        _ = try await blocker.value
        do { _ = try await queued.value; XCTFail("stale operation accepted") } catch is CancellationError {} catch { XCTFail("\(error)") }
        await fulfillment(of: [locked], timeout: 1)
        let result = try await worker.perform(generation: current) { session in
            let key = try VaultCrypto.openSlot(XCTUnwrap(session.slot), password: "demo")
            try session.unlock(key: key)
            return session.vault.drafts
        }
        XCTAssertEqual(result.value.map(\.id), [entry.id])
    }

    func testFailedWorkerWriteDoesNotPublishUnsavedVault() async throws {
        let storage = MemoryStorage()
        let worker = VaultWorker(storage: storage, backups: nil)
        let key = VaultCrypto.newVaultKey()
        let slot = try VaultCrypto.makeSlot(for: key, password: "demo", iterations: 1)
        _ = try await worker.perform(generation: worker.generation) { try $0.create(key: key, slot: slot) }
        do {
            _ = try await worker.perform(generation: worker.generation) { session in
                storage.failUpdates = true
                try session.update { $0.upsert(Entry(title: "unsaved")) }
            }
            XCTFail("failed write accepted")
        } catch {}
        let result = try await worker.perform(generation: worker.generation) { $0.vault }
        XCTAssertTrue(result.value.entries.isEmpty)
    }
}
