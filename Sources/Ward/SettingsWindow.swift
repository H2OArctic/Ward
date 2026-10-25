import AppKit
import SwiftUI
import WardCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func close() {
        window?.close()
    }

    func show() {
        Foreground.show(self.window ?? makeWindow())
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.sharingType = .none
        window.title = "Настройки"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Theme.list)
        window.contentView = NSHostingView(rootView: SettingsView()
            .environmentObject(Prefs.shared)
            .environmentObject(VaultStore.shared))
        window.center()
        self.window = window
        return window
    }
}

struct SettingsView: View {
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var store: VaultStore
    @State private var recording = false
    @State private var monitor: Any?
    @State private var changingPassword = false
    @State private var hotkeyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("Безопасность") {
                    row("Автоблокировка") {
                        Picker("", selection: $prefs.autoLockMinutes) {
                            Text("через 1 минуту простоя").tag(1)
                            Text("через 5 минут простоя").tag(5)
                            Text("через 15 минут простоя").tag(15)
                            Text("через час простоя").tag(60)
                            Text("никогда").tag(0)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Hairline()
                    toggleRow("Блокировать при переходе в сон", $prefs.lockOnSleep)
                    Hairline()
                    toggleRow("Блокировать при блокировке экрана и смене пользователя", $prefs.lockOnScreenLock)
                    Hairline()
                    row("Мастер-пароль") {
                        Button("Сменить…") { changingPassword = true }
                            .buttonStyle(SecondaryButtonStyle(height: 28))
                            .disabled(store.state != .unlocked)
                    }
                }

                group("Быстрая панель") {
                    row("Горячая клавиша") {
                        Text(recording ? "Нажмите сочетание…" : prefs.hotkey.label)
                            .font(.system(size: 13))
                            .foregroundStyle(recording ? Theme.accent : Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 6))
                        Button(recording ? "Отмена" : "Изменить") { recording ? stopRecording() : startRecording() }
                            .buttonStyle(SecondaryButtonStyle(height: 28))
                    }
                    if let hotkeyError {
                        Text(hotkeyError)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }
                    Hairline()
                    row("Вставка в поля (⇧⏎)") {
                        if AutoType.isTrusted {
                            Text("разрешена").font(.system(size: 13)).foregroundStyle(Theme.success)
                        } else {
                            Button("Разрешить…") {
                                AutoType.requestPermission()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle(height: 28))
                        }
                    }
                    Hairline()
                    toggleRow("После вставки копировать код 2FA", $prefs.copyCodeAfterFill,
                              hint: "Логин и пароль вставятся сами, код останется в буфере для следующего шага")
                    Hairline()
                    row("⏎ в панели") {
                        Picker("", selection: $prefs.enterAction) {
                            ForEach(EnterAction.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                group("Буфер обмена") {
                    row("Очищать скопированное") {
                        Picker("", selection: $prefs.clipboardClearSeconds) {
                            Text("через 10 секунд").tag(10)
                            Text("через 30 секунд").tag(30)
                            Text("через 1 минуту").tag(60)
                            Text("не очищать").tag(0)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Hairline()
                    toggleRow("Скрывать от менеджеров буфера", $prefs.concealClipboard,
                              hint: "Пароли не попадут в историю Raycast, Maccy и подобных")
                }

                group("SSH-агент") {
                    toggleRow("Отдавать SSH-ключи из Ward через агент", $prefs.sshAgentEnabled,
                              hint: "ssh, git и scp берут ключи из Ward — файлов ключей в ~/.ssh не нужно")
                    if prefs.sshAgentEnabled {
                        Hairline()
                        toggleRow("Спрашивать перед каждым использованием ключа", $prefs.sshAgentConfirm,
                                  hint: "Иначе — только уведомление; так видно, если ключ тайком использует другая программа")
                        Hairline()
                        agentStatus
                    }
                }

                group("Терминал и sudo") {
                    toggleRow("Разрешать запросы из Codex и терминала", $prefs.commandAccessEnabled,
                              hint: "Сервер выбираете вы в окне Ward; пароль sudo передаётся помощнику, вход в SSH — по ключу")
                    if prefs.commandAccessEnabled {
                        Hairline()
                        row("Запоминать подтверждение") {
                            Picker("", selection: $prefs.commandApprovalMinutes) {
                                Text("Каждый раз").tag(0)
                                Text("5 минут").tag(5)
                                Text("15 минут").tag(15)
                                Text("1 час").tag(60)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Hairline()
                        VStack(alignment: .leading, spacing: 8) {
                            if let problem = commands.problem {
                                Text(problem).foregroundStyle(Theme.danger)
                            }
                            Text("Codex через Ward MCP предлагает выбрать подходящий сервер в окне Ward и получает только его ID. Выполнение команды подтверждается отдельно. Вручную: меню «…» записи → команда sudo.")
                                .foregroundStyle(Theme.text2)
                            Text("Для SSH нужен известный ключ сервера в ~/.ssh/known_hosts и ключ входа в Ward или ~/.ssh. Ввод данных в команду не поддерживается.")
                                .foregroundStyle(Theme.text2)
                            Button("Отозвать все разрешения") { commands.revoke() }
                                .buttonStyle(SecondaryButtonStyle(height: 30))
                        }
                        .font(.system(size: 12))
                        .padding(16)
                    }
                }

                group("Браузер") {
                    toggleRow("Пароли и passkey в Chrome через расширение Ward", $prefs.browserEnabled,
                              hint: "Расширение подставляет учётки в формы входа и сохраняет passkey — только для сайта открытой вкладки")
                    if prefs.browserEnabled {
                        Hairline()
                        browserStatus
                    }
                }

                group("Резервные копии") {
                    row("Хранить версий") {
                        Picker("", selection: $prefs.backupsToKeep) {
                            Text("20 последних").tag(20)
                            Text("50 последних").tag(50)
                            Text("все").tag(0)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Hairline()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Последняя копия: " + (store.lastBackupAt.map(Format.dayTime) ?? "ещё не было"))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text)
                            Text(store.backups.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Показать в Finder") { NSWorkspace.shared.open(store.backups.directory) }
                            .buttonStyle(SecondaryButtonStyle(height: 28))
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    if let problem = store.backupProblem {
                        Hairline()
                        Text(problem)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    Hairline()
                    mirrorRow
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .frame(width: 760, height: 680)
        .background(Theme.list)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $changingPassword) {
            ChangePasswordSheet().environmentObject(store)
        }
        .onDisappear(perform: stopRecording)
    }

    @ObservedObject private var mirror = BackupMirror.shared
    @ObservedObject private var agent = AgentController.shared
    @ObservedObject private var browser = BrowserController.shared
    @ObservedObject private var commands = CommandController.shared

    private var browserStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = browser.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(browser.isRunning ? "Помощник установлен"
                        + (browser.lastRequestAt.map { " · расширение обращалось " + Format.dayTime($0) } ?? " · расширение ещё не подключалось")
                        : "Запускается…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.success)
            }
            Text("Один раз: chrome://extensions → «Режим разработчика» → «Загрузить распакованное» → папка расширения Ward.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Показать папку расширения") { browser.revealExtension() }.buttonStyle(SecondaryButtonStyle(height: 30))
                Button("Открыть расширения Chrome") { browser.openChromeExtensions() }.buttonStyle(SecondaryButtonStyle(height: 30))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = agent.problem {
                Text("Не запустился: \(problem)").font(.system(size: 12)).foregroundStyle(Theme.danger)
            } else {
                Text(agent.isRunning ? "Работает · " + Format.plural(agent.keyCount, "ключ", "ключа", "ключей") : "Запускается…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.success)
            }
            Text("Добавьте в начало ~/.ssh/config:").font(.system(size: 12)).foregroundStyle(Theme.text2)
            HStack(alignment: .top) {
                Text(AgentController.configSnippet)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                Spacer()
                IconButton(systemName: "doc.on.doc", label: "Скопировать") {
                    Clipboard.copy(AgentController.configSnippet, sensitive: false)
                    Toast.shared.show("Скопировано", over: NSApp.keyWindow)
                }
            }
            .padding(10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            Text("Для одного терминала: export SSH_AUTH_SOCK=\"$HOME/Library/Application Support/Ward/agent.sock\"")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mirrorRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Дублировать на другой диск").font(.system(size: 14)).foregroundStyle(Theme.text)
                Group {
                    if prefs.mirrorBackupPath.isEmpty {
                        Text("Выключено — если умрёт диск Mac, копии пропадут вместе с ним")
                            .foregroundStyle(Theme.text2)
                    } else if let problem = mirror.problem {
                        Text(problem).foregroundStyle(Theme.danger)
                    } else {
                        Text(prefs.mirrorBackupPath + " · " + (mirror.lastMirroredAt.map(Format.dayTime) ?? "ещё не копировали"))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
            }
            Spacer()
            if !prefs.mirrorBackupPath.isEmpty {
                Button("Сейчас") { mirror.mirrorNow() }.buttonStyle(SecondaryButtonStyle(height: 28))
                Button("Отключить") {
                    prefs.mirrorBackupPath = ""
                    mirror.refreshStatus()
                }
                .buttonStyle(SecondaryButtonStyle(height: 28))
            }
            Button(prefs.mirrorBackupPath.isEmpty ? "Выбрать папку…" : "Другая…", action: chooseMirror)
                .buttonStyle(SecondaryButtonStyle(height: 28))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private func chooseMirror() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Копировать сюда"
        panel.message = "Лучше папка на другом физическом диске"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.standardizedFileURL.path.hasPrefix(store.backups.directory.standardizedFileURL.path) {
            return
        }
        prefs.mirrorBackupPath = url.path
        mirror.mirrorNow()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
            VStack(spacing: 0) { content() }.cardStyle()
        }
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.text)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }

    private func toggleRow(_ title: String, _ value: Binding<Bool>, hint: String? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.text)
                if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.text2) }
            }
            Spacer()
            Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }

    private func startRecording() {
        // Пока записываем, старое сочетание снято — иначе Carbon перехватит его раньше нас.
        Hotkey.shared.unregister()
        recording = true
        hotkeyError = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
            // Сочетания только с ⌘ (⌘C, ⌘V, ⌘⇧3…) заняты системой и приложениями — глобально их перехватывать нельзя.
            guard !flags.intersection([.option, .control]).isEmpty else {
                hotkeyError = "Нужен ⌥ или ⌃: сочетания только с ⌘ заняты системой и приложениями"
                stopRecording()
                return nil
            }
            let spec = HotkeySpec(keyCode: UInt32(event.keyCode),
                                  carbonModifiers: HotkeySpec.carbonModifiers(from: flags),
                                  label: HotkeySpec.label(flags: flags, keyCode: event.keyCode,
                                                          characters: event.charactersIgnoringModifiers))
            if Hotkey.shared.register(spec) {
                prefs.hotkey = spec
            } else {
                hotkeyError = "\(spec.label) занято другим приложением — выберите другое"
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { Hotkey.shared.register(prefs.hotkey) }
        recording = false
    }
}

private struct ChangePasswordSheet: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сменить мастер-пароль").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
            SecureField("Текущий пароль", text: $current).wardField()
            SecureField("Новый пароль", text: $new).wardField()
            HStack(spacing: 10) {
                let score = PasswordStrength.evaluate(new).score
                StrengthBar(score: score, width: 96)
                Text(new.isEmpty ? "Минимум \(MasterPasswordPolicy.minLength) символов" : Theme.strengthLabel(score))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
            }
            SecureField("Новый ещё раз", text: $confirm).wardField()
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Сменить", action: submit).buttonStyle(AccentButtonStyle()).disabled(busy)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 400)
        .background(Theme.sheet)
        .environment(\.colorScheme, .dark)
    }

    private func submit() {
        if let problem = MasterPasswordPolicy.problem(new) { error = problem; return }
        guard new == confirm else { error = "Пароли не совпадают"; return }
        busy = true
        Task {
            do {
                try await store.changePassword(current: current, new: new)
                Toast.shared.show("Мастер-пароль изменён")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
