import Foundation
import CryptoKit

public enum VaultSessionError: LocalizedError, Equatable {
    case notUnlocked
    case alreadyExists
    case unavailable(String)
    /// Хранилище в связке ключей переписал кто-то другой (второй запущенный Ward): запись поверх потеряла бы его изменения.
    case changedElsewhere
    case noSuchEntry

    public var errorDescription: String? {
        switch self {
        case .notUnlocked: return "Хранилище заблокировано"
        case .alreadyExists: return "Хранилище уже создано"
        case .unavailable(let reason): return "Хранилище недоступно: \(reason)"
        case .changedElsewhere: return "Хранилище изменено другой копией Ward — заблокируйте и откройте его заново"
        case .noSuchEntry: return "Запись удалена"
        }
    }
}

/// Жизненный цикл хранилища без UI: создание, открытие, изменения, смена пароля, копии.
/// Вывод ключа из пароля (медленный) делает вызывающий — сюда приходят уже готовые ключи и слоты.
public final class VaultSession {
    public enum State: Equatable, Sendable {
        case needsSetup
        case locked
        case unlocked
        /// Хранилище есть, но прочитать его не вышло. Создавать новое в этом состоянии нельзя — затрёт старое.
        case unavailable(String)
    }

    public private(set) var state: State
    public private(set) var vault = Vault()
    /// Ошибка последней резервной копии. Само изменение при этом уже сохранено — это только предупреждение.
    public private(set) var backupError: Error?

    private let storage: VaultStorage
    private var backups: BackupStore?
    private var envelope: VaultEnvelope?
    /// Байты хранилища, как они лежат в связке ключей после нашего последнего чтения или записи.
    private var stored: Data?
    private var key: SymmetricKey?

    public init(storage: VaultStorage, backups: BackupStore?) {
        self.storage = storage
        self.backups = backups
        state = .needsSetup
        load()
    }

    private func load() {
        do {
            if let data = try storage.read() {
                envelope = try JSONDecoder().decode(VaultEnvelope.self, from: data)
                stored = data
                state = .locked
            } else {
                envelope = nil
                stored = nil
                state = .needsSetup
            }
        } catch {
            envelope = nil
            stored = nil
            state = .unavailable(error.localizedDescription)
        }
    }

    /// Перечитать хранилище перед разблокировкой: пока оно было заблокировано, его могла сменить другая копия Ward.
    public func reload() {
        guard state != .unlocked else { return }
        load()
    }

    public var slot: KeySlot? { envelope?.slot }
    public var failedUnlocks: Int { envelope?.failedUnlocks ?? 0 }
    public var sshAgentEnabled: Bool { envelope?.sshAgent ?? false }
    public var browserEnabled: Bool { envelope?.browser ?? false }

    /// Итог проверки мастер-пароля. Ключ не нужен: меняется только открытая служебная часть записи.
    public func recordUnlock(succeeded: Bool) throws {
        guard var updated = envelope else { throw VaultSessionError.notUnlocked }
        let count = succeeded ? 0 : failedUnlocks + 1
        guard count != failedUnlocks else { return }
        updated.failedUnlocks = count
        try store(updated)
    }

    public func create(key: SymmetricKey, slot: KeySlot) throws {
        guard state == .needsSetup else { throw VaultSessionError.alreadyExists }
        let fresh = Vault()
        let envelope = try VaultCrypto.encode(fresh, key: key, slot: slot)
        let data = try JSONEncoder().encode(envelope)
        try storage.create(data)
        stored = data
        self.envelope = envelope
        self.key = key
        vault = fresh
        state = .unlocked
    }

    public func unlock(key: SymmetricKey) throws {
        guard let envelope else {
            if case .unavailable(let reason) = state { throw VaultSessionError.unavailable(reason) }
            throw VaultSessionError.notUnlocked
        }
        vault = try VaultCrypto.decode(envelope, key: key)
        self.key = key
        state = .unlocked
    }

    public func lock() {
        guard state == .unlocked else { return }
        key = nil
        vault = Vault()
        state = .locked
    }

    /// Изменение попадает в память только после успешной записи — память и связка ключей не расходятся.
    @discardableResult
    public func update(backup: Bool = true, _ change: (inout Vault) throws -> Void) throws -> Vault {
        try updateReturning(backup: backup, change).vault
    }

    public func updateReturning<Value>(backup: Bool = true, _ change: (inout Vault) throws -> Value) throws -> (vault: Vault, value: Value) {
        guard state == .unlocked, let key, let envelope else { throw VaultSessionError.notUnlocked }
        var next = vault
        let value = try change(&next)
        try write(next, key: key, slot: envelope.slot, backup: backup)
        vault = next
        return (next, value)
    }

    public func setBackupLimit(_ limit: Int) {
        guard let backups else { return }
        self.backups = BackupStore(directory: backups.directory, keep: { limit })
    }

    /// Смена мастер-пароля вместе с ключом хранилища: кто достал старый ключ (старый пароль + любая старая копия),
    /// не прочитает ни новые копии, ни связку ключей.
    public func rekey(key newKey: SymmetricKey, slot: KeySlot) throws {
        guard state == .unlocked, key != nil else { throw VaultSessionError.notUnlocked }
        try write(vault, key: newKey, slot: slot, backup: true)
        key = newKey
    }

    public func exportData() throws -> Data {
        guard state == .unlocked, let envelope else { throw VaultSessionError.notUnlocked }
        return try JSONEncoder().encode(envelope)
    }

    @discardableResult
    private func store(_ updated: VaultEnvelope) throws -> Data {
        let data = try JSONEncoder().encode(updated)
        guard try storage.read() == stored else { throw VaultSessionError.changedElsewhere }
        try storage.update(data)
        stored = data
        envelope = updated
        return data
    }

    /// Бросает, только если не записалось само хранилище. Копия пишется после — если она не удалась,
    /// изменение уже в связке ключей, и сообщать «не сохранено» (а при смене пароля — «пароль прежний») нельзя.
    private func write(_ vault: Vault, key: SymmetricKey, slot: KeySlot, backup: Bool) throws {
        var updated = try VaultCrypto.encode(vault, key: key, slot: slot)
        // Хранилище открыто — значит, пароль уже введён верно.
        updated.failedUnlocks = 0
        updated.sshAgent = vault.security?.sshAgentEnabled ?? false
        updated.browser = vault.security?.browserEnabled ?? false
        let data = try store(updated)
        guard backup, let backups else { return }
        do {
            try backups.write(data)
            backupError = nil
        } catch {
            backupError = error
        }
    }
}

extension Vault {
    public mutating func addPasskey(_ passkey: Passkey, to entryID: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == entryID && !$0.isDeleted }) else {
            throw VaultSessionError.noSuchEntry
        }
        guard !entries.contains(where: { $0.passkeys.contains(where: { $0.id == passkey.id }) }) else {
            throw BrowserBridge.Failure.alreadyRegistered
        }
        entries[index].passkeys.append(passkey)
    }

    /// Смена пароля оставляет старый в истории.
    public mutating func upsert(_ entry: Entry, now: Date = Date()) {
        var entry = entry
        entry.updatedAt = now
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            let old = entries[i]
            if old.secret != entry.secret {
                if !old.secret.isEmpty { entry.history.insert(PasswordChange(value: old.secret, changedAt: now), at: 0) }
                entry.passwordUpdatedAt = entry.secret.isEmpty ? nil : now
            }
            entries[i] = entry
        } else {
            entry.createdAt = now
            if !entry.secret.isEmpty { entry.passwordUpdatedAt = now }
            entries.append(entry)
        }
    }

    public mutating func modifyEntry(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }

    /// Импорт без дублей: запись с тем же сайтом, логином и паролем уже есть (или встречалась в файле раньше).
    public mutating func importEntries(_ incoming: [Entry]) -> (added: Int, duplicates: Int) {
        func key(_ e: Entry) -> String {
            [e.url.trimmingCharacters(in: .whitespaces).lowercased(), e.login.lowercased(), e.secret,
             e.totp.map { Base32.encode($0.secret) } ?? ""].joined(separator: "\u{1F}")
        }
        var known = Set(entries.filter { !$0.isDeleted }.map(key))
        var added = 0, duplicates = 0
        for entry in incoming {
            guard known.insert(key(entry)).inserted else {
                duplicates += 1
                continue
            }
            entries.append(entry)
            added += 1
        }
        return (added, duplicates)
    }

    /// Добавляет только то, чего ещё нет (по id). Возвращает число добавленных записей.
    @discardableResult
    public mutating func merge(_ other: Vault) -> Int {
        let knownCompanies = Set(companies.map(\.id))
        let knownProjects = Set(projects.map(\.id))
        let knownServices = Set(services.map(\.id))
        let knownEntries = Set(entries.map(\.id))
        companies += other.companies.filter { !knownCompanies.contains($0.id) }
        projects += other.projects.filter { !knownProjects.contains($0.id) }
        services += other.services.filter { !knownServices.contains($0.id) }
        let added = other.entries.filter { !knownEntries.contains($0.id) }
        entries += added
        return added.count
    }
}
