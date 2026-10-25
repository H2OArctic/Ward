import Foundation
import CryptoKit
import WardCore

/// Мост между `VaultSession` из ядра и SwiftUI: публикует состояние, медленный вывод ключа уводит с главного потока.
@MainActor
final class VaultStore: ObservableObject {
    static let shared: VaultStore = {
        #if DEBUG
        // Снимки интерфейса не должны трогать настоящую связку ключей: там может ждать системный запрос доступа.
        let env = ProcessInfo.processInfo.environment
        if env["WARD_SNAPSHOT"] != nil || env["WARD_AGENT_DEMO"] != nil || env["WARD_BROWSER_DEMO"] != nil {
            return VaultStore(storage: MemoryVaultStorage(),
                              backups: BackupStore(directory: FileManager.default.temporaryDirectory
                                  .appendingPathComponent("ward-snapshot-backups"), keep: { 1 }))
        }
        #endif
        let backupLimit = Prefs.shared.backupsToKeep
        return VaultStore(
            storage: KeychainStorage(service: WardIdentity.applicationID, account: "vault"),
            backups: BackupStore(
                directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Ward/Backups", isDirectory: true),
                keep: { backupLimit }))
    }()

    enum State { case needsSetup, locked, unlocked }
    enum LockReason { case launch, manual, idle, sleep, screenLock }

    enum StoreError: LocalizedError {
        case wrongPassword, unavailable(String), corrupted, notUnlocked, newerFormat

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "Неверный пароль"
            case .unavailable(let reason): return "Хранилище недоступно: \(reason)"
            case .corrupted: return "Данные повреждены"
            case .notUnlocked: return "Хранилище заблокировано"
            case .newerFormat: return "Хранилище создано более новой версией Ward — обновите приложение"
            }
        }
    }

    @Published private(set) var state: State = .locked
    @Published private(set) var vault = Vault()
    @Published private(set) var lockReason: LockReason = .launch
    @Published private(set) var lastBackupAt: Date?
    /// Изменения сохраняются, но резервная копия не пишется (например, кончилось место).
    @Published private(set) var backupProblem: String?
    @Published var lastError: String?
    /// Итог проверки по базе утечек: запись → сколько раз её пароль встречался. Привязан к `updatedAt`:
    /// после смены пароля старый результат не относится к новому. Только в памяти, стирается при блокировке.
    @Published private(set) var breaches: [UUID: (updatedAt: Date, count: Int)] = [:]
    @Published private(set) var breachCheckedAt: Date?
    var onBackup: (() -> Void)?

    let backups: BackupStore
    private var worker: VaultWorker
    private var snapshot: VaultWorker.Snapshot
    private(set) var generation: UUID

    func isCurrent(_ generation: UUID) -> Bool { state == .unlocked && self.generation == generation }
    /// Промахи, которые не удалось записать в связку ключей: задержка всё равно растёт до перезапуска.
    private var unrecordedFailures = 0
    /// Переживает перезапуск (хранится рядом с хранилищем): иначе «Выйти из Ward» и открыть снова обнуляло бы задержку.
    private var failedUnlocks: Int { snapshot.failedUnlocks + unrecordedFailures }
    /// Открытый редактор записывает сюда свой черновик перед блокировкой и выходом — пока ключ ещё в памяти.
    private var draftSaver: (id: UUID, value: () -> EntryDraft?)?

    init(storage: VaultStorage, backups: BackupStore) {
        self.backups = backups
        // Раньше счётчик лежал в UserDefaults, где его мог обнулить любой процесс.
        UserDefaults.standard.removeObject(forKey: "failedUnlocks")
        worker = VaultWorker(storage: storage, backups: backups)
        snapshot = worker.initial
        generation = worker.generation
        lastBackupAt = backups.latestDate()
        sync()
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = snapshot.state { return reason }
        return nil
    }

    private func sync() {
        vault = snapshot.vault
        switch snapshot.state {
        case .needsSetup: state = .needsSetup
        case .unlocked: state = .unlocked
        case .locked, .unavailable: state = .locked
        }
        if state != .unlocked {
            breaches = [:]
            breachCheckedAt = nil
        }
    }

    private func accept(_ next: VaultWorker.Snapshot, generation: UUID) throws {
        guard self.generation == generation else { throw CancellationError() }
        guard next.revision >= snapshot.revision else { return }
        snapshot = next
        sync()
    }

    // MARK: - Доступ

    /// Повторное чтение хранилища, которое не удалось прочитать (например, отклонили запрос связки ключей).
    func reload() async {
        guard unavailableReason != nil else { return }
        let generation = generation
        do {
            let result = try await worker.perform(generation: generation) { $0.reload() }
            try accept(result.snapshot, generation: generation)
        } catch { lastError = error.localizedDescription }
    }

    func setup(password: String) async throws {
        generation = worker.invalidate()
        let generation = generation
        let key = VaultCrypto.newVaultKey()
        let slot = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.makeSlot(for: key, password: password)
        }.value
        let result = try await worker.perform(generation: generation) { try $0.create(key: key, slot: slot) }
        try accept(result.snapshot, generation: generation)
        await adoptSecuritySettings()
        await assignOrphans()
        guard isCurrent(generation) else { throw CancellationError() }
    }

    func unlock(password: String) async throws {
        guard state != .unlocked else { return }
        generation = worker.invalidate()
        let generation = generation
        let reloaded = try await worker.perform(generation: generation) { $0.reload() }
        try accept(reloaded.snapshot, generation: generation)
        if let reason = unavailableReason { throw StoreError.unavailable(reason) }
        guard let slot = snapshot.slot else { throw StoreError.notUnlocked }
        let key = try await openSlotThrottled(slot, password: password, generation: generation)
        guard state != .unlocked else { return }
        do {
            let result = try await worker.perform(generation: generation) { try $0.unlock(key: key) }
            try accept(result.snapshot, generation: generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch VaultCryptoError.unsupportedFormat {
            throw StoreError.newerFormat
        } catch {
            throw StoreError.corrupted
        }
        await adoptSecuritySettings()
        await assignOrphans()
        guard isCurrent(generation) else { throw CancellationError() }
    }

    var sshAgentEnabledWhileLocked: Bool { snapshot.sshAgentEnabled }
    var browserEnabledWhileLocked: Bool { snapshot.browserEnabled }

    func setDraftSaver(id: UUID, _ value: @escaping () -> EntryDraft?) { draftSaver = (id, value) }

    func clearDraftSaver(id: UUID) {
        if draftSaver?.id == id { draftSaver = nil }
    }

    /// Перед выходом из Ward: недописанная запись остаётся черновиком.
    func flushDraft() async {
        if state == .unlocked, let saver = draftSaver {
            if let draft = saver.value() { await saveDraft(draft) }
            else { await removeDraft(saver.id) }
        }
        await worker.drain()
    }

    func prepareForTermination(completion: @escaping @Sendable () -> Void) {
        lock(reason: .manual)
        worker.drain(completion: completion)
    }

    var drafts: [EntryDraft] { vault.drafts.sorted { $0.savedAt > $1.savedAt } }
    func draft(_ id: UUID) -> EntryDraft? { vault.draft(id) }

    /// Черновик пишется часто (после паузы в наборе) — без резервной копии на каждое нажатие.
    @discardableResult
    func saveDraft(_ draft: EntryDraft) async -> Bool {
        guard state == .unlocked else { return false }
        guard vault.draft(draft.id) != draft else { return true }
        return await change(backup: false) { $0.saveDraft(draft) }
    }

    func removeDraft(_ id: UUID) async {
        guard state == .unlocked, vault.draft(id) != nil else { return }
        await change(backup: false) { $0.removeDraft(id) }
    }

    func lock(reason: LockReason) {
        let wasUnlocked = state == .unlocked
        generation = worker.invalidate()
        let saver = wasUnlocked ? draftSaver : nil
        let draft = saver?.value()
        draftSaver = nil
        let generation = generation
        worker.lock(draft: draft, removingDraft: draft == nil ? saver?.id : nil) { [weak self] next, problem in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                try? self.accept(next, generation: generation)
                if let problem { self.lastError = "Черновик не сохранился: \(problem)" }
            }
        }
        guard wasUnlocked else { return }
        lockReason = reason
        snapshot = snapshot.locked()
        vault = Vault()
        breaches = [:]
        breachCheckedAt = nil
        keyIssueCache = [:]
        state = .locked
    }

    func changePassword(current: String, new: String) async throws {
        guard state == .unlocked, let slot = snapshot.slot else { throw StoreError.notUnlocked }
        let generation = generation
        _ = try await openSlotThrottled(slot, password: current, generation: generation)
        let newKey = VaultCrypto.newVaultKey()
        let newSlot = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.makeSlot(for: newKey, password: new)
        }.value
        try Task.checkCancellation()
        guard isCurrent(generation) else { throw CancellationError() }
        self.generation = worker.invalidate()
        let rekeyGeneration = self.generation
        let keep = Prefs.shared.backupsToKeep
        let result = try await worker.perform(generation: rekeyGeneration) {
            $0.setBackupLimit(keep)
            try $0.rekey(key: newKey, slot: newSlot)
        }
        try accept(result.snapshot, generation: rekeyGeneration)
        noteBackup()
    }

    /// Проверка мастер-пароля с нарастающей задержкой: после трёх промахов 1, 2, 4… до 30 с на попытку.
    /// Общая для разблокировки и смены пароля — иначе форма смены была бы перебором без задержки.
    private func openSlotThrottled(_ slot: KeySlot, password: String, generation: UUID) async throws -> SymmetricKey {
        if failedUnlocks >= 3 {
            try await Task.sleep(for: .seconds(min(1 << min(failedUnlocks - 3, 5), 30)))
        }
        do {
            let key = try await Self.openSlot(slot, password: password)
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            await recordUnlock(succeeded: true, generation: generation)
            return key
        } catch StoreError.wrongPassword {
            await recordUnlock(succeeded: false, generation: generation)
            throw StoreError.wrongPassword
        }
    }

    private func recordUnlock(succeeded: Bool, generation: UUID) async {
        do {
            let result = try await worker.perform(generation: generation) { try $0.recordUnlock(succeeded: succeeded) }
            try accept(result.snapshot, generation: generation)
            unrecordedFailures = 0
        } catch {
            guard self.generation == generation, !(error is CancellationError) else { return }
            // Задержка перебора не должна пропасть из-за того, что счётчик не записался.
            unrecordedFailures = succeeded ? 0 : unrecordedFailures + 1
        }
    }

    private static func openSlot(_ slot: KeySlot, password: String) async throws -> SymmetricKey {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.openSlot(slot, password: password)
            }.value
        } catch VaultCryptoError.wrongPassword {
            throw StoreError.wrongPassword
        } catch VaultCryptoError.unsupportedKDF {
            throw StoreError.newerFormat
        } catch {
            throw StoreError.corrupted
        }
    }

    /// Бросает, если изменение не сохранилось — для мест, которые сами показывают итог (импорт).
    private func commit<Value>(backup: Bool = true, _ body: @escaping (inout Vault) throws -> Value) async throws -> Value {
        guard state == .unlocked else { throw StoreError.notUnlocked }
        let generation = generation
        let keep = Prefs.shared.backupsToKeep
        let result = try await worker.perform(generation: generation) { session in
            session.setBackupLimit(keep)
            return try session.updateReturning(backup: backup, body).value
        }
        try accept(result.snapshot, generation: generation)
        if backup { noteBackup() }
        return result.value
    }

    @discardableResult
    private func change(backup: Bool = true, _ body: @escaping (inout Vault) throws -> Void) async -> Bool {
        do {
            try await commit(backup: backup, body)
            return true
        } catch {
            if error is CancellationError { return false }
            lastError = "Не удалось сохранить: \(error.localizedDescription)"
            return false
        }
    }

    private func noteBackup() {
        if let error = snapshot.backupProblem {
            let firstFailure = backupProblem == nil
            backupProblem = "Резервная копия не записалась: \(error)"
            if firstFailure {
                lastError = "Изменение сохранено, но резервная копия не записалась: \(error)"
            }
        } else {
            backupProblem = nil
            lastBackupAt = Date()
            onBackup?()
        }
    }

    // MARK: - Настройки безопасности

    /// Хранилище, созданное до переноса настроек внутрь, один раз забирает их из UserDefaults.
    /// Настройки, добавленные в хранилище позже (число копий, зеркало), переезжают туда так же.
    private func adoptSecuritySettings() async {
        if let saved = vault.security {
            Prefs.shared.apply(saved)
            guard saved.backupsToKeep == nil || saved.mirrorBackupPath == nil else { return }
        }
        let settings = Prefs.shared.security
        if await change(backup: false, { $0.security = settings }) {
            Prefs.shared.forgetLegacySecurity()
        }
    }

    func saveSecurity(_ settings: SecuritySettings) async {
        guard state == .unlocked, vault.security != settings else { return }
        let generation = generation
        if !(await change({ $0.security = settings })), isCurrent(generation) {
            Prefs.shared.apply(vault.security ?? SecuritySettings())
        }
    }

    // MARK: - Записи

    var active: [Entry] { vault.entries.filter { !$0.isDeleted } }
    var trashed: [Entry] { vault.entries.filter(\.isDeleted) }

    func entry(_ id: UUID?) -> Entry? {
        guard let id else { return nil }
        return vault.entries.first { $0.id == id }
    }

    @discardableResult
    func save(_ entry: Entry, requireExisting: Bool = false) async -> Bool {
        await change { vault in
            var entry = entry
            let current = vault.entries.first(where: { $0.id == entry.id })
            if requireExisting && current == nil { throw VaultSessionError.noSuchEntry }
            if let current {
                entry.favorite = current.favorite
                entry.deletedAt = current.deletedAt
                entry.lastUsedAt = current.lastUsedAt
                entry.useCount = current.useCount
                entry.passkeys = current.passkeys
                entry.history = current.history
                entry.passwordUpdatedAt = current.passwordUpdatedAt
                entry.createdAt = current.createdAt
                if entry.reminder != nil { entry.reminder?.lastDoneAt = current.reminder?.lastDoneAt }
            }
            vault.upsert(entry)
        }
    }

    func markUsed(_ id: UUID) async {
        await change(backup: false) {
            $0.modifyEntry(id) {
                $0.lastUsedAt = Date()
                $0.useCount += 1
            }
        }
    }

    @discardableResult
    func addPasskey(_ passkey: Passkey, to entryID: UUID) async -> Bool {
        await change { try $0.addPasskey(passkey, to: entryID) }
    }

    func removePasskey(_ passkeyID: Data, from entryID: UUID) async {
        await change { $0.modifyEntry(entryID) { $0.passkeys.removeAll { $0.id == passkeyID } } }
    }

    /// «Последний вход» passkey — без резервной копии: это не изменение данных, а отметка.
    func touchPasskey(_ passkeyID: Data) async {
        guard let owner = vault.passkey(id: passkeyID)?.entry.id else { return }
        await change(backup: false) {
            $0.modifyEntry(owner) { entry in
                if let i = entry.passkeys.firstIndex(where: { $0.id == passkeyID }) { entry.passkeys[i].lastUsedAt = Date() }
            }
        }
    }

    func toggleFavorite(_ id: UUID) async { await change { $0.modifyEntry(id) { $0.favorite.toggle() } } }
    @discardableResult
    func markReminderDone(_ id: UUID) async -> Bool { await change { $0.modifyEntry(id) { $0.reminder?.lastDoneAt = Date() } } }
    func trash(_ id: UUID) async { await change { $0.modifyEntry(id) { $0.deletedAt = Date() } } }
    func restore(_ id: UUID) async { await change { $0.modifyEntry(id) { $0.deletedAt = nil } } }
    func purge(_ id: UUID) async { await change { $0.purge([id]) } }
    func emptyTrash() async { await change { $0.purge(Set($0.entries.filter(\.isDeleted).map(\.id))) } }

    func sshKey(for entry: Entry) -> (key: SSHKey, source: Entry?)? { vault.sshKey(for: entry) }
    func certificate(for entry: Entry) -> (bundle: CertificateBundle, source: Entry?)? { vault.certificate(for: entry) }
    func entriesLinking(to id: UUID) -> [Entry] { vault.entriesLinking(to: id) }

    // MARK: - Проекты

    func project(_ id: UUID?) -> Project? { vault.project(id) }
    func tree(in space: VaultSpace, company: UUID?) -> [(project: Project, depth: Int)] {
        vault.tree(in: space, company: space == .work ? company : nil)
    }
    func children(of id: UUID) -> [Project] {
        guard let project = project(id) else { return [] }
        return vault.children(of: id, in: project.space, company: project.companyID)
    }

    var companies: [Company] { vault.sortedCompanies }
    func connections(for entry: Entry) -> [Entry] { vault.connections(for: entry) }
    func title(of step: PreStep) -> String { vault.title(of: step) }
    func entriesUsing(connection id: UUID) -> [Entry] { vault.entriesUsing(connection: id) }
    func company(_ id: UUID?) -> Company? { vault.company(id) }
    func companyID(of entry: Entry) -> UUID? { vault.companyID(of: entry) }
    func isEmpty(company id: UUID) -> Bool { vault.isEmpty(company: id) }

    @discardableResult
    func save(_ company: Company) async -> Bool { await change { $0.upsert(company) } }

    @discardableResult
    func deleteCompany(_ id: UUID) async -> Bool {
        guard vault.isEmpty(company: id) else { return false }
        do {
            return try await commit { vault in
                guard vault.isEmpty(company: id) else { return false }
                vault.removeCompany(id)
                return true
            }
        } catch {
            if !(error is CancellationError) { lastError = "Не удалось сохранить: \(error.localizedDescription)" }
            return false
        }
    }

    /// Всё рабочее без компании (старое хранилище, импорт, восстановление из копии) — в компанию.
    private func assignOrphans() async {
        var probe = vault
        guard probe.assignOrphansToCompany(defaultName: "Компания") else { return }
        await change(backup: false) { $0.assignOrphansToCompany(defaultName: "Компания") }
    }
    func ancestors(of id: UUID) -> [Project] { vault.ancestors(of: id) }
    func path(of id: UUID) -> String { vault.path(of: id) }
    func possibleParents(for project: Project) -> [Project] { vault.possibleParents(for: project) }

    func service(_ id: UUID?) -> Service? { vault.service(id) }
    func services(in space: VaultSpace, company: UUID?) -> [Service] {
        vault.services(in: space, company: space == .work ? company : nil)
    }
    func services(of projectID: UUID) -> [Service] { vault.services(of: projectID) }

    @discardableResult
    func save(_ service: Service, renamingEnvironments renames: [String: String] = [:]) async -> Bool {
        await change { $0.upsert(service, renamingEnvironments: renames) }
    }
    func deleteService(_ id: UUID) async { await change { $0.removeService(id) } }

    func linkService(_ id: UUID, to projectID: UUID) async {
        await change { vault in
            guard var service = vault.service(id), !service.projectIDs.contains(projectID) else { return }
            service.projectIDs.append(projectID)
            vault.upsert(service)
        }
    }

    @discardableResult
    func save(_ project: Project, renamingEnvironments renames: [String: String] = [:]) async -> Bool {
        await change { $0.upsert(project, renamingEnvironments: renames) }
    }
    func deleteProject(_ id: UUID) async { await change { $0.removeProject(id) } }

    // MARK: - Производные

    func whereLabel(_ entry: Entry) -> String {
        let space = entry.space == .work ? "Работа" : "Личное"
        let location = vault.location(of: entry)
        return location.isEmpty ? space : "\(space) › \(location)"
    }

    /// Контекст поиска: где лежит запись и, для интеграций, какие проекты ей пользуются.
    func searchContext(_ entry: Entry) -> String {
        (entry.space == .work ? "Работа " : "Личное ") + vault.searchContext(of: entry)
    }

    func reuseCounts() -> [String: Int] {
        PasswordAudit.reuseCounts(vault.entries)
    }

    func issues(_ entry: Entry, reuse: [String: Int]) -> (weak: Bool, reusedWith: Int) {
        guard entry.authKind == .password, !entry.secret.isEmpty else { return (false, 0) }
        return (entry.strength.score <= 1, max((reuse[entry.secret] ?? 1) - 1, 0))
    }

    func hasIssues(_ entry: Entry, reuse: [String: Int]) -> Bool {
        let i = issues(entry, reuse: reuse)
        return i.weak || i.reusedWith > 0 || keyIssue(entry) != nil || entry.hygieneIssue() != nil || breachCount(entry) > 0
    }

    func breachCount(_ entry: Entry) -> Int {
        guard let found = breaches[entry.id], found.updatedAt == entry.updatedAt else { return 0 }
        return found.count
    }

    /// Проверяет пароли живых записей по Have I Been Pwned. Наружу — только первые 5 символов SHA-1 каждого пароля.
    func checkBreaches() async throws -> (checked: Int, found: Int) {
        guard state == .unlocked else { throw StoreError.notUnlocked }
        // Только пароли: токены API в базе утечек паролей искать бессмысленно, а отправлять лишнее — незачем.
        let generation = generation
        let checked = active.filter { $0.authKind == .password && !$0.secret.isEmpty }
        let passwords = Set(checked.map(\.secret))
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let result = try await PwnedPasswords.check(passwords) { prefix in
            var request = URLRequest(url: PwnedPasswords.rangeURL(prefix: prefix))
            // Ответ дополняется фиктивными строками — по размеру ответа не понять, какой префикс спрашивали.
            request.setValue("true", forHTTPHeaderField: "Add-Padding")
            request.setValue("Ward-password-manager", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return String(decoding: data, as: UTF8.self)
        }
        guard isCurrent(generation) else { throw CancellationError() }
        var found: [UUID: (updatedAt: Date, count: Int)] = [:]
        for entry in checked { found[entry.id] = (entry.updatedAt, result[entry.secret] ?? 0) }
        breaches = found
        breachCheckedAt = Date()
        return (result.count, result.values.filter { $0 > 0 }.count)
    }

    /// Разбор ключей и сертификатов дорогой, а список перерисовывается часто — помним итог до изменения записи
    /// (и до смены дня: «скоро истечёт» зависит от даты).
    /// Ключ и сертификат могут быть взяты из другой записи — её изменение тоже сбрасывает кэш.
    private var keyIssueCache: [UUID: (signature: [Date], day: Date, issue: String?)] = [:]

    func keyIssue(_ entry: Entry) -> String? {
        guard entry.hasSSH || entry.hasCertificate else { return nil }
        let signature = [entry.updatedAt] + [entry.sshKeyEntryID, entry.certificateEntryID]
            .compactMap { self.entry($0)?.updatedAt }
        let day = Calendar.current.startOfDay(for: Date())
        if let cached = keyIssueCache[entry.id], cached.signature == signature, cached.day == day {
            return cached.issue
        }
        let issue = vault.keyIssue(for: entry)
        keyIssueCache[entry.id] = (signature, day, issue)
        return issue
    }

    var dueEntries: [Entry] {
        let now = Date()
        return active.filter { $0.reminder?.isDue(at: now) == true }
    }

    // MARK: - Импорт и экспорт

    func exportBackup(to url: URL) async throws {
        let generation = generation
        _ = try await worker.perform(generation: generation) {
            try BackupStore.writePrivate($0.exportData(), to: url)
        }
        guard isCurrent(generation) else { throw CancellationError() }
    }

    /// Копия открывается паролем, с которым её сделали; добавляются только недостающие записи.
    func importBackup(from url: URL, password: String) async throws -> Int {
        guard state == .unlocked else { throw StoreError.notUnlocked }
        let generation = generation
        let other: VaultEnvelope
        do {
            other = try await Task.detached { try JSONDecoder().decode(VaultEnvelope.self, from: Self.readLimited(url)) }.value
        } catch {
            throw StoreError.corrupted
        }
        let key = try await Self.openSlot(other.slot, password: password)
        let incoming: Vault
        do {
            incoming = try await Task.detached { try VaultCrypto.decode(other, key: key) }.value
        } catch VaultCryptoError.unsupportedFormat {
            throw StoreError.newerFormat
        } catch {
            throw StoreError.corrupted
        }
        guard isCurrent(generation) else { throw CancellationError() }
        return try await commit {
            let added = $0.merge(incoming)
            $0.assignOrphansToCompany(defaultName: "Компания")
            return added
        }
    }

    /// `company` — куда во «Работе» попадут новые записи (общими доступами компании).
    func importCodes(_ codes: [TOTPConfig], space: VaultSpace, company: UUID?) async throws -> (added: Int, duplicates: Int) {
        return try await commit {
            let before = Set($0.entries.map(\.id))
            let result = $0.importCodes(codes, space: space)
            Self.place(&$0, newSince: before, company: space == .work ? company : nil)
            return result
        }
    }

    nonisolated private static func place(_ vault: inout Vault, newSince before: Set<UUID>, company: UUID?) {
        for i in vault.entries.indices where !before.contains(vault.entries[i].id) {
            vault.entries[i].companyID = company
        }
        vault.assignOrphansToCompany(defaultName: "Компания")
    }

    func importCSV(from url: URL, space: VaultSpace, company: UUID?) async throws -> (added: Int, duplicates: Int) {
        guard state == .unlocked else { throw StoreError.notUnlocked }
        let generation = generation
        let entries = try await Task.detached { CSVImport.entries(from: try Self.readText(url), space: space) }.value
        guard isCurrent(generation) else { throw CancellationError() }
        return try await commit {
            let before = Set($0.entries.map(\.id))
            let result = $0.importEntries(entries)
            Self.place(&$0, newSince: before, company: space == .work ? company : nil)
            return result
        }
    }

    /// Экспорт и копия даже десятков тысяч паролей — единицы мегабайт; больше или не обычный файл — не наш файл.
    nonisolated private static func readLimited(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 64 << 20 else { throw CocoaError(.fileReadTooLarge) }
        return try Data(contentsOf: url)
    }

    /// Excel в русской Windows сохраняет «CSV» в cp1251, остальные — в UTF-8 (иногда UTF-16 с BOM).
    nonisolated private static func readText(_ url: URL) throws -> String {
        let data = try readLimited(url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1251) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    #if DEBUG
    /// Для снимков интерфейса: хранилище только в памяти, связка ключей не трогается.
    func loadDemo(_ demo: Vault) async {
        worker.invalidate()
        worker = VaultWorker(storage: MemoryVaultStorage(), backups: nil)
        generation = worker.generation
        snapshot = worker.initial
        let generation = generation
        let key = VaultCrypto.newVaultKey()
        do {
            let result = try await worker.perform(generation: generation) {
                let slot = try VaultCrypto.makeSlot(for: key, password: "demo", iterations: 1)
                try $0.create(key: key, slot: slot)
                try $0.update(backup: false) { $0 = demo }
            }
            try accept(result.snapshot, generation: generation)
        } catch { lastError = error.localizedDescription }
    }
    #endif
}

#if DEBUG
private final class MemoryVaultStorage: VaultStorage {
    private var data: Data?
    func read() throws -> Data? { data }
    func create(_ data: Data) throws { self.data = data }
    func update(_ data: Data) throws { self.data = data }
}
#endif
