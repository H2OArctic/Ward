import AppKit
import Combine
import SwiftUI
import WardCore

/// SSH-агент Ward: сокет, окно подтверждения, разблокировка по требованию.
@MainActor
final class AgentController: ObservableObject {
    static let shared = AgentController()

    static let socketPath: String = {
        #if DEBUG
        // Проверка агента на демо-данных — отдельный сокет, чтобы не задеть настоящий Ward.
        if let path = ProcessInfo.processInfo.environment["WARD_AGENT_SOCKET"] { return path }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ward/agent.sock").path
    }()
    /// Для ~/.ssh/config: путь с «~», в кавычках из-за пробела.
    static let configSnippet = "Host *\n    IdentityAgent \"~/Library/Application Support/Ward/agent.sock\""

    @Published private(set) var isRunning = false
    @Published private(set) var problem: String?
    @Published private(set) var keyCount = 0

    /// Показать окно разблокировки (быструю панель) — когда ключ просят у заблокированного Ward.
    var requestUnlock: (() -> Void)?

    private let backend = WardAgentBackend()
    private var server: SSHAgentServer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastMarked: [UUID: Date] = [:]

    func start(store: VaultStore) {
        backend.controller = self
        // Раньше признак лежал в UserDefaults — там его мог включить любой процесс. Теперь он рядом с хранилищем.
        UserDefaults.standard.removeObject(forKey: "sshAgentWanted")
        store.$state.sink { [weak self] state in
            guard let self else { return }
            if state != .unlocked {
                self.backend.forget()
                ApprovalPanel.shared.cancelAll()
                self.lastMarked = [:]
            }
            // Настройки из хранилища применяются уже после публикации состояния — берём их следующим тактом.
            DispatchQueue.main.async { self.refresh() }
        }.store(in: &cancellables)
        store.$vault.sink { [weak self, weak store] vault in
            guard let self, let store else { return }
            let settings = vault.security ?? Prefs.shared.security
            let unlocked = store.state == .unlocked
            if self.backend.update(unlocked: unlocked, enabled: settings.sshAgentEnabled,
                                   candidates: unlocked && settings.sshAgentEnabled ? Self.candidates(vault.entries.filter { !$0.isDeleted }) : [],
                                   confirm: settings.sshAgentConfirm) {
                ApprovalPanel.shared.cancelAll()
            }
            DispatchQueue.main.async { self.refresh() }
        }.store(in: &cancellables)
        Prefs.shared.$sshAgentEnabled.combineLatest(Prefs.shared.$sshAgentConfirm).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        refresh()
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    /// Передаёт агенту текущее состояние: разблокировано ли хранилище, какие ключи, нужны ли подтверждения.
    private func refresh() {
        let store = VaultStore.shared
        let unlocked = store.state == .unlocked
        // Пока заблокировано, настройку внутри хранилища не прочесть — берём её открытую копию из той же записи связки.
        let wanted = unlocked ? Prefs.shared.sshAgentEnabled : store.sshAgentEnabledWhileLocked
        let candidates = unlocked && wanted ? Self.candidates(store.active) : []
        keyCount = candidates.count
        // Сначала состояние, потом сокет: первый же запрос после bind должен застать актуальные ключи.
        if backend.update(unlocked: unlocked, enabled: wanted, candidates: candidates, confirm: Prefs.shared.sshAgentConfirm) {
            ApprovalPanel.shared.cancelAll()
        }
        run(wanted)
    }

    private func run(_ enabled: Bool) {
        guard enabled else {
            if server != nil {
                stop()
                // Выключили агент — расшифрованные ключи и разрешения больше не нужны.
                backend.forget()
            }
            problem = nil
            return
        }
        guard server == nil else { return }
        do {
            let directory = (Self.socketPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let server = SSHAgentServer(socketPath: Self.socketPath, backend: backend)
            try server.start()
            self.server = server
            isRunning = true
            problem = nil
        } catch {
            isRunning = false
            problem = error.localizedDescription
        }
    }

    /// Ключ, который можно отдать: из живой записи, со своим приватным ключом, разрешён для агента.
    struct Candidate {
        let entryID: UUID
        let title: String
        let blob: Data
        let privateKey: String
        let passphrase: String
    }

    static func candidates(_ entries: [Entry]) -> [Candidate] {
        var seen = Set<Data>()
        return entries.compactMap { entry in
            guard let ssh = entry.ssh, ssh.useInAgent, let blob = ssh.agentReadiness.blob,
                  seen.insert(blob).inserted else { return nil }
            return Candidate(entryID: entry.id, title: entry.title, blob: blob, privateKey: ssh.privateKey, passphrase: ssh.passphrase)
        }
    }

    func noteUse(_ candidate: Candidate, client: SSHAgentClient, panelShown: Bool) {
        // Без окна человек хотя бы видит, что ключ использовали — в том числе по «разрешить на 10 минут».
        if !panelShown { Toast.shared.show("SSH-ключ «\(candidate.title)» — \(client.displayName)") }
        // «Последнее использование» — не на каждую подпись: git rebase с подписью коммитов — это сотни подписей,
        // а каждая отметка перешифровывает и перезаписывает хранилище.
        let store = VaultStore.shared
        guard store.state == .unlocked, (lastMarked[candidate.entryID] ?? .distantPast) < Date().addingTimeInterval(-300) else { return }
        lastMarked[candidate.entryID] = Date()
        Task { await store.markUsed(candidate.entryID) }
    }

    func reportFailure(_ candidate: Candidate, _ error: Error) {
        Toast.shared.show("SSH-ключ «\(candidate.title)» не расшифровался: \(error.localizedDescription)")
    }

    func askUnlock() {
        requestUnlock?()
        Toast.shared.show("SSH просит ключ — разблокируйте Ward")
    }
}

/// Работает на потоках соединений. Состояние хранилища ему присылает приложение (`update`) — сам агент
/// в главный поток не ходит и ждать его не может, поэтому взаимная блокировка исключена.
final class WardAgentBackend: SSHAgentBackend, @unchecked Sendable {
    weak var controller: AgentController?
    private let approval: ((AgentController.Candidate, Data, SSHAgentClient) -> ApprovalPanel.Decision)?

    init(approval: ((AgentController.Candidate, Data, SSHAgentClient) -> ApprovalPanel.Decision)? = nil) {
        self.approval = approval
    }

    private let state = NSCondition()
    // Под `state`:
    private var unlocked = false
    private var enabled = false
    private var confirm = true
    private var candidates: [AgentController.Candidate] = []
    /// Растёт при блокировке и выключении агента: начатые до этого подписи не должны ни закончиться, ни оставить ключ в памяти.
    private var generation = 0
    private var loaded: [Data: (source: String, key: SSHSigningKey)] = [:]
    private var approvedUntil: [String: Date] = [:]
    private var unlockPrompt: Date?

    @discardableResult
    func update(unlocked: Bool, enabled: Bool, candidates: [AgentController.Candidate], confirm: Bool) -> Bool {
        state.lock()
        let previous = self.candidates.map { [$0.entryID.uuidString, $0.title, $0.blob.base64EncodedString(), $0.privateKey, $0.passphrase] }
        let incoming = candidates.map { [$0.entryID.uuidString, $0.title, $0.blob.base64EncodedString(), $0.privateKey, $0.passphrase] }
        let changed = self.unlocked != unlocked || self.enabled != enabled || self.confirm != confirm || previous != incoming
        if changed {
            generation += 1
            approvedUntil = [:]
        }
        self.unlocked = unlocked
        self.enabled = enabled
        self.candidates = candidates
        self.confirm = confirm
        // Ключ удалили, отключили для агента или сменили — расшифрованная копия и разрешения не нужны.
        let current = Set(candidates.map { $0.blob.base64EncodedString() })
        let sources = Dictionary(candidates.map { ($0.blob, $0.privateKey + "\u{0}" + $0.passphrase) }, uniquingKeysWith: { first, _ in first })
        loaded = loaded.filter { sources[$0.key] == $0.value.source }
        approvedUntil = approvedUntil.filter { key, _ in current.contains(String(key.split(separator: "|").last ?? "")) }
        state.broadcast()
        state.unlock()
        return changed
    }

    func forget() {
        state.lock()
        generation += 1
        unlocked = false
        candidates = []
        loaded = [:]
        approvedUntil = [:]
        state.broadcast()
        state.unlock()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.lock()
        defer { state.unlock() }
        return self.generation == generation && unlocked && enabled
    }

    /// Хранилище заблокировано — просим разблокировать и ждём до минуты. Окно — не чаще раза в 30 секунд:
    /// посторонний процесс не должен уметь бесконечно открывать запрос мастер-пароля.
    private func waitUntilUnlocked() -> Bool {
        state.lock()
        defer { state.unlock() }
        guard enabled else { return false }
        if unlocked { return true }
        let now = Date()
        let sincePrompt = unlockPrompt.map { now.timeIntervalSince($0) } ?? .infinity
        if sincePrompt < 60 {
            // Окно уже открыто другим запросом — ждём вместе с ним.
        } else if sincePrompt < 90 {
            // Только что открывали, и разблокировать не стали — ещё полминуты не открываем снова.
            return false
        } else {
            unlockPrompt = now
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.controller?.askUnlock() }
            }
        }
        let deadline = (unlockPrompt ?? now).addingTimeInterval(60)
        while !unlocked && enabled {
            guard state.wait(until: deadline) else { break }
        }
        if unlocked { unlockPrompt = nil }
        return unlocked
    }

    func identities(for client: SSHAgentClient) -> [SSHAgentIdentity] {
        guard waitUntilUnlocked() else { return [] }
        state.lock()
        defer { state.unlock() }
        return candidates.map { SSHAgentIdentity(blob: $0.blob, comment: "Ward: \($0.title)") }
    }

    func sign(blob: Data, data: Data, flags: UInt32, client: SSHAgentClient) -> Data? {
        guard waitUntilUnlocked() else { return nil }
        state.lock()
        let generation = self.generation
        let candidate = candidates.first { $0.blob == blob }
        let confirm = self.confirm
        state.unlock()
        guard let candidate else { return nil }

        let remember = client.approvalIdentity.map { $0 + "|" + blob.base64EncodedString() }
        var panelShown = false
        // Проброс агента (ssh -A) подтверждается всегда: просит удалённый сервер, а не программа на этом Mac.
        if (confirm || client.isForwarded) && !isApproved(remember) {
            guard isCurrent(generation) else { return nil }
            if !isApproved(remember) {
                panelShown = true
                switch ask(candidate, data: data, client: client, generation: generation) {
                case .deny:
                    return nil
                case .once:
                    break
                case .tenMinutes:
                    state.lock()
                    if let remember, self.generation == generation { approvedUntil[remember] = Date().addingTimeInterval(600) }
                    state.unlock()
                }
            }
        }
        guard isCurrent(generation) else { return nil }
        let key: SSHSigningKey
        do {
            key = try load(candidate, generation: generation)
        } catch {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.controller?.reportFailure(candidate, error) }
            }
            return nil
        }
        // Расшифровка могла идти секунды — за это время Ward могли заблокировать.
        guard isCurrent(generation), let signature = try? key.sign(data, flags: flags), isCurrent(generation) else { return nil }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.controller?.noteUse(candidate, client: client, panelShown: panelShown) }
        }
        return signature
    }

    private func isApproved(_ remember: String?) -> Bool {
        guard let remember else { return false }
        state.lock()
        defer { state.unlock() }
        return (approvedUntil[remember] ?? .distantPast) > Date()
    }

    private func ask(_ candidate: AgentController.Candidate, data: Data, client: SSHAgentClient, generation: Int) -> ApprovalPanel.Decision {
        if let approval { return approval(candidate, data, client) }
        let semaphore = DispatchSemaphore(value: 0)
        let box = DecisionBox()
        let request = ApprovalPanel.Request(keyTitle: candidate.title, client: client.displayName,
                                            purpose: SSHAgentRequest.describe(data), forwarded: client.isForwarded,
                                            canRemember: client.approvalIdentity != nil)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard self?.isCurrent(generation) == true else { semaphore.signal(); return }
                ApprovalPanel.shared.show(request, isValid: { self?.isCurrent(generation) == true }) { result in
                    box.value = result
                    semaphore.signal()
                }
            }
        }
        // Панель сама отвечает «отклонить» через минуту — ждём с запасом.
        _ = semaphore.wait(timeout: .now() + 90)
        return box.value
    }

    private final class DecisionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var decision = ApprovalPanel.Decision.deny
        var value: ApprovalPanel.Decision {
            get { lock.lock(); defer { lock.unlock() }; return decision }
            set { lock.lock(); decision = newValue; lock.unlock() }
        }
    }

    /// Расшифровка (bcrypt) небыстрая — ключ держим в памяти до блокировки, выключения агента или правки записи.
    private func load(_ candidate: AgentController.Candidate, generation: Int) throws -> SSHSigningKey {
        let source = candidate.privateKey + "\u{0}" + candidate.passphrase
        state.lock()
        if let cached = loaded[candidate.blob], cached.source == source {
            state.unlock()
            return cached.key
        }
        state.unlock()
        let key = try SSHPrivateKeyLoader.load(candidate.privateKey, passphrase: candidate.passphrase)
        guard key.publicBlob == candidate.blob else { throw SSHSigningKey.Failure.corrupted }
        state.lock()
        if self.generation == generation && unlocked { loaded[candidate.blob] = (source, key) }
        state.unlock()
        return key
    }
}

// MARK: - Окно подтверждения

@MainActor
final class ApprovalPanel {
    static let shared = ApprovalPanel()

    enum Decision { case deny, once, tenMinutes }

    struct Request {
        let keyTitle: String
        let client: String
        /// Со слов самого запроса (имя пользователя, пространство подписи) — подделать его может и клиент.
        let purpose: String?
        let forwarded: Bool
        let canRemember: Bool
    }

    private var panel: KeyPanel?
    private let approvals = ApprovalQueue<Decision>()

    func show(_ request: Request, isValid: @escaping () -> Bool = { true }, completion: @escaping (Decision) -> Void) {
        Task { [self] in
            let decision = await approvals.ask(show: { [self] finish in
                guard isValid() else { finish(.deny); return }
                let panel = self.panel ?? makePanel()
                panel.contentView = NSHostingView(rootView: ApprovalView(request: request, onDecision: { finish($0) }))
                let size = panel.contentView?.fittingSize ?? NSSize(width: 460, height: 180)
                let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                if let frame = screen?.visibleFrame {
                    panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.2 - size.height,
                                          width: size.width, height: size.height), display: true)
                }
                panel.makeKeyAndOrderFront(nil)
            }, close: { [weak self] in self?.panel?.orderOut(nil) })
            completion(decision ?? .deny)
        }
    }

    /// При блокировке Ward ждущие запросы отклоняются.
    func cancelAll() { approvals.cancelAll() }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        self.panel = panel
        return panel
    }
}

private struct ApprovalView: View {
    let request: ApprovalPanel.Request
    let onDecision: (ApprovalPanel.Decision) -> Void
    /// Кнопки оживают не сразу: окно появляется, пока человек печатает в терминале, и случайные
    /// ⏎ или пробел не должны стать «Разрешить».
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: request.forwarded ? "network" : "key.horizontal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(request.forwarded ? Theme.danger : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background((request.forwarded ? Theme.danger : Theme.accent).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.forwarded ? "Удалённый сервер просит SSH-ключ" : "«\(request.client)» просит SSH-ключ")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(["«\(request.keyTitle)»", request.purpose].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(2)
                    if request.forwarded {
                        Text("Через проброс агента (ssh -A) из «\(request.client)». Разрешайте, только если сами запустили это на сервере.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dangerText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Отклонить") { onDecision(.deny) }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if request.canRemember && !request.forwarded {
                    Button("На 10 минут") { onDecision(.tenMinutes) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Не спрашивать 10 минут для этой программы, запущенной этим же экземпляром (например, этим git rebase)")
                        .disabled(!armed)
                }
                Button("Разрешить") { onDecision(.once) }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!armed)
            }
        }
        .padding(20)
        .frame(width: 460)
        .focusEffectDisabled()
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .environment(\.colorScheme, .dark)
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            armed = true
        }
    }
}
