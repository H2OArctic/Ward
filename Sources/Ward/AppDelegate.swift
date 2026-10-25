import AppKit
import Combine
import WardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = VaultStore.shared
    private var statusItem: NSStatusItem?
    private lazy var quickPanel = QuickPanelController(store: store)
    private lazy var mainWindow = MainWindowController(store: store)
    private lazy var settingsWindow = SettingsWindowController()
    private let autoLock = AutoLock()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        ScreenPrivacy.start()
        NSApp.mainMenu = buildMainMenu()
        setupStatusItem()

        quickPanel.onOpen = { [weak self] entry in
            self?.showMainWindow()
            Navigator.shared.open(entry)
        }
        quickPanel.onNewEntry = { [weak self] title in
            self?.showMainWindow()
            Navigator.shared.newEntry(title: title)
        }
        quickPanel.onOpenMain = { [weak self] in self?.showMainWindow() }

        Hotkey.shared.action = { [weak self] in self?.quickPanel.toggle() }
        let hotkeyRegistered = Hotkey.shared.register(Prefs.shared.hotkey)
        Prefs.shared.$hotkey.dropFirst().removeDuplicates().sink { Hotkey.shared.register($0) }.store(in: &cancellables)
        store.$state.sink { [weak self] state in
            if state != .unlocked {
                self?.settingsWindow.close()
                Clipboard.clearSensitive()
                BackupMirror.shared.flush()
            }
            DispatchQueue.main.async { self?.refreshStatusMenu() }
        }.store(in: &cancellables)

        #if DEBUG
        if ProcessInfo.processInfo.environment["WARD_BROWSER_DEMO"] != nil {
            Task { await Snapshots.runBrowserDemo(main: mainWindow) }
            return
        }
        if let key = ProcessInfo.processInfo.environment["WARD_AGENT_DEMO"] {
            Task { await Snapshots.runAgentDemo(keyPath: key, main: mainWindow) }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["WARD_SNAPSHOT"] {
            Task { await Snapshots.run(into: URL(fileURLWithPath: dir), main: mainWindow, panel: quickPanel, settings: settingsWindow) }
            return
        }
        #endif

        Prefs.shared.onSecurityChange = { [weak self] settings in Task { await self?.store.saveSecurity(settings) } }
        autoLock.start(store: store)
        AgentController.shared.requestUnlock = { [weak self] in self?.quickPanel.show() }
        AgentController.shared.start(store: store)
        BrowserController.shared.requestUnlock = { [weak self] in self?.showMainWindow() }
        BrowserController.shared.start(store: store)
        CommandController.shared.start()
        store.onBackup = { BackupMirror.shared.noteChange() }
        BackupMirror.shared.start()
        // Открыли Ward — сразу окно (разблокировки или создания хранилища), а не только значок в строке меню.
        showMainWindow()
        if !hotkeyRegistered {
            Toast.shared.show("\(Prefs.shared.hotkey.label) занято другим приложением — смените в настройках Ward")
        }
    }

    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        store.prepareForTermination {
            RunLoop.main.perform(inModes: [.common, .default, .modalPanel, .eventTracking]) {
                MainActor.assumeIsolated { sender.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Clipboard.clearSensitive()
        AgentController.shared.stop()
        BrowserController.shared.stop()
        CommandController.shared.stop()
        BackupMirror.shared.noteChange()
        BackupMirror.shared.flush(wait: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Действия

    @objc func toggleQuickPanel() { quickPanel.toggle() }
    @objc func showMainWindow() { mainWindow.show() }
    /// Настройки только при открытом хранилище: иначе можно было бы, например, выключить автоблокировку.
    @objc func showSettings() {
        guard store.state == .unlocked else {
            if store.state == .locked { quickPanel.show() } else { showMainWindow() }
            return
        }
        settingsWindow.show()
    }
    @objc func lockVault() { store.lock(reason: .manual) }

    @objc func newEntry() {
        showMainWindow()
        guard store.state == .unlocked else { return }
        Navigator.shared.newEntry()
    }

    // MARK: - Меню

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: "Ward")
        item.button?.image?.isTemplate = true
        statusItem = item
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("Быстрая панель", #selector(toggleQuickPanel), hint: Prefs.shared.hotkey.label))
        menu.addItem(menuItem("Открыть Ward", #selector(showMainWindow)))
        let newEntry = menuItem("Новая запись", #selector(newEntry))
        newEntry.isEnabled = store.state == .unlocked
        menu.addItem(newEntry)
        menu.addItem(.separator())
        let lock = menuItem("Заблокировать", #selector(lockVault))
        lock.isEnabled = store.state == .unlocked
        menu.addItem(lock)
        let settings = menuItem("Настройки…", #selector(showSettings))
        settings.isEnabled = store.state == .unlocked
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти из Ward", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        menu.autoenablesItems = false
        statusItem?.menu = menu
    }

    private func menuItem(_ title: String, _ action: Selector, hint: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let hint { item.toolTip = hint }
        return item
    }

    /// Главное меню нужно и агенту без Dock-иконки: без «Правка» в полях не работают ⌘C/⌘V.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "О программе Ward", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(targeted("Настройки…", #selector(showSettings), ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Скрыть Ward", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Выйти из Ward", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        attach(app, to: main, title: "Ward")

        let vault = NSMenu(title: "Хранилище")
        vault.addItem(targeted("Новая запись", #selector(newEntry), "n"))
        vault.addItem(targeted("Быстрая панель", #selector(toggleQuickPanel), ""))
        vault.addItem(.separator())
        let hide = targeted("Скрыть данные", #selector(toggleHideData), "h")
        hide.keyEquivalentModifierMask = [.command, .shift]
        vault.addItem(hide)
        let lock = targeted("Заблокировать", #selector(lockVault), "l")
        lock.keyEquivalentModifierMask = [.control, .command]
        vault.addItem(lock)
        attach(vault, to: main, title: "Хранилище")

        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        attach(edit, to: main, title: "Правка")

        let window = NSMenu(title: "Окно")
        window.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        attach(window, to: main, title: "Окно")
        NSApp.windowsMenu = window

        return main
    }

    @objc func toggleHideData() { Prefs.shared.hideData.toggle() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHideData):
            menuItem.state = Prefs.shared.hideData ? .on : .off
            return true
        case #selector(showSettings), #selector(lockVault), #selector(newEntry): return store.state == .unlocked
        default: return true
        }
    }

    private func targeted(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func attach(_ submenu: NSMenu, to main: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
