import AppKit
import Combine
import SwiftUI
import WardCore

/// Мост с расширением Chrome: сокет для помощника native messaging, установка помощника и расширения,
/// ответы на запросы (учётки, заполнение, passkey) с подтверждением и разблокировкой по требованию.
@MainActor
final class BrowserController: ObservableObject {
    static let shared = BrowserController()

    static let hostName = WardIdentity.applicationID
    static let extensionID = "fddnjhiefjihmplhkkcemckakfmhplpc"
    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let socketPath: String = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["WARD_BROWSER_SOCKET"] { return path }
        #endif
        return support.appendingPathComponent("Ward/browser.sock").path
    }()
    /// Постоянная папка расширения: Chrome загружает распакованное расширение по пути, а Ward.app при сборке пересоздаётся.
    static let extensionFolder = support.appendingPathComponent("Ward/Chrome Extension", isDirectory: true)
    static let hostManifest: URL = {
        #if DEBUG
        // Демо-проверка ставит помощника в свой временный профиль Chrome, а не в настоящий.
        if let dir = ProcessInfo.processInfo.environment["WARD_BROWSER_MANIFEST_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("\(hostName).json")
        }
        #endif
        return support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/\(hostName).json")
    }()

    @Published private(set) var isRunning = false
    @Published private(set) var problem: String?
    @Published private(set) var lastRequestAt: Date?

    /// Показать окно разблокировки — когда расширение спрашивает у заблокированного Ward.
    var requestUnlock: (() -> Void)?

    private var server: BrowserBridgeServer?
    private var cancellables: Set<AnyCancellable> = []
    private var requests: [UUID: [String: (token: UUID, task: Task<Void, Never>)]] = [:]
    private var suppliedStore: VaultStore?
    private let approval: (String, String, [String], String) async -> Int?

    private var store: VaultStore { suppliedStore ?? .shared }

    init(store: VaultStore? = nil, approval: ((String, String, [String], String) async -> Int?)? = nil) {
        suppliedStore = store
        self.approval = approval ?? { await BrowserPrompt.shared.ask(title: $0, detail: $1, options: $2, decline: $3) }
    }

    func start(store: VaultStore) {
        suppliedStore = store
        store.$state.sink { [weak self] state in
            if state != .unlocked { self?.cancelRequests() }
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        Prefs.shared.$browserEnabled.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        refresh()
    }

    func stop() {
        cancelRequests()
        server?.stop()
        server = nil
        isRunning = false
    }

    private func cancelRequests(connection: UUID? = nil) {
        if let connection {
            requests.removeValue(forKey: connection)?.values.forEach { $0.task.cancel() }
        } else {
            requests.values.forEach { $0.values.forEach { $0.task.cancel() } }
            requests = [:]
            BrowserPrompt.shared.cancelAll()
        }
    }

    private func receive(_ data: Data, connection: UUID, reply: @escaping @Sendable (Data) -> Void) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let id = object["id"] as? Int
        if object["type"] as? String == "cancel", let target = object["requestID"] as? Int {
            requests[connection]?[String(target)]?.task.cancel()
            reply(Data("{}".utf8))
            return
        }
        guard let id, requests.values.reduce(0, { $0 + $1.count }) < 32,
              requests[connection]?[String(id)] == nil else {
            let response: [String: Any] = ["id": object["id"] ?? NSNull(), "ok": false, "error": "busy"]
            reply((try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8))
            return
        }
        let token = UUID()
        let task = Task {
            var response = await respond(to: data)
            if Task.isCancelled {
                response = (try? JSONSerialization.data(withJSONObject: ["id": id, "ok": false, "error": "cancelled"])) ?? Data("{}".utf8)
            }
            if requests[connection]?[String(id)]?.token == token {
                requests[connection]?.removeValue(forKey: String(id))
            }
            if requests[connection]?.isEmpty == true { requests.removeValue(forKey: connection) }
            reply(response)
        }
        requests[connection, default: [:]][String(id)] = (token, task)
    }

    private func refresh() {
        let store = store
        // Пока заблокировано, настройку внутри хранилища не прочесть — берём её открытую копию из той же записи связки.
        let wanted = store.state == .unlocked ? Prefs.shared.browserEnabled : store.browserEnabledWhileLocked
        guard wanted else {
            if server != nil { stop() }
            // Выключили в разблокированном Ward — Chrome больше не найдёт помощника.
            if store.state == .unlocked { uninstall() }
            problem = nil
            return
        }
        do {
            try install()
        } catch {
            problem = "Не удалось установить помощник: \(error.localizedDescription)"
        }
        guard server == nil else { return }
        guard let team = BrowserPeerCheck.ownTeam() else {
            problem = "Ward подписан без команды разработчика — проверить помощника браузера не по чему. Соберите Ward с сертификатом Apple Development."
            return
        }
        let server = BrowserBridgeServer(socketPath: Self.socketPath, admit: { peer in
            BrowserPeerCheck.isOurHost(peer.auditToken, team: team) && BrowserPeerCheck.isLaunchedByBrowser(hostPID: peer.pid)
        }, disconnected: { connection in
            Task { @MainActor in BrowserController.shared.cancelRequests(connection: connection) }
        }, handle: { connection, request, reply in
            Task { @MainActor in BrowserController.shared.receive(request, connection: connection, reply: reply) }
        })
        do {
            try FileManager.default.createDirectory(atPath: (Self.socketPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try server.start()
            self.server = server
            isRunning = true
            problem = nil
        } catch {
            isRunning = false
            problem = error.localizedDescription
        }
    }

    // MARK: - Установка

    /// Манифест помощника для Chrome (путь к помощнику внутри Ward.app, только наше расширение)
    /// и копия расширения в постоянной папке. Повторяется при каждом запуске: Ward.app могли переместить.
    func install() throws {
        var host = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ward-browser-host")
        #if DEBUG
        // Сквозная проверка подменяет помощника обёрткой, которая передаёт ему свой сокет и делает exec.
        if let path = ProcessInfo.processInfo.environment["WARD_BROWSER_HOST_PATH"] { host = URL(fileURLWithPath: path) }
        #endif
        guard FileManager.default.isExecutableFile(atPath: host.path),
              let bundled = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "Ward — пароли и passkey",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
        ]
        try FileManager.default.createDirectory(at: Self.hostManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        if (try? Data(contentsOf: Self.hostManifest)) != data { try data.write(to: Self.hostManifest, options: .atomic) }

        let fm = FileManager.default
        let staging = Self.extensionFolder.deletingLastPathComponent().appendingPathComponent(".Chrome Extension.new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: bundled, to: staging)
        if fm.fileExists(atPath: Self.extensionFolder.path) {
            _ = try fm.replaceItemAt(Self.extensionFolder, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: Self.extensionFolder)
        }
    }

    /// Выключили мост — Chrome больше не найдёт помощника.
    func uninstall() {
        try? FileManager.default.removeItem(at: Self.hostManifest)
    }

    func revealExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.extensionFolder])
    }

    func openChromeExtensions() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let url = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Запросы

    private struct Failure: Error {
        let code: String
    }

    func respond(to data: Data) async -> Data {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let id = object["id"] ?? NSNull()
        lastRequestAt = Date()
        var reply: [String: Any] = ["id": id]
        do {
            try Task.checkCancellation()
            let request = try BrowserRequest.parse(object)
            reply["result"] = try await handle(request)
            try Task.checkCancellation()
            reply["ok"] = true
        } catch is CancellationError {
            reply["ok"] = false
            reply["error"] = "cancelled"
        } catch let failure as Failure {
            reply["ok"] = false
            reply["error"] = failure.code
        } catch let failure as BrowserBridge.Failure {
            reply["ok"] = false
            reply["error"] = failure == .alreadyRegistered ? "alreadyRegistered" : failure == .siteMismatch ? "siteMismatch" : "noSuchEntry"
        } catch is WebAuthn.Failure {
            reply["ok"] = false
            reply["error"] = "rejectedOrigin"
        } catch {
            reply["ok"] = false
            reply["error"] = "malformed"
        }
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
    }

    private func handle(_ request: BrowserRequest) async throws -> Any {
        let store = store
        if case .hello = request { return ["locked": store.state != .unlocked] }
        try await ensureUnlocked()
        switch request {
        case .hello:
            return [:]
        case .logins(let url):
            let logins = BrowserBridge.logins(for: url, in: store.vault).map {
                ["entryID": $0.entryID.uuidString, "title": $0.title, "login": $0.login,
                 "hasPassword": $0.hasPassword, "hasCode": $0.hasCode] as [String: Any]
            }
            return ["logins": logins]
        case .fill(let entryID, let url):
            let generation = store.generation
            _ = try BrowserBridge.fill(entryID: entryID, url: url, in: store.vault)
            await store.markUsed(entryID)
            try Task.checkCancellation()
            guard store.isCurrent(generation) else { throw Failure(code: "locked") }
            let fill = try BrowserBridge.fill(entryID: entryID, url: url, in: store.vault)
            var result: [String: Any] = ["login": fill.login, "password": fill.password]
            if let code = fill.code { result["code"] = code }
            return result
        case .createPasskey(let creation):
            return try encoded(try await createPasskey(creation))
        case .getPasskey(let passkeyRequest):
            return try encoded(try await usePasskey(passkeyRequest))
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    /// Заблокирован — просим разблокировать и ждём до минуты (как SSH-агент), потом отвечаем «заблокирован».
    private func ensureUnlocked() async throws {
        let store = store
        guard store.state != .unlocked else { return }
        requestUnlock?()
        Toast.shared.show("Chrome просит данные из Ward — разблокируйте")
        for _ in 0..<240 where store.state != .unlocked {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard store.state == .unlocked else { throw Failure(code: "locked") }
    }

    private func createPasskey(_ creation: BrowserRequest.PasskeyCreation) async throws -> BrowserBridge.Created {
        let store = store
        let generation = store.generation
        try WebAuthn.validate(rpID: creation.rpID, origin: creation.origin)
        let host = creation.rpID
        let matching = store.active.filter { entry in entry.host.map { SiteMatch.matches(pageHost: host, entryHost: $0) } ?? false }
            .map { (id: $0.id, title: $0.title, login: $0.login) }
        let site = creation.rpName.isEmpty ? host : creation.rpName
        let options = matching.map { "Добавить в «\($0.title)»" + ($0.login.isEmpty ? "" : " · \($0.login)") } + ["Новая запись «\(site)»"]
        let choice = await approval(
            "Сохранить passkey для \(host)?",
            "Аккаунт: \(creation.userName.isEmpty ? creation.userDisplayName : creation.userName). Сайт будет входить по нему без пароля.",
            options, "Не в Ward")
        guard let choice else { throw Failure(code: "declined") }
        try Task.checkCancellation()
        guard store.isCurrent(generation) else { throw Failure(code: "locked") }
        let (passkey, response) = try BrowserBridge.createPasskey(creation, in: store.vault)
        if choice < matching.count {
            guard await store.addPasskey(passkey, to: matching[choice].id) else { throw Failure(code: "saveFailed") }
        } else {
            var entry = Entry(title: site, space: Navigator.shared.space)
            if entry.space == .work { entry.companyID = Navigator.shared.company }
            entry.url = host
            entry.login = creation.userName
            entry.loginKind = LoginKind.detect(creation.userName)
            entry.passkeys = [passkey]
            guard await store.save(entry) else { throw Failure(code: "saveFailed") }
        }
        try Task.checkCancellation()
        guard store.isCurrent(generation), store.vault.passkey(id: passkey.id) != nil else { throw Failure(code: "locked") }
        Toast.shared.show("Passkey для \(host) сохранён в Ward")
        return response
    }

    private func usePasskey(_ request: BrowserRequest.PasskeyRequest) async throws -> BrowserBridge.Asserted {
        let store = store
        let generation = store.generation
        let candidates = try BrowserBridge.candidates(request, in: store.vault)
            .map { (entryID: $0.entry.id, id: $0.passkey.id, title: $0.entry.title,
                    userName: $0.passkey.userName, userDisplayName: $0.passkey.userDisplayName) }
        guard !candidates.isEmpty else { throw Failure(code: "noPasskey") }
        let options = candidates.map { candidate in
            [candidate.userName.isEmpty ? candidate.userDisplayName : candidate.userName,
             "«\(candidate.title)»"].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let choice = await approval(
            "Войти на \(request.rpID) с passkey?", "Chrome просит подтвердить вход passkey из Ward.",
            options, "Отклонить")
        guard let choice else { throw Failure(code: "declined") }
        try Task.checkCancellation()
        guard store.isCurrent(generation) else { throw Failure(code: "locked") }
        let chosen = candidates[choice]
        guard let current = store.vault.passkey(id: chosen.id), current.entry.id == chosen.entryID else {
            throw Failure(code: "noPasskey")
        }
        await store.touchPasskey(chosen.id)
        try Task.checkCancellation()
        guard store.isCurrent(generation), let latest = store.vault.passkey(id: chosen.id),
              latest.entry.id == chosen.entryID, latest.passkey.privateKey == current.passkey.privateKey else {
            throw Failure(code: "noPasskey")
        }
        return try BrowserBridge.assertion(latest.passkey, request: request)
    }
}

/// Окно подтверждения запросов браузера: варианты кнопками, по одному окну за раз, через минуту — отказ.
@MainActor
final class BrowserPrompt {
    static let shared = BrowserPrompt()
    private let allowDemo: Bool
    private let scrollDetail: Bool

    init(allowDemo: Bool = true, scrollDetail: Bool = false) {
        self.allowDemo = allowDemo
        self.scrollDetail = scrollDetail
    }

    private var panel: KeyPanel?
    private let approvals = ApprovalQueue<Int>()

    func cancelAll() { approvals.cancelAll() }

    func ask(title: String, detail: String, options: [String], decline: String) async -> Int? {
        #if DEBUG
        if allowDemo, ProcessInfo.processInfo.environment["WARD_BROWSER_DEMO"] == "approve" { return options.isEmpty ? nil : 0 }
        #endif
        return await approvals.ask(show: { [self] finish in
            let panel = self.panel ?? makePanel()
            panel.contentView = NSHostingView(rootView: BrowserPromptView(title: title, detail: detail, options: options,
                                                                          decline: decline, scrollDetail: scrollDetail, onChoice: finish))
            let size = panel.contentView?.fittingSize ?? NSSize(width: 460, height: 200)
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.2 - size.height,
                                      width: size.width, height: size.height), display: true)
            }
            Foreground.show(panel)
        }, close: { [weak self] in self?.panel?.orderOut(nil) })
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
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

private struct BrowserPromptView: View {
    let title: String
    let detail: String
    let options: [String]
    let decline: String
    let scrollDetail: Bool
    let onChoice: (Int?) -> Void
    /// Кнопки оживают не сразу: окно всплывает, пока человек печатает на сайте, и случайный ⏎ не должен стать «да».
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    if scrollDetail {
                        ScrollView {
                            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .privacySensitive()
                        }
                        .frame(height: 160)
                    } else {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if scrollDetail {
                ScrollView {
                    choices
                }
                .frame(height: min(CGFloat(options.count) * 72, 288))
            } else {
                choices
            }
            HStack {
                Spacer()
                Button(decline) { onChoice(nil) }
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    .keyboardShortcut(.cancelAction)
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

    private var choices: some View {
        VStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { onChoice(index) } label: {
                    Text(option).lineLimit(scrollDetail ? 3 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .privacySensitive()
                }
                .buttonStyle(SecondaryButtonStyle(height: scrollDetail ? 66 : 32))
                .disabled(!armed)
            }
        }
    }
}
