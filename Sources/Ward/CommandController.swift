import AppKit
import Combine
import WardCore

@MainActor
final class CommandController: ObservableObject {
    static let shared = CommandController()
    @Published private(set) var problem: String?
    private var server: BrowserBridgeServer?
    private var cancellables: Set<AnyCancellable> = []
    private var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var grants = CommandGrants()
    private var selections = CommandGrants()
    private let prompt = CommandPrompt()
    private let peers = CommandConnections()
    private var generation = 0
    private let suppliedStore: VaultStore?
    private let approval: ((String, String, [String], String) async -> Int?)?
    private var store: VaultStore { suppliedStore ?? .shared }

    init(store: VaultStore? = nil, approval: ((String, String, [String], String) async -> Int?)? = nil) {
        suppliedStore = store
        self.approval = approval
    }

    func start() {
        store.$state.sink { [weak self] _ in
            self?.revoke()
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        Prefs.shared.$commandAccessEnabled.dropFirst().sink { [weak self] _ in
            self?.revoke()
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        Prefs.shared.$commandApprovalMinutes.dropFirst().sink { [weak self] _ in self?.revoke() }
            .store(in: &cancellables)
        refresh()
    }

    func revoke() {
        generation += 1
        grants.revokeAll()
        selections.revokeAll()
        tasks.values.forEach { $0.task.cancel() }
        tasks = [:]
        prompt.cancelAll()
    }

    func stop() {
        revoke()
        server?.stop()
        server = nil
        peers.removeAll()
    }

    private func refresh() {
        guard store.state == .unlocked, Prefs.shared.commandAccessEnabled else {
            stop()
            return
        }
        guard server == nil else { return }
        guard let team = BrowserPeerCheck.ownTeam() else {
            problem = "Для доступа из терминала нужна подпись Apple Development."
            return
        }
        let peers = peers
        let server = BrowserBridgeServer(socketPath: CommandWire.socketPath, admit: {
            CommandPeerCheck.matches($0.auditToken, identifier: CommandPeerCheck.identifier, team: team)
        }, disconnected: { [weak self] connection in
            peers.remove(connection)
            Task { @MainActor in self?.tasks.removeValue(forKey: connection)?.task.cancel() }
        }, connected: { connection, peer in
            peers.insert(peer, for: connection)
        }, handle: { [weak self] connection, data, reply in
            Task { @MainActor in
                guard let self else { reply(Data("{}".utf8)); return }
                self.receive(data, connection: connection, reply: reply)
            }
        })
        do {
            try FileManager.default.createDirectory(atPath: (CommandWire.socketPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try server.start()
            self.server = server
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    private func receive(_ data: Data, connection: UUID, reply: @escaping @Sendable (Data) -> Void) {
        guard tasks[connection] == nil else {
            reply(response(error: "В этом соединении уже есть запрос."))
            return
        }
        let token = UUID()
        let task = Task {
            let result = await authorize(data, connection: connection)
            reply((try? JSONEncoder().encode(result)) ?? Data("{}".utf8))
            if tasks[connection]?.token == token { tasks.removeValue(forKey: connection) }
        }
        tasks[connection] = (token, task)
    }

    private func response(error: String) -> Data {
        (try? JSONEncoder().encode(CommandResponse(error: error))) ?? Data("{}".utf8)
    }

    private func authorize(_ data: Data, connection: UUID) async -> CommandResponse {
        guard store.state == .unlocked, Prefs.shared.commandAccessEnabled,
              let peer = peers.get(connection), let team = BrowserPeerCheck.ownTeam(),
              CommandPeerCheck.matches(peer.auditToken, identifier: CommandPeerCheck.identifier, team: team) else {
            return CommandResponse(error: "Запрос отклонён: разблокируйте Ward, включите доступ и проверьте запись SSH.")
        }
        let caller = CommandPeerCheck.caller(of: peer.pid)
        let currentPeer = { [peers] in
            peers.get(connection) != nil
                && CommandPeerCheck.matches(peer.auditToken, identifier: CommandPeerCheck.identifier, team: team)
                && CommandPeerCheck.caller(of: peer.pid)?.identity == caller?.identity
        }
        if let search = try? JSONDecoder().decode(CommandServerSearch.self, from: data) {
            return await findServers(search, caller: caller, isCurrentPeer: currentPeer)
        }
        guard let request = try? JSONDecoder().decode(SudoRequest.self, from: data) else {
            return CommandResponse(error: "Некорректный запрос.")
        }
        return await approve(request, caller: caller, isCurrentPeer: currentPeer)
    }

    func findServers(_ search: CommandServerSearch, caller: (identity: String, path: String)?,
                     isCurrentPeer: () -> Bool) async -> CommandResponse {
        guard store.state == .unlocked, Prefs.shared.commandAccessEnabled, search.isValid, isCurrentPeer() else {
            return CommandResponse(error: "Поиск недоступен: разблокируйте Ward и включите «Терминал и sudo».")
        }
        guard let caller else { return CommandResponse(error: "Не удалось определить процесс запроса.") }
        let matches = CommandServerMatch.find(search, in: store.vault)
        guard !matches.isEmpty else { return CommandResponse(error: "Подходящие записи SSH не найдены. Уточните название или адрес сервера.") }
        let revision = generation
        let vaultGeneration = store.generation
        let choice: Int?
        if let approval {
            choice = await approval("Выберите сервер для Codex", search.query, matches.map(\.title), "Отмена")
        } else {
            choice = await prompt.select(matches, query: search.query, caller: caller.path)
        }
        guard !Task.isCancelled, let choice, matches.indices.contains(choice), revision == generation,
              store.isCurrent(vaultGeneration), Prefs.shared.commandAccessEnabled, isCurrentPeer(),
              let entry = store.entry(matches[choice].entryID), let credentials = SudoCredentials(entry: entry),
              CommandServerMatch.find(search, in: store.vault).contains(matches[choice]) else {
            return CommandResponse(error: "Выбор отменён или запись изменилась.")
        }
        selections.allow(entryID: entry.id, identity: caller.identity, credentials: credentials,
                         minutes: min(60, max(5, Prefs.shared.commandApprovalMinutes)))
        var result = CommandResponse()
        result.selectedEntryID = entry.id
        return result
    }

    func approve(_ request: SudoRequest, caller: (identity: String, path: String)?,
                 isCurrentPeer: () -> Bool) async -> CommandResponse {
        guard store.state == .unlocked, Prefs.shared.commandAccessEnabled, request.isValid, isCurrentPeer(),
              let entry = store.entry(request.entryID), let credentials = SudoCredentials(entry: entry) else {
            return CommandResponse(error: "Запрос отклонён.")
        }
        let identity = caller?.identity ?? UUID().uuidString
        if request.selectionRequired == true,
           !selections.permits(entryID: entry.id, identity: identity, credentials: credentials) {
            return CommandResponse(error: "Сначала выберите эту запись в окне Ward через find_server. Выбор истёк или был отозван.")
        }
        let revision = generation
        let vaultGeneration = store.generation
        if !grants.permits(entryID: entry.id, identity: identity, credentials: credentials) {
            let minutes = min(60, max(0, Prefs.shared.commandApprovalMinutes))
            var options = ["Разрешить один раз"]
            if caller != nil, minutes > 0 { options.append("Для процесса и сервера на \(minutes) мин.") }
            let choice: Int?
            if let approval {
                choice = await approval("Выполнить команду через sudo?", request.arguments.map(SudoRequest.quote).joined(separator: " "), options, "Отклонить")
            } else {
                choice = await prompt.authorize(CommandServerMatch(entry: entry, credentials: credentials, in: store.vault),
                    caller: caller?.path ?? "Неизвестный процесс", command: request.arguments,
                    rememberMinutes: caller != nil ? minutes : 0)
            }
            guard !Task.isCancelled, let choice, revision == generation,
                  store.isCurrent(vaultGeneration), Prefs.shared.commandAccessEnabled,
                  let current = store.entry(entry.id), SudoCredentials(entry: current) == credentials,
                  isCurrentPeer() else {
                return CommandResponse(error: "Запрос отменён или запись изменилась.")
            }
            if choice == 1 {
                grants.allow(entryID: entry.id, identity: identity, credentials: credentials, minutes: minutes)
            }
        }
        guard !Task.isCancelled, revision == generation else { return CommandResponse(error: "Запрос отменён.") }
        Toast.shared.show("sudo · \(entry.title)")
        return CommandResponse(credentials: credentials)
    }
}

private final class CommandConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: BrowserBridgeServer.Peer] = [:]

    func insert(_ peer: BrowserBridgeServer.Peer, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        values[id] = peer
    }

    func get(_ id: UUID) -> BrowserBridgeServer.Peer? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: id)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        values = [:]
    }
}
