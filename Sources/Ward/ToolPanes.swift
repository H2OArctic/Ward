import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WardCore

struct GeneratorPane: View {
    @EnvironmentObject private var prefs: Prefs
    @State private var password = PasswordGenerator.generate(Prefs.shared.generator)

    var body: some View {
        let strength = PasswordStrength.evaluate(password)
        VStack(alignment: .leading, spacing: 24) {
            Text("Генератор").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 16) {
                Text(password)
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    StrengthBar(score: strength.score)
                    Text("\(Theme.strengthLabel(strength.score)) · " + Format.plural(password.count, "символ", "символа", "символов"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                    Spacer()
                    Button { password = PasswordGenerator.generate(prefs.generator) } label: {
                        Label("Новый", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Скопировать") {
                        Clipboard.copy(password, sensitive: true)
                        Toast.shared.show("Пароль скопирован", over: NSApp.keyWindow)
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(24)
            .cardStyle()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Text(prefs.generator.words ? "Слов: \(min(max(prefs.generator.length / 5, 3), 10))" : "Длина \(prefs.generator.length)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSoft)
                        .frame(width: 80, alignment: .leading)
                    Slider(value: Binding(get: { Double(prefs.generator.length) },
                                          set: { prefs.generator.length = Int($0) }), in: Double(GeneratorOptions.lengths.lowerBound)...Double(GeneratorOptions.lengths.upperBound))
                        .tint(Theme.accent)
                        .frame(width: 320)
                }
                HStack(spacing: 20) {
                    CheckToggle(title: "Цифры", isOn: $prefs.generator.digits)
                    CheckToggle(title: "Символы !#$", isOn: $prefs.generator.symbols)
                    CheckToggle(title: "Слова вместо символов", isOn: $prefs.generator.words)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
        .onChange(of: prefs.generator) { password = PasswordGenerator.generate(prefs.generator) }
    }
}

struct ImportExportPane: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @State private var importSpace: VaultSpace = .personal
    @State private var message: String?
    @State private var backupURL: URL?
    @State private var backupPassword = ""
    @State private var showLinkInput = false
    @State private var linkInput = ""
    @State private var confirmCSVExport = false

    var body: some View {
        // Прокрутка начинается ниже заголовка окна, как в карточке записи: под самим заголовком
        // macOS рисует свой эффект края прокрутки.
        VStack(spacing: 0) {
        Color.clear.frame(height: 40)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Импорт и экспорт").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)

                HStack(spacing: 12) {
                    Text("Импортировать").font(.system(size: 13)).foregroundStyle(Theme.text2)
                    Picker("", selection: $importSpace) {
                        Text("в Личное").tag(VaultSpace.personal)
                        Text("в Работу").tag(VaultSpace.work)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                card(title: "Из Google Authenticator",
                     text: "На телефоне: ⋮ → «Перенести коды» → «Экспорт». Сделайте скриншот QR и перешлите на Mac (AirDrop), затем «Из картинок». Если QR несколько — выберите все картинки сразу. Коды, которые уже есть в Ward, не задублируются.") {
                    Button("Из картинок…", action: importGoogleImages).buttonStyle(AccentButtonStyle())
                    Button("Найти QR на экране", action: importGoogleScreen).buttonStyle(SecondaryButtonStyle())
                    Button("Вставить ссылку…") { showLinkInput = true }.buttonStyle(SecondaryButtonStyle())
                }

                card(title: "Импорт из CSV",
                     text: "Пароли Apple и Safari, Chrome, Firefox, Bitwarden, Excel. Коды 2FA из колонки OTPAuth тоже переносятся. После импорта удалите CSV — в нём всё открытым текстом.") {
                    Button("Выбрать файл…", action: { Task { await importCSV() } }).buttonStyle(AccentButtonStyle())
                }

                card(title: "Резервная копия",
                     text: "Зашифрованный файл .wardbackup. Открывается мастер-паролем, который был на момент экспорта. При восстановлении добавляются только недостающие записи.") {
                    Button("Экспорт…", action: { Task { await exportBackup() } }).buttonStyle(AccentButtonStyle())
                    Button("Восстановить из копии…", action: pickBackup).buttonStyle(SecondaryButtonStyle())
                }

                card(title: "Экспорт в CSV",
                     text: "Чтобы перенести пароли в другой менеджер или браузер. Файл — открытым текстом: логины, пароли, 2FA и дополнительные поля. SSH-ключи и сертификаты в CSV не попадают.") {
                    Button("Экспорт в CSV…") { confirmCSVExport = true }.buttonStyle(SecondaryButtonStyle())
                }

                card(title: "Автоматические копии",
                     text: "После каждого изменения Ward сохраняет зашифрованную копию. Последняя: "
                        + (store.lastBackupAt.map(Format.dayTime) ?? "ещё не было") + ".") {
                    Button("Показать в Finder") { NSWorkspace.shared.open(store.backups.directory) }
                        .buttonStyle(SecondaryButtonStyle())
                }

                if let message {
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.textSoft)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
        .alert("Пароль от копии", isPresented: Binding(get: { backupURL != nil }, set: { if !$0 { backupURL = nil } })) {
            SecureField("Мастер-пароль копии", text: $backupPassword)
            Button("Восстановить", action: restoreBackup)
            Button("Отмена", role: .cancel) { backupPassword = "" }
        } message: {
            Text(backupURL?.lastPathComponent ?? "")
        }
        .alert("Ссылка из Google Authenticator", isPresented: $showLinkInput) {
            TextField("otpauth-migration://offline?data=…", text: $linkInput)
            Button("Импортировать") {
                let payload = linkInput
                linkInput = ""
                Task { await importCodes(from: [payload]) }
            }
            Button("Отмена", role: .cancel) { linkInput = "" }
        }
        .confirmationDialog("Сохранить пароли открытым текстом?", isPresented: $confirmCSVExport) {
            Button("Экспортировать", role: .destructive, action: exportCSV)
        } message: {
            Text("Любая программа на этом Mac сможет прочитать файл — удалите его сразу после переноса. "
                 + "В CSV не попадут SSH-ключи, сертификаты, история паролей и напоминания: для полной копии — «Резервная копия». "
                 + "Не открывайте файл в Excel: он может исказить пароли.")
        }
        .onAppear { importSpace = nav.space }
    }

    private func card<Buttons: View>(title: String, text: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { buttons() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func importGoogleImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importCodes(from: await QRScanner.scanFiles(urls)) }
    }

    private func importGoogleScreen() {
        Task {
            do {
                await importCodes(from: try await QRScanner.scanScreens())
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func importCodes(from payloads: [String]) async {
        let migrations = payloads.compactMap(GoogleAuthMigration.parse)
        let skipped = migrations.reduce(0) { $0 + $1.skipped }
        let codes = payloads.flatMap(TOTPConfig.parseAll)
        guard !codes.isEmpty else {
            message = payloads.isEmpty ? "QR-код не найден"
                : skipped > 0 ? "Нашлись только счётчиковые коды (HOTP) — Ward их не поддерживает"
                : "Это не экспорт Google Authenticator и не код 2FA"
            return
        }
        let result: (added: Int, duplicates: Int)
        do {
            result = try await store.importCodes(codes, space: importSpace, company: nav.company)
        } catch {
            message = "Не удалось сохранить: \(error.localizedDescription)"
            return
        }
        var parts = ["Добавлено: " + Format.plural(result.added, "код", "кода", "кодов")]
        if result.duplicates > 0 { parts.append("уже были: \(result.duplicates)") }
        if skipped > 0 { parts.append("пропущено HOTP: \(skipped)") }
        message = parts.joined(separator: " · ")
    }

    private func importCSV() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try await store.importCSV(from: url, space: importSpace, company: nav.company)
            message = "Импортировано: " + Format.plural(result.added, "запись", "записи", "записей")
                + (result.duplicates > 0 ? " · уже были: \(result.duplicates)" : "")
        } catch {
            message = "Не удалось импортировать: \(error.localizedDescription)"
        }
    }

    private func exportBackup() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ward \(Format.day(Date())).\(BackupStore.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await store.exportBackup(to: url)
            message = "Копия сохранена: \(url.lastPathComponent)"
        } catch {
            message = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ward \(Format.day(Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BackupStore.writePrivate(Data(CSVExport.export(store.active).utf8), to: url)
            var notes = ["Экспортировано: " + Format.plural(store.active.count, "запись", "записи", "записей")
                + " → \(url.lastPathComponent). Удалите файл после переноса."]
            do {
                try PlaintextFile.excludeFromBackup(url)
            } catch {
                notes.append("Не удалось исключить файл из Time Machine: \(error.localizedDescription)")
            }
            if let warning = PlaintextFile.cloudWarning(for: url) { notes.append(warning) }
            message = notes.joined(separator: " ")
        } catch {
            message = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    private func pickBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: BackupStore.fileExtension) ?? .data]
        panel.directoryURL = store.backups.directory
        guard panel.runModal() == .OK else { return }
        backupURL = panel.url
    }

    private func restoreBackup() {
        guard let url = backupURL else { return }
        let password = backupPassword
        backupPassword = ""
        Task {
            do {
                let added = try await store.importBackup(from: url, password: password)
                message = "Добавлено из копии: " + Format.plural(added, "запись", "записи", "записей")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
