import AppKit

MainActor.assumeIsolated {
    guard SingleInstance.acquire() else {
        SingleInstance.activateRunning()
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Ward открывается окном (см. applicationDidFinishLaunching), поэтому с самого начала — обычное приложение:
    // при запуске из режима «только строка меню» macOS не делала окно активным. Закрыли окно — снова только строка меню.
    app.setActivationPolicy(.regular)
    app.run()
}
