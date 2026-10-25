import Foundation

public final class VaultWorker: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let state: VaultSession.State
        public let vault: Vault
        public let slot: KeySlot?
        public let failedUnlocks: Int
        public let sshAgentEnabled: Bool
        public let browserEnabled: Bool
        public let backupProblem: String?
        public let revision: UInt64

        public func locked() -> Snapshot {
            Snapshot(state: .locked, vault: Vault(), slot: slot, failedUnlocks: failedUnlocks,
                     sshAgentEnabled: sshAgentEnabled, browserEnabled: browserEnabled,
                     backupProblem: backupProblem, revision: revision)
        }
    }

    public struct Result<Value> {
        public let value: Value
        public let snapshot: Snapshot
    }

    public let initial: Snapshot
    private let session: VaultSession
    private let queue = DispatchQueue(label: "ward.vault.persistence", qos: .userInitiated)
    private let lock = NSLock()
    private var epoch = UUID()
    private var revision: UInt64 = 0

    public init(storage: VaultStorage, backups: BackupStore?) {
        let session = VaultSession(storage: storage, backups: backups)
        self.session = session
        initial = Self.snapshot(session, revision: 0)
    }

    public var generation: UUID {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    @discardableResult
    public func invalidate() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        epoch = UUID()
        return epoch
    }

    public func perform<Value>(generation: UUID, _ body: @escaping (VaultSession) throws -> Value) async throws -> Result<Value> {
        try Task.checkCancellation()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard self.generation == generation, !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let value = try body(session)
                        revision &+= 1
                        continuation.resume(returning: Result(value: value, snapshot: Self.snapshot(session, revision: revision)))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    public func drain() async {
        await withCheckedContinuation { continuation in
            drain { continuation.resume() }
        }
    }

    public func drain(completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    public func lock(draft: EntryDraft?, removingDraft id: UUID?, completion: @escaping (Snapshot, String?) -> Void) {
        queue.async { [self] in
            var problem: String?
            do {
                if let draft { try session.update(backup: false) { $0.saveDraft(draft) } }
                else if let id, session.state == .unlocked { try session.update(backup: false) { $0.removeDraft(id) } }
            } catch { problem = error.localizedDescription }
            session.lock()
            revision &+= 1
            completion(Self.snapshot(session, revision: revision), problem)
        }
    }

    private static func snapshot(_ session: VaultSession, revision: UInt64) -> Snapshot {
        Snapshot(state: session.state, vault: session.vault, slot: session.slot, failedUnlocks: session.failedUnlocks,
                 sshAgentEnabled: session.sshAgentEnabled, browserEnabled: session.browserEnabled,
                 backupProblem: session.backupError?.localizedDescription, revision: revision)
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }
}
