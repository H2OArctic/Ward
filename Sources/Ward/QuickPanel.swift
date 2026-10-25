import AppKit
import SwiftUI
import WardCore

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickPanelModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    @Published var showCount = 0
}

struct QuickPanelActions {
    var fill: (Entry, _ passwordOnly: Bool) -> Void
    var copySecret: (Entry) -> Void
    var copyCode: (Entry) -> Void
    var copyLogin: (Entry) -> Void
    var markDone: (Entry) -> Void
    var open: (Entry) -> Void
    var newEntry: (String) -> Void
    var openMain: () -> Void
    var close: () -> Void
}

@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 680, height: 434)

    private let store: VaultStore
    private let model = QuickPanelModel()
    private var panel: KeyPanel?
    /// Приложение, из которого вызвали панель: панель не активирует Ward, поэтому это окно вставки.
    private var target: NSRunningApplication?

    var onOpen: ((Entry) -> Void)?
    var onNewEntry: ((String) -> Void)?
    var onOpenMain: (() -> Void)?

    init(store: VaultStore) {
        self.store = store
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        if panel?.isVisible != true {
            let front = NSWorkspace.shared.frontmostApplication
            target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            // Chromium строит дерево страницы не сразу — включаем заранее, пока человек ищет запись.
            if let target, AutoType.isBrowser(target) { AutoType.prepare(target) }
        }
        let panel = self.panel ?? makePanel()
        model.query = ""
        model.selection = 0
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                         y: frame.maxY - frame.height * 0.16 - Self.size.height))
        }
        panel.makeKeyAndOrderFront(nil)
        model.showCount += 1
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let root = QuickPanelView(model: model, actions: actions)
            .environmentObject(store)
            .environmentObject(Prefs.shared)
        panel.contentView = NSHostingView(rootView: root)
        self.panel = panel
        return panel
    }

    private var actions: QuickPanelActions {
        QuickPanelActions(
            fill: { [weak self] entry, passwordOnly in self?.fill(entry, passwordOnly: passwordOnly) },
            copySecret: { [weak self] entry in self?.copySecret(entry) },
            copyCode: { [weak self] entry in self?.copyCode(entry) },
            copyLogin: { [weak self] entry in
                guard let self, !entry.login.isEmpty else { return }
                Clipboard.copy(entry.login, sensitive: false)
                self.finish(entry, "\(Format.loginLabel(entry.loginKind)) «\(entry.title)» скопирован")
            },
            markDone: { [weak self] entry in
                guard let store = self?.store else { return }
                Task {
                    guard await store.markReminderDone(entry.id) else {
                        // Главного окна может не быть на экране — его алерт никто бы не увидел.
                        Toast.shared.show(store.lastError ?? "Не удалось сохранить")
                        store.lastError = nil
                        return
                    }
                    Toast.shared.show("«\(entry.reminder?.task ?? entry.title)» — сделано")
                }
            },
            open: { [weak self] entry in
                self?.hide()
                self?.onOpen?(entry)
            },
            newEntry: { [weak self] title in
                self?.hide()
                self?.onNewEntry?(title)
            },
            openMain: { [weak self] in
                self?.hide()
                self?.onOpenMain?()
            },
            close: { [weak self] in self?.hide() }
        )
    }

    private func copySecret(_ entry: Entry) {
        switch entry.authKind {
        case .sso:
            let target = store.entry(entry.ssoEntryID)
            Toast.shared.show(target.map { "Вход через «\($0.title)»" } ?? "Вход через другой аккаунт")
            if let target, target.authKind != .sso { copySecret(target) }
        case .password, .token:
            guard !entry.secret.isEmpty else {
                Toast.shared.show("У записи нет пароля")
                return
            }
            Clipboard.copy(entry.secret, sensitive: true)
            let what = entry.authKind == .token ? "Токен" : "Пароль"
            let clear = Prefs.shared.clipboardClearSeconds
            finish(entry, "\(what) «\(entry.title)» скопирован" + (clear > 0 ? " · очистится через \(clear) с" : ""))
        }
    }

    /// ⇧⏎: логин → Tab → пароль прямо в поле сайта; ⌥⏎: только пароль. Код 2FA затем ждёт в буфере.
    private func fill(_ entry: Entry, passwordOnly: Bool) {
        guard AutoType.isTrusted else {
            AutoType.requestPermission()
            hide()
            Toast.shared.show("Разрешите Ward «Универсальный доступ» и повторите ⇧⏎")
            return
        }
        var source = entry
        if entry.authKind == .sso {
            guard let target = store.entry(entry.ssoEntryID), target.authKind != .sso else {
                Toast.shared.show("Вход через другой аккаунт, но он не выбран")
                return
            }
            source = target
        }
        guard !source.secret.isEmpty else {
            Toast.shared.show("У записи «\(entry.title)» нет пароля")
            return
        }
        guard let target, !target.isTerminated else {
            Toast.shared.show("Некуда вставлять: откройте панель из окна со страницей входа")
            return
        }
        var pieces = [source.secret]
        if !passwordOnly && !source.login.isEmpty { pieces.insert(source.login, at: 0) }
        let totp = entry.totp ?? source.totp
        // Сверяем с сайтом той записи, чей пароль вставляется: у входа через Google это Google, а не сайт,
        // куда входят через него, — иначе пароль Google ушёл бы в форму стороннего сайта.
        let site = source.address
        let siteUnreadable = site == nil && !source.url.trimmingCharacters(in: .whitespaces).isEmpty
        let requiresHTTPS = site?.webURL(original: source.url)?.scheme == "https"
        let pid = target.processIdentifier
        let appName = target.localizedName ?? "приложение"
        let isBrowser = AutoType.isBrowser(target)
        if isBrowser { AutoType.prepare(target) }
        // Перед каждой вставкой: то же окно, а на веб-странице (в любом приложении) — тот же сайт, что в записи.
        // Сайт не определился (адресная строка, другой фрейм, браузер молчит) — не вставляем: это безопаснее.
        let check: () -> String? = {
            guard AutoType.isFrontmost(pid) else { return "Активно другое окно — вставка отменена" }
            let content = AutoType.focusedContent(pid: pid)
            if content == .noPage && !isBrowser { return nil }
            if siteUnreadable { return "Адрес записи не распознан — вставка отменена, поправьте его в записи" }
            guard let site else {
                return "У записи «\(source.title)» нет адреса — на веб-страницу не вставляем, скопируйте пароль через ⏎"
            }
            guard case .page(let page, let secure) = content else {
                return "Не удалось определить сайт в \(appName) — вставка отменена, скопируйте пароль через ⏎"
            }
            guard SiteMatch.matches(pageHost: page, entryHost: site.host) else {
                return "Открыт \(page), а запись для \(site.host) — вставка отменена"
            }
            if requiresHTTPS && !secure { return "\(page) открыт без HTTPS — вставка отменена" }
            return nil
        }
        hide()
        Task { @MainActor in
            // Даём фокусу вернуться в окно, из которого вызвали панель.
            try? await Task.sleep(for: .milliseconds(120))
            // Первый раз после запуска Chromium может ещё строить дерево страницы — даём ему до секунды.
            if isBrowser {
                for _ in 0..<4 where AutoType.isFrontmost(pid) && !AutoType.focusedContent(pid: pid).isPage {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            if let problem = check() {
                Toast.shared.show(problem)
                return
            }
            await store.markUsed(entry.id)
            if let problem = await AutoType.type(pieces, check: check) {
                Clipboard.clearSensitive()
                Toast.shared.show(problem)
                return
            }
            if Prefs.shared.copyCodeAfterFill, let totp {
                Clipboard.copy(TOTP.code(totp), sensitive: true)
                Toast.shared.show("Вставлено · код 2FA в буфере — ⌘V на следующем шаге")
            } else {
                Clipboard.clear()
                Toast.shared.show("Вставлено")
            }
        }
    }

    private func copyCode(_ entry: Entry) {
        guard let totp = entry.totp else {
            Toast.shared.show("У записи «\(entry.title)» нет 2FA")
            return
        }
        Clipboard.copy(TOTP.code(totp), sensitive: true)
        finish(entry, "Код «\(entry.title)» скопирован")
    }

    private func finish(_ entry: Entry, _ message: String) {
        Task { await store.markUsed(entry.id) }
        hide()
        Toast.shared.show(message)
    }
}

struct QuickPanelView: View {
    @ObservedObject var model: QuickPanelModel
    let actions: QuickPanelActions
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var prefs: Prefs

    var body: some View {
        Group {
            switch store.state {
            case .unlocked:
                QuickSearchView(model: model, actions: actions)
            case .locked:
                UnlockView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsSetup:
                VStack(spacing: 16) {
                    LockBadge()
                    Text("Хранилище ещё не создано").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                    Button("Создать", action: actions.openMain).buttonStyle(AccentButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: QuickPanelController.size.width, height: QuickPanelController.size.height)
        .redacted(reason: prefs.hideData ? .privacy : [])
        .focusEffectDisabled()
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
        .environment(\.colorScheme, .dark)
        .onExitCommand(perform: actions.close)
    }
}

private struct QuickSearchView: View {
    @ObservedObject var model: QuickPanelModel
    let actions: QuickPanelActions
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var prefs: Prefs
    @FocusState private var searchFocused: Bool

    private var results: [Entry] {
        let query = model.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            // Без запроса: сначала то, что пора сделать, потом самое используемое.
            let due = store.dueEntries
            let dueIDs = Set(due.map(\.id))
            let rest = store.active.filter { !dueIDs.contains($0.id) }.sorted {
                if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
                return ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
            }
            return due + rest
        }
        return EntrySearch.search(store.active, query: query) { store.searchContext($0) }
    }

    var body: some View {
        let items = results
        let selected = items.isEmpty ? -1 : min(model.selection, items.count - 1)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.text3)
                TextField("Поиск по названию, логину или сайту", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.text)
                    .focused($searchFocused)
                    .onChange(of: model.query) { model.selection = 0 }
                    .onKeyPress(.downArrow) {
                        model.selection = min(selected + 1, items.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.selection = max(selected - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        guard selected >= 0 else { return .ignored }
                        actions.open(items[selected])
                        return .handled
                    }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard selected >= 0 else { return .ignored }
                        let entry = items[selected]
                        if press.modifiers.contains(.command) {
                            actions.copyCode(entry)
                        } else if press.modifiers.contains(.shift) {
                            actions.fill(entry, false)
                        } else if press.modifiers.contains(.option) {
                            actions.fill(entry, true)
                        } else {
                            perform(prefs.enterAction, entry)
                        }
                        return .handled
                    }
                    .onKeyPress(keys: ["u", "г", "n", "т", "d", "в", "h", "H", "р", "Р"], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        switch press.characters {
                        case "h", "H", "р", "Р":
                            guard press.modifiers.contains(.shift) else { return .ignored }
                            prefs.hideData.toggle()
                        case "u", "г":
                            if selected >= 0 { actions.copyLogin(items[selected]) }
                        case "n", "т":
                            actions.newEntry(model.query)
                        default:
                            if selected >= 0, items[selected].reminder?.isDue() == true { actions.markDone(items[selected]) }
                        }
                        return .handled
                    }
                IconButton(systemName: prefs.hideData ? "eye.slash" : "eye",
                           label: prefs.hideData ? "Показать данные (⌘⇧H)" : "Скрыть данные от тех, кто рядом (⌘⇧H)",
                           size: 36, iconSize: 15, tint: prefs.hideData ? Theme.accent : Theme.text2) {
                    prefs.hideData.toggle()
                }
                IconButton(systemName: "lock", label: "Заблокировать хранилище", size: 36, iconSize: 16) {
                    store.lock(reason: .manual)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 60)

            Hairline()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            QuickRow(entry: entry, place: store.whereLabel(entry), selected: index == selected,
                                     onPick: {
                                         model.selection = index
                                         perform(prefs.enterAction, entry)
                                     },
                                     onCode: { actions.copyCode(entry) },
                                     onDone: { actions.markDone(entry) })
                            .id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) {
                    if selected >= 0 { proxy.scrollTo(items[selected].id) }
                }
            }
            .frame(height: 332)
            .overlay {
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Text(store.active.isEmpty ? "Записей пока нет" : "Ничего не найдено")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.text)
                        Text(model.query.isEmpty ? "⌘N — новая запись" : "⌘N — создать запись «\(model.query)»")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text2)
                    }
                }
            }

            HStack(spacing: 18) {
                hint("⏎", enterHint)
                hint("⇧⏎", "вставить")
                hint("⌘⏎", "код 2FA")
                hint("⌘U", "логин")
                hint("→", "открыть")
                Spacer()
                hint("⌘N", "новая запись")
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Theme.panelFooter)
            .overlay(alignment: .top) { Hairline() }
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.showCount) { searchFocused = true }
    }

    private var enterHint: String {
        switch prefs.enterAction {
        case .password: return "пароль"
        case .code: return "код"
        case .open: return "открыть"
        }
    }

    private func perform(_ action: EnterAction, _ entry: Entry) {
        switch action {
        case .password: actions.copySecret(entry)
        case .code: actions.copyCode(entry)
        case .open: actions.open(entry)
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(text: key)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
    }
}

private struct QuickRow: View {
    let entry: Entry
    let place: String
    let selected: Bool
    let onPick: () -> Void
    let onCode: () -> Void
    let onDone: () -> Void

    var body: some View {
        let due = entry.reminder?.isDue() == true
        HStack(spacing: 8) {
            Button(action: onPick) {
                HStack(spacing: 12) {
                    Avatar(title: entry.title, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(entry.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            ForEach(entry.environments, id: \.self) { EnvBadge(env: $0) }
                        }
                        Text(subtitle).privacySensitive()
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if due, let reminder = entry.reminder {
                Button(action: onDone) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 13))
                        Text(reminder.task).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .hoverBackground(Theme.accent.opacity(0.12), cornerRadius: 14)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Отметить сделанным до следующего месяца (⌘D)")
            }

            if let totp = entry.totp {
                Button(action: onCode) {
                    TOTPCodeView(config: totp)
                        .padding(.leading, 12)
                        .padding(.trailing, 10)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .hoverBackground(Color.white.opacity(0.06), cornerRadius: 8)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Скопировать код 2FA")
                .fixedSize()
            }
        }
        .padding(.trailing, 8)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
        .hoverBackground(cornerRadius: 10, enabled: !selected)
    }

    private var subtitle: String {
        entry.login.isEmpty ? place : "\(place) · \(entry.login)"
    }
}
