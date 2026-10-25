import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import WardCore

/// Глобальная горячая клавиша через Carbon: не требует прав Accessibility.
final class Hotkey {
    static let shared = Hotkey()

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// `false` — сочетание не зарегистрировалось (например, занято другим приложением).
    @discardableResult
    func register(_ spec: HotkeySpec) -> Bool {
        unregister()
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotkey.action?() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x5741_5244), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = status == noErr ? ref : nil
        return hotKeyRef != nil
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

@MainActor
enum Clipboard {
    // nspasteboard.org: менеджеры буфера (Raycast, Maccy, Paste) не сохраняют такие записи в историю.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// `changeCount` буфера, когда в нём лежит секрет, положенный Ward.
    private static var sensitiveStamp: Int?

    static func copy(_ text: String, sensitive: Bool) {
        place(text, sensitive: sensitive, autoClear: sensitive)
    }

    static func clear() {
        NSPasteboard.general.clearContents()
        sensitiveStamp = nil
    }

    /// При блокировке и выходе: таймер очистки умирает вместе с процессом, а пароль в буфере не должен пережить Ward.
    static func clearSensitive() {
        guard let stamp = sensitiveStamp, NSPasteboard.general.changeCount == stamp else { return }
        clear()
    }

    static func place(_ text: String, sensitive: Bool, autoClear: Bool) {
        let pasteboard = NSPasteboard.general
        if sensitive {
            // Только этот Mac: иначе Universal Clipboard отправит пароль на iPhone/iPad, где его не очистить.
            _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
        // Одним элементом: менеджер буфера не должен успеть увидеть строку без пометок «скрыть».
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if sensitive && Prefs.shared.concealClipboard {
            item.setData(Data(), forType: concealed)
            item.setData(Data(), forType: transient)
        }
        pasteboard.writeObjects([item])
        sensitiveStamp = sensitive ? pasteboard.changeCount : nil
        guard autoClear else { return }
        let seconds = Prefs.shared.clipboardClearSeconds
        guard seconds > 0 else { return }
        let stamp = pasteboard.changeCount
        // По настенным часам: монотонные во сне стоят, и пароль пережил бы сон Mac.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + .seconds(seconds)) {
            if pasteboard.changeCount == stamp { clear() }
        }
    }

    /// Секрет для вставки: строка отдаётся по запросу, поэтому видно, когда приложение её действительно прочитало.
    static func offer(_ text: String) -> PasteOffer {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        let offer = PasteOffer(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(offer, forTypes: [.string])
        if Prefs.shared.concealClipboard {
            item.setData(Data(), forType: concealed)
            item.setData(Data(), forType: transient)
        }
        pasteboard.writeObjects([item])
        sensitiveStamp = pasteboard.changeCount
        return offer
    }
}

/// Провайдер данных AppKit может позвать не с главного потока — состояние под замком.
final class PasteOffer: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var isDelivered = false

    init(text: String) {
        self.text = text
    }

    var delivered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDelivered
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        lock.lock()
        isDelivered = true
        lock.unlock()
    }

    /// `false` — за `timeout` строку так никто и не запросил.
    func waitForDelivery(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !delivered && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return delivered
    }
}

@MainActor
final class AutoLock {
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start(store: VaultStore) {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if Prefs.shared.lockOnSleep { store.lock(reason: .sleep) }
            }
        }))
        // Быстрая смена пользователя: другой человек за этим Mac не должен застать Ward открытым.
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if Prefs.shared.lockOnScreenLock { store.lock(reason: .screenLock) }
            }
        }))
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if Prefs.shared.lockOnScreenLock { store.lock(reason: .screenLock) }
            }
        }))
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let minutes = Prefs.shared.autoLockMinutes
                guard minutes > 0, store.state == .unlocked else { return }
                if Self.idleSeconds() >= TimeInterval(minutes * 60) { store.lock(reason: .idle) }
            }
        }
        // Во всех режимах цикла: в .default таймер молчал бы, пока открыт модальный диалог (NSSavePanel и т. п.).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}

/// Всплывашка «Скопировано»: живёт в отдельном окне, чтобы её было видно и после закрытия панели.
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, over window: NSWindow? = nil) {
        let host = NSHostingView(rootView: ToastView(text: text))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        let anchor = window?.isVisible == true ? window!.frame
            : (NSScreen.main?.visibleFrame ?? .zero)
        panel.setFrame(NSRect(x: anchor.midX - size.width / 2, y: anchor.minY + 28,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel?.animator().alphaValue = 0 }) {
                panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Theme.accent, in: Capsule())
        .fixedSize()
    }
}

/// Вставка в поле под фокусом другого приложения: кладём значение в буфер и шлём ⌘V, между полями — Tab.
/// Нужен доступ «Универсальный доступ»; поля пароля в браузерах так тоже заполняются.
@MainActor
enum AutoType {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// `check` вызывается перед каждой вставкой (фокус после Tab мог уйти в адресную строку или чужой фрейм):
    /// вернул текст — вставка прерывается с этим объяснением. Результат — `nil`, если вставлено всё.
    static func type(_ pieces: [String], check: () -> String?) async -> String? {
        guard await waitForModifiersRelease() else { return "Клавиши ещё зажаты — вставка отменена, повторите" }
        let source = CGEventSource(stateID: .combinedSessionState)
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                press(CGKeyCode(kVK_Tab), flags: [], source: source)
                try? await Task.sleep(for: .milliseconds(80))
            }
            if let problem = check() { return problem }
            let offer = Clipboard.offer(piece)
            press(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)
            // Следующий кусок кладём в буфер только после того, как приложение забрало этот: иначе медленная
            // страница прочитала бы по ⌘V уже пароль — и он ушёл бы открытым текстом в поле логина.
            guard await offer.waitForDelivery(timeout: .seconds(3)) else {
                return "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "Приложение") не приняло вставку — отменено"
            }
        }
        return nil
    }

    static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static let browserPrefixes = [
        "com.apple.Safari", "com.google.Chrome", "org.chromium.", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.", "com.operasoftware.", "com.vivaldi.", "ru.yandex.desktop.yandex-browser",
        "org.mozilla.", "app.zen-browser.", "com.kagi.kagimacOS", "org.torproject.",
    ]

    static func isBrowser(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return browserPrefixes.contains { id.hasPrefix($0) }
    }

    private static let chromiumPrefixes = [
        "com.google.Chrome", "org.chromium.", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.",
        "com.operasoftware.", "com.vivaldi.", "ru.yandex.desktop.yandex-browser",
    ]

    /// Chromium строит дерево доступности страницы только по просьбе — иначе адрес страницы не узнать.
    static func prepare(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, chromiumPrefixes.contains(where: { id.hasPrefix($0) }) else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    enum FocusedContent: Equatable {
        /// Поле на веб-странице этого сайта.
        case page(host: String, secure: Bool)
        /// Поле на веб-странице, но сайт не узнать (не http, браузер не ответил).
        case unknownPage
        /// Веб-страницы над полем не нашлось (обычное окно, адресная строка) или приложение не ответило.
        case noPage

        var isPage: Bool {
            if case .page = self { return true }
            return false
        }
    }

    /// Ближайшая к полю под фокусом веб-область — т. е. тот фрейм, куда уйдёт ввод. Не только в известных
    /// браузерах: веб-вход бывает в любом браузере и во встроенных окнах приложений.
    static func focusedContent(pid: pid_t) -> FocusedContent {
        // Глобальный таймаут: зависший браузер не должен морозить Ward на стандартные ~6 с за каждый вызов.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let deadline = Date().addingTimeInterval(1)
        guard var element = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) else { return .noPage }
        for _ in 0..<40 {
            guard Date() < deadline else { return .noPage }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
                      let url = value as? URL, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let host = url.host, !host.isEmpty else { return .unknownPage }
                return .page(host: host, secure: scheme == "https")
            }
            guard let parent = attribute(element, kAXParentAttribute) else { return .noPage }
            element = parent
        }
        return .noPage
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// ⇧⏎ ещё зажат, когда начинаем печатать: с зажатым ⇧ Tab ушёл бы в предыдущее поле. `false` — так и не отпустили.
    private static func waitForModifiersRelease() async -> Bool {
        for _ in 0..<40 {
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskShift, .maskCommand, .maskAlternate, .maskControl])
            if held.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

/// Копии на внешний диск: не на каждое изменение (HDD раскручивался бы постоянно),
/// а раз в 30 минут, при блокировке, при выходе и когда диск подключили.
@MainActor
final class BackupMirror: ObservableObject {
    static let shared = BackupMirror()

    @Published private(set) var lastMirroredAt: Date?
    @Published private(set) var problem: String?

    private var dirty = false
    private var lastAttempt = Date.distantPast
    private var timer: Timer?
    private var mountObserver: NSObjectProtocol?
    private let interval: TimeInterval = 30 * 60
    private let queue = DispatchQueue(label: "ward.backup-mirror", qos: .utility)

    var target: BackupStore? {
        let path = Prefs.shared.mirrorBackupPath
        guard !path.isEmpty else { return nil }
        let keep = Prefs.shared.backupsToKeep
        return BackupStore(directory: URL(fileURLWithPath: path, isDirectory: true), keep: { keep })
    }

    func start() {
        refreshStatus()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let mirror = BackupMirror.shared
                if mirror.dirty && Date().timeIntervalSince(mirror.lastAttempt) >= mirror.interval { mirror.flush() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                BackupMirror.shared.refreshStatus()
                if BackupMirror.shared.dirty { BackupMirror.shared.flush() }
            }
        }
    }

    func noteChange() {
        dirty = true
    }

    func refreshStatus() {
        guard let target else {
            problem = nil
            lastMirroredAt = nil
            return
        }
        if BackupStore.isReachable(target.directory) {
            lastMirroredAt = target.latestDate()
            problem = nil
        } else {
            problem = "Диск не подключён — копия пока только на этом Mac"
        }
    }

    func mirrorNow() {
        dirty = true
        flush()
    }

    /// `wait` — при выходе из приложения: дождаться записи, иначе процесс завершится раньше.
    func flush(wait: Bool = false) {
        guard dirty, let target else { return }
        lastAttempt = Date()
        guard BackupStore.isReachable(target.directory) else {
            problem = "Диск не подключён — копия пока только на этом Mac"
            return
        }
        let primary = VaultStore.shared.backups
        let work = { Result { try primary.mirrorLatest(to: target) } }
        if wait {
            finish(queue.sync(execute: work))
        } else {
            queue.async {
                let result = work()
                DispatchQueue.main.async { MainActor.assumeIsolated { BackupMirror.shared.finish(result) } }
            }
        }
    }

    private func finish(_ result: Result<Bool, Error>) {
        switch result {
        case .success:
            dirty = false
            problem = nil
            lastMirroredAt = target?.latestDate()
        case .failure(let error):
            problem = "Не удалось скопировать: \(error.localizedDescription)"
        }
    }
}

/// Окна Ward не попадают в демонстрацию экрана и записи: там бывают открытые пароли.
@MainActor
enum ScreenPrivacy {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        // Листы, всплывающие окна и алерты создаются на ходу, поэтому проверяем все окна после каждого обновления.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.sharingType != .none { window.sharingType = .none }
            }
        }
    }
}

/// Окно Ward — на передний план, даже если его открыли из строки меню или быстрой панели, пока активно другое приложение.
@MainActor
enum Foreground {
    static func show(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Смена политики активации (строка меню → обычное окно) вступает в силу к следующему такту: сразу после неё
        // macOS 14+ пропускает просьбу стать активным, и окно оставалось позади чужих.
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// Один Ward на пользователя: две копии держали бы в памяти разные версии хранилища и переписывали бы друг друга.
enum SingleInstance {
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    /// `false` — Ward уже запущен. Если замок не создать (например, нет места), запуск не блокируется:
    /// перезапись чужих изменений всё равно остановит `VaultSession`.
    static func acquire() -> Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["WARD_SNAPSHOT"] != nil || env["WARD_AGENT_DEMO"] != nil || env["WARD_BROWSER_DEMO"] != nil { return true }
        #endif
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ward", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("ward.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    static func activateRunning() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? WardIdentity.applicationID)
        others.first { $0.processIdentifier != me }?.activate()
        FileHandle.standardError.write(Data("Ward уже запущен — второй экземпляр не открывается\n".utf8))
    }
}

/// Файлы с секретами открытым текстом (экспорт CSV, приватные ключи), которые человек сохраняет сам.
enum PlaintextFile {
    /// Права 0600 не мешают синхронизации: «Рабочий стол и Документы» в iCloud унесут файл в облако.
    static func cloudWarning(for url: URL) -> String? {
        FileManager.default.isUbiquitousItem(at: url)
            ? "Файл попал в папку iCloud — секреты уйдут в облако открытым текстом, удалите его как можно скорее" : nil
    }

    /// Временный файл (экспорт для переноса) не должен остаться в Time Machine после удаления.
    static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }
}
