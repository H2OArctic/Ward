import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WardCore

struct EntryEditor: View {
    let isNew: Bool
    @State private var entry: Entry
    @State private var options: GeneratorOptions
    @State private var showKeyInput = false
    @State private var keyInput = ""
    @State private var otpError: String?
    @State private var scanning = false
    @State private var newStep = ""
    @State private var creatingConnection = false
    @State private var newConnectionName = ""
    @State private var reminderOn: Bool
    @State private var reminder: Reminder
    @State private var revealSecret: Bool
    /// Последний пароль из генератора: смена настроек генератора перегенерирует только его, а не введённый вручную.
    @State private var lastGenerated: String?
    @State private var saveError: String?
    @State private var confirmDiscard = false
    /// Когда был сохранён черновик, с которого продолжили правку.
    @State private var restoredAt: Date?
    /// Сохранили или отказались от правок — черновик больше не пишется.
    @State private var finished = false
    /// Запись и напоминание, как они лежат в хранилище, — чтобы не выбросить правки без вопроса.
    private let original: Entry

    private struct DraftState: Equatable {
        var entry: Entry
        var reminderOn: Bool
        var reminder: Reminder
    }

    @State private var saving = false
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    init(draft: Navigator.Draft) {
        isNew = draft.isNew
        original = draft.entry
        var entry = draft.entry
        let options = Prefs.shared.generator
        var generated: String?
        if draft.regenerate {
            entry.authKind = .password
            entry.secret = PasswordGenerator.generate(options)
            generated = entry.secret
        }
        var reminderOn = entry.reminder != nil
        var reminder = entry.reminder ?? Self.defaultReminder
        if let restored = draft.restored {
            entry = restored.entry
            reminderOn = restored.reminderOn
            reminder = restored.reminder
        }
        _entry = State(initialValue: entry)
        _options = State(initialValue: options)
        _reminderOn = State(initialValue: reminderOn)
        _reminder = State(initialValue: reminder)
        _revealSecret = State(initialValue: generated != nil)
        _lastGenerated = State(initialValue: generated)
        _restoredAt = State(initialValue: draft.restored?.savedAt)
    }

    private static let defaultReminder = Reminder(task: "Передать показания", dayFrom: 20, dayTo: 25)

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Новая запись" : "Изменить запись")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 6)

            if let restoredAt {
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.clock").foregroundStyle(Theme.accent)
                    Text("Продолжен черновик от \(Format.dayTime(restoredAt))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                    Spacer()
                    // Не в порядке фокуса: иначе он достался бы кнопке, и случайный пробел выбросил бы черновик.
                    Button("Сбросить черновик", action: { Task { await resetDraft() } })
                        .buttonStyle(SecondaryButtonStyle(height: 28))
                        .focusable(false)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identity
                    loginAndLink
                    steps
                    secret
                    Hairline()
                    // Одинаковый отступ перед каждым разделом: заголовок не прилипает к карточке предыдущего.
                    Group {
                        twoFactor
                        SSHKeyEditor(ssh: $entry.ssh, linkedID: $entry.sshKeyEntryID, entryID: entry.id)
                        CertificateEditor(certificate: $entry.certificate, linkedID: $entry.certificateEntryID, entryID: entry.id)
                        customFields
                        reminderSection
                    }
                    .padding(.top, 6)
                    notes
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }

            HStack(spacing: 8) {
                if let saveError {
                    Text(saveError).font(.system(size: 12)).foregroundStyle(Theme.danger).lineLimit(2)
                }
                Spacer()
                Button("Отмена") { if isDirty { confirmDiscard = true } else { Task { await discard() } } }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .confirmationDialog("Закрыть без сохранения?", isPresented: $confirmDiscard) {
                        Button("Не сохранять", role: .destructive, action: { Task { await discard() } })
                        Button("Продолжить правку", role: .cancel) {}
                    } message: {
                        Text("Изменения в записи пропадут.")
                    }
                Button("Сохранить", action: { Task { await save() } })
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canSave || saving)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Theme.sheetFooter)
            .overlay(alignment: .top) { Hairline() }
        }
        .disabled(saving)
        .frame(width: 620, height: 760)
        .background(Theme.sheet)
        // Лист — отдельное окно: без этого первую кнопку (например, у доп. полей) обводит системная синяя рамка.
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        .onAppear { store.setDraftSaver(id: entry.id) { draftValue } }
        .onDisappear { store.clearDraftSaver(id: entry.id) }
        // Черновик — через секунду после последней правки: переживает блокировку, выход и сбой Ward.
        .task(id: DraftState(entry: entry, reminderOn: reminderOn, reminder: reminder)) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await persistDraft()
        }
        .onChange(of: options) {
            prefs.generator = options
            if entry.secret.isEmpty || entry.secret == lastGenerated { generate() }
        }
    }

    // MARK: - Где и кто

    private struct Place: Hashable {
        var space: VaultSpace
        var companyID: UUID?
        var projectID: UUID?
        var label: String
    }

    private var places: [Place] {
        var result: [Place] = [Place(space: .personal, label: "Личное")]
        func addProjects(space: VaultSpace, company: UUID?, prefix: String) {
            for item in store.tree(in: space, company: company) {
                result.append(Place(space: space, companyID: company, projectID: item.project.id,
                                    label: "\(prefix) › \(store.path(of: item.project.id))"))
            }
        }
        addProjects(space: .personal, company: nil, prefix: "Личное")
        for company in store.companies {
            let prefix = "Работа › \(company.name)"
            result.append(Place(space: .work, companyID: company.id, label: "\(prefix) › Общие доступы"))
            addProjects(space: .work, company: company.id, prefix: prefix)
        }
        return result
    }

    /// Компания записи в редакторе: через проект, сервис или напрямую.
    private var entryCompany: UUID? {
        guard entry.space == .work else { return nil }
        return store.project(entry.projectID)?.companyID ?? store.service(entry.serviceID)?.companyID ?? entry.companyID
    }

    private var currentPlace: String {
        let company = entryCompany
        return places.first {
            $0.space == entry.space && $0.projectID == entry.projectID && (entry.space != .work || $0.companyID == company)
        }?.label ?? (entry.space == .work ? "Работа" : "Личное")
    }

    /// Окружения, из которых выбирают: проекта, а у общей учётки сервиса — сервиса.
    private var offeredEnvironments: [String] {
        if let project = store.project(entry.projectID) { return project.environments }
        if let service = store.service(entry.serviceID) { return service.environments }
        return []
    }

    private var availableServices: [Service] {
        store.services(in: entry.space, company: entryCompany)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Название")
                    TextField("Например, Админка", text: $entry.title).wardField()
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Где")
                    pickerMenu(currentPlace) {
                        ForEach(places, id: \.self) { place in
                            Button(place.label) { choose(place) }
                        }
                    }
                }
            }
            if !availableServices.isEmpty || entry.serviceID != nil {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: entry.projectID == nil ? "Сервис · общая учётка компании"
                                                            : "Сервис · учётка этого проекта в сервисе")
                    pickerMenu(store.service(entry.serviceID)?.name ?? "Нет") {
                        Button("Нет") {
                            entry.serviceID = nil
                            keepOfferedEnvironments()
                        }
                        ForEach(availableServices) { service in
                            Button(service.name) {
                                entry.serviceID = service.id
                                keepOfferedEnvironments()
                            }
                        }
                    }
                }
            }
            if !offeredEnvironments.isEmpty {
                environmentPicker
            }
        }
    }

    /// Окружения записи: одно, несколько (VPN для Stage и Production) или все.
    private var environmentPicker: some View {
        let offered = offeredEnvironments
        let all = Set(offered).isSubset(of: Set(entry.environments))
        return VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Окружения · к каким даёт доступ")
            FlowRow {
                ToggleChip(title: "Все", isOn: all) {
                    entry.environments = all ? [] : offered
                }
                ForEach(offered, id: \.self) { env in
                    ToggleChip(title: env, isOn: entry.environments.contains(env)) {
                        if let i = entry.environments.firstIndex(of: env) {
                            entry.environments.remove(at: i)
                        } else {
                            // Порядок — как у проекта: колонки и метки не прыгают.
                            entry.environments = offered.filter { entry.environments.contains($0) || $0 == env }
                        }
                    }
                }
            }
        }
    }

    /// Сменили проект или сервис — остаются только окружения, которые у нового есть.
    private func keepOfferedEnvironments() {
        let offered = offeredEnvironments
        entry.environments = entry.environments.filter(offered.contains)
    }

    private func choose(_ place: Place) {
        entry.space = place.space
        entry.companyID = place.companyID
        entry.projectID = place.projectID
        if let service = store.service(entry.serviceID), service.space != place.space || service.companyID != place.companyID {
            entry.serviceID = nil
        }
        keepOfferedEnvironments()
        if entry.environments.isEmpty, let first = store.project(place.projectID)?.environments.first {
            entry.environments = [first]
        }
    }

    private func pickerMenu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            .hoverBackground(cornerRadius: 8)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var loginAndLink: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    FieldLabel(text: "Вход по")
                    Spacer()
                    MiniSegments(options: [(LoginKind.email, "почте"), (.phone, "телефону"), (.username, "логину")],
                                 selection: $entry.loginKind)
                }
                TextField(loginPlaceholder, text: $entry.login)
                    .autocorrectionDisabled()
                    .wardField()
                    .onChange(of: entry.login) {
                        if !entry.login.isEmpty { entry.loginKind = LoginKind.detect(entry.login) }
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Адрес · сайт, IP или IP:порт")
                TextField("admin.example.com, 10.0.0.5:22", text: $entry.url).autocorrectionDisabled().wardField()
                if !entry.url.trimmingCharacters(in: .whitespaces).isEmpty && entry.address == nil {
                    Text("Не похоже на адрес: example.com, 10.0.0.5, 10.0.0.5:8080, [2001:db8::1]:22")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private var loginPlaceholder: String {
        switch entry.loginKind {
        case .email: return "you@example.com"
        case .phone: return "+7 900 000-00-00"
        case .username: return "admin"
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Перед входом нужно")
            FlowRow {
                ForEach(Array(entry.preSteps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 4) {
                        if case .entry = step {
                            Image(systemName: "network").font(.system(size: 10)).foregroundStyle(Theme.accent)
                        }
                        Text(store.title(of: step)).font(.system(size: 12)).foregroundStyle(Theme.textChip)
                        Button { entry.preSteps.remove(at: index) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Убрать шаг «\(store.title(of: step))»")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.chip, in: Capsule())
                }
                HStack(spacing: 4) {
                    TextField("+ шаг: Basic auth, SSH-туннель…", text: $newStep)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .frame(width: 190)
                        .onSubmit(addStep)
                    Menu {
                        let connections = store.connections(for: entry).filter { !entry.preSteps.contains(.entry($0.id)) }
                        Section("Подключения") {
                            ForEach(connections) { connection in
                                Button(connection.title) { entry.preSteps.append(.entry(connection.id)) }
                            }
                            Button("Новое подключение…") {
                                newConnectionName = ""
                                creatingConnection = true
                            }
                        }
                        Section("Шаг") {
                            ForEach(["Basic auth", "SSH-туннель", "Корпоративный прокси"], id: \.self) { preset in
                                Button(preset) { entry.preSteps.append(.text(preset)) }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            Toggle(isOn: $entry.isConnection) {
                Text("Эта запись — подключение (VPN, туннель, прокси): её можно выбирать шагом у других записей")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
            }
            .toggleStyle(.checkbox)
        }
        .alert("Новое подключение", isPresented: $creatingConnection) {
            TextField("VPN A, туннель к базе…", text: $newConnectionName)
            Button("Создать", action: { Task { await createConnection() } })
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Создастся запись-подключение с полями VPN — адрес, логин и настройки заполните в ней потом.")
        }
    }

    private func addStep() {
        let step = newStep.trimmingCharacters(in: .whitespaces)
        guard !step.isEmpty else { return }
        entry.preSteps.append(.text(step))
        newStep = ""
    }

    /// Подключение сохраняется сразу отдельной записью — в том же пространстве и компании, что и эта.
    private func createConnection() async {
        let name = newConnectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var connection = Entry(title: name, space: entry.space)
        connection.companyID = entryCompany
        connection.isConnection = true
        connection.loginKind = .username
        connection.fields = Self.vpnFields
        guard await store.save(connection) else {
            otpError = nil
            saveError = store.lastError
            store.lastError = nil
            return
        }
        entry.preSteps.append(.entry(connection.id))
    }

    private static var vpnFields: [CustomField] {
        [CustomField(name: "Протокол", value: "WireGuard"), CustomField(name: "Сервер"),
         CustomField(name: "Общий ключ (PSK)", hidden: true), CustomField(name: "Конфигурация", hidden: true)]
    }

    // MARK: - Пароль, токен, SSO

    private var secret: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                FieldLabel(text: secretLabel)
                Spacer()
                MiniSegments(options: [(AuthKind.password, "пароль"), (.token, "токен"), (.sso, "через аккаунт")],
                             selection: $entry.authKind)
            }
            switch entry.authKind {
            case .sso:
                let accounts = store.active.filter { $0.id != entry.id && $0.authKind != .sso && !$0.secret.isEmpty }
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                Menu {
                    ForEach(accounts) { other in
                        Button("\(other.title) — \(other.login.isEmpty ? store.whereLabel(other) : other.login)") {
                            entry.ssoEntryID = other.id
                        }
                    }
                    if accounts.isEmpty {
                        Text("Пока нет записей с паролем")
                    }
                } label: {
                    HStack {
                        Text(store.entry(entry.ssoEntryID)?.title ?? "Выберите аккаунт: Google, Microsoft, GitHub…")
                            .foregroundStyle(entry.ssoEntryID == nil ? Theme.text3 : Theme.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                    .hoverBackground(cornerRadius: 8)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                Text(accounts.isEmpty
                     ? "Для сайтов с кнопкой «Войти через Google» и т. п. Сначала добавьте запись самого аккаунта "
                        + "(например, «Google» с почтой и паролем), затем выберите её здесь."
                     : "Для сайтов с кнопкой «Войти через Google» и т. п.: своего пароля у записи нет — "
                        + "⏎ и ⇧⏎ в быстрой панели берут логин и пароль из выбранного аккаунта.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            case .token:
                HStack(spacing: 8) {
                    secretField("Вставьте токен")
                    revealButton
                }
            case .password:
                HStack(spacing: 8) {
                    secretField("Пароль")
                    revealButton
                    Button(action: generate) {
                        Label("Сгенерировать", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 38))
                }
                HStack(spacing: 14) {
                    StrengthBar(score: entry.strength.score, width: 96)
                    Text("Длина \(options.length)").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: Binding(get: { Double(options.length) }, set: { options.length = Int($0) }), in: Double(GeneratorOptions.lengths.lowerBound)...Double(GeneratorOptions.lengths.upperBound))
                        .frame(width: 120)
                        .tint(Theme.accent)
                    CheckToggle(title: "0–9", isOn: $options.digits)
                    CheckToggle(title: "!#$", isOn: $options.symbols)
                    CheckToggle(title: "Слова", isOn: $options.words)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func secretField(_ placeholder: String) -> some View {
        Group {
            if revealSecret {
                TextField(placeholder, text: $entry.secret)
            } else {
                SecureField(placeholder, text: $entry.secret)
            }
        }
        .font(.system(size: 14, design: .monospaced))
        .autocorrectionDisabled()
        .wardField()
    }

    private var revealButton: some View {
        IconButton(systemName: revealSecret ? "eye.slash" : "eye", label: revealSecret ? "Скрыть" : "Показать",
                   size: 38) { revealSecret.toggle() }
    }

    private func generate() {
        entry.secret = PasswordGenerator.generate(options)
        lastGenerated = entry.secret
        revealSecret = true
    }

    private var secretLabel: String {
        switch entry.authKind {
        case .password: return "Пароль"
        case .token: return "Токен или ключ API"
        case .sso: return "Вход через"
        }
    }

    // MARK: - 2FA

    private var twoFactor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Двухфакторная аутентификация").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            if let totp = entry.totp {
                KeySummary(icon: "checkmark", title: "2FA подключена",
                           detail: [totp.issuer, totp.account].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                           subtitle: "\(totp.digits) цифр · \(totp.period) с · \(totp.algorithm.rawValue.replacingOccurrences(of: "SHA", with: "SHA-")) · сверьте с сайтом",
                           ok: true, onRemove: { entry.totp = nil }) {
                    TOTPCodeView(config: totp, fontSize: 22, ringSize: 20).fixedSize()
                }
            } else {
                HStack(spacing: 8) {
                    sourceButton("Найти QR на экране", "qrcode.viewfinder", highlighted: true, busy: scanning, action: scanScreen)
                    sourceButton("Вставить ключ", "key", highlighted: showKeyInput) { showKeyInput.toggle() }
                    sourceButton("Из картинки", "photo", action: pickImage)
                }
                if showKeyInput {
                    HStack(spacing: 8) {
                        TextField("Секретный ключ или ссылка otpauth://", text: $keyInput)
                            .font(.system(size: 13, design: .monospaced))
                            .autocorrectionDisabled()
                            .onSubmit(applyKey)
                            .wardField()
                        Button("Добавить", action: applyKey).buttonStyle(SecondaryButtonStyle(height: 38))
                    }
                }
            }
            if let otpError {
                Text(otpError).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
        }
    }

    private func sourceButton(_ title: String, _ icon: String, highlighted: Bool = false, busy: Bool = false,
                              action: @escaping () -> Void) -> some View {
        SourceTile(title: title, icon: icon, highlighted: highlighted, busy: busy, action: action)
    }

    private func scanScreen() {
        scanning = true
        otpError = nil
        Task {
            do {
                accept(try await QRScanner.scanScreens(), source: "на экране")
            } catch {
                otpError = error.localizedDescription
            }
            scanning = false
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { accept(await QRScanner.scanFiles([url]), source: "на картинке") }
    }

    private func accept(_ payloads: [String], source: String) {
        let configs = payloads.flatMap(TOTPConfig.parseAll)
        guard let config = configs.first else {
            otpError = payloads.isEmpty ? "QR-код \(source) не найден" : "QR-код найден, но это не код 2FA"
            return
        }
        otpError = configs.count > 1 ? manyCodesHint(configs.count) : nil
        entry.totp = config
        fillFromTOTP(config)
    }

    private func manyCodesHint(_ count: Int) -> String {
        "В QR " + Format.plural(count, "код", "кода", "кодов")
            + " — взят первый. Все сразу: «Импорт и экспорт» → Google Authenticator"
    }

    private func applyKey() {
        let configs = TOTPConfig.parseAll(keyInput)
        guard let config = configs.first else {
            otpError = "Не похоже на ключ 2FA: нужен base32-ключ или ссылка otpauth://"
            return
        }
        otpError = configs.count > 1 ? manyCodesHint(configs.count) : nil
        keyInput = ""
        showKeyInput = false
        entry.totp = config
        fillFromTOTP(config)
    }

    private func fillFromTOTP(_ config: TOTPConfig) {
        if entry.title.trimmingCharacters(in: .whitespaces).isEmpty, let issuer = config.issuer { entry.title = issuer }
        if entry.login.isEmpty, let account = config.account {
            entry.login = account
            entry.loginKind = LoginKind.detect(account)
        }
    }

    // MARK: - Дополнительные поля

    private static let templates: [(title: String, fields: [CustomField])] = [
        ("Банковская карта", [CustomField(name: "Номер карты", hidden: true), CustomField(name: "Держатель"),
                              CustomField(name: "Срок (ММ/ГГ)"), CustomField(name: "CVV", hidden: true),
                              CustomField(name: "PIN", hidden: true)]),
        ("Wi-Fi", [CustomField(name: "Сеть (SSID)"), CustomField(name: "Шифрование", value: "WPA2/WPA3")]),
        ("VPN", vpnFields),
        ("Документ", [CustomField(name: "Номер"), CustomField(name: "Кем выдан"), CustomField(name: "Дата выдачи"),
                      CustomField(name: "Действует до")]),
        ("Секретный вопрос", [CustomField(name: "Вопрос"), CustomField(name: "Ответ", hidden: true)]),
    ]

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Дополнительные поля").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            ForEach($entry.fields) { $field in
                HStack(spacing: 8) {
                    TextField("Название", text: $field.name)
                        .autocorrectionDisabled()
                        .wardField()
                        .frame(width: 170)
                    Group {
                        if field.hidden {
                            SecureField("Значение", text: $field.value)
                        } else {
                            TextField("Значение", text: $field.value)
                        }
                    }
                    .autocorrectionDisabled()
                    .wardField()
                    IconButton(systemName: field.hidden ? "eye.slash" : "eye",
                               label: field.hidden ? "Скрытое — сделать обычным" : "Обычное — сделать скрытым", size: 38) {
                        field.hidden.toggle()
                    }
                    IconButton(systemName: "minus.circle", label: "Убрать поле", size: 38) {
                        entry.fields.removeAll { $0.id == field.id }
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    entry.fields.append(CustomField(name: ""))
                } label: {
                    Label("Поле", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle(height: 30))
                Menu {
                    ForEach(Self.templates, id: \.title) { template in
                        Button(template.title) {
                            // Новые id: шаблон можно добавить дважды (две карты в одной записи).
                            entry.fields += template.fields.map { CustomField(name: $0.name, value: $0.value, hidden: $0.hidden) }
                        }
                    }
                } label: {
                    Text("Шаблон…")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            if entry.fields.isEmpty {
                Text("PIN, номер карты, секретный вопрос — всё, чему нет своего поля. Скрытые поля копируются как пароль.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    // MARK: - Напоминание и заметки

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $reminderOn) {
                Text("Повторять каждый месяц").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            if reminderOn {
                HStack(spacing: 10) {
                    TextField("Что сделать", text: $reminder.task).wardField()
                    Text("с").font(.system(size: 13)).foregroundStyle(Theme.text2)
                    dayPicker($reminder.dayFrom)
                    Text("по").font(.system(size: 13)).foregroundStyle(Theme.text2)
                    dayPicker($reminder.dayTo)
                    Text("число").font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                Text("В эти дни запись поднимется наверх быстрой панели и попадёт в «Сейчас нужно».")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private func dayPicker(_ value: Binding<Int>) -> some View {
        Picker("", selection: value) {
            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
        }
        .labelsHidden()
        .frame(width: 64)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Заметки")
            TextEditor(text: $entry.notes)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 72)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }

    // MARK: - Сохранение

    /// Незаконченная правка — в черновик внутри хранилища; вернулись к исходному — черновик не нужен.
    private var draftValue: EntryDraft? {
        guard !finished, isDirty else { return nil }
        return EntryDraft(entry: entry, isNew: isNew, reminderOn: reminderOn, reminder: reminder)
    }

    private func persistDraft() async {
        guard !finished, !saving else { return }
        guard isDirty else {
            await store.removeDraft(entry.id)
            return
        }
        if let saved = store.draft(entry.id), saved.entry == entry, saved.reminderOn == reminderOn, saved.reminder == reminder {
            return
        }
        await store.saveDraft(EntryDraft(entry: entry, isNew: isNew, reminderOn: reminderOn, reminder: reminder))
    }

    private func resetDraft() async {
        entry = original
        reminderOn = original.reminder != nil
        reminder = original.reminder ?? Self.defaultReminder
        restoredAt = nil
        await store.removeDraft(entry.id)
    }

    private func discard() async {
        finished = true
        await store.removeDraft(entry.id)
        dismiss()
    }

    private var isDirty: Bool {
        if entry != original || reminderOn != (original.reminder != nil) { return true }
        return reminderOn && reminder != original.reminder
    }

    private var canSave: Bool {
        !entry.title.trimmingCharacters(in: .whitespaces).isEmpty || entry.host != nil || !entry.login.isEmpty
    }

    /// Запись в том виде, в каком её сохраняет «Сохранить». `nil` — её удалили, пока редактировали.
    private func prepared() -> Entry? {
        var result = entry
        result.title = result.title.trimmingCharacters(in: .whitespaces)
        if result.title.isEmpty { result.title = result.host ?? result.login }
        result.url = result.url.trimmingCharacters(in: .whitespaces)
        result.login = result.login.trimmingCharacters(in: .whitespaces)
        if result.authKind != .sso { result.ssoEntryID = nil }
        if result.authKind == .sso { result.secret = "" }
        result.fields = result.fields
            .map { var f = $0; f.name = f.name.trimmingCharacters(in: .whitespaces); return f }
            .filter { !$0.name.isEmpty || !$0.value.isEmpty }
        if result.ssh?.isEmpty == true || result.sshKeyEntryID != nil { result.ssh = nil }
        if result.certificate?.isEmpty == true || result.certificateEntryID != nil { result.certificate = nil }
        if reminderOn {
            var r = reminder
            r.task = r.task.trimmingCharacters(in: .whitespaces)
            if r.task.isEmpty { r.task = "Зайти" }
            result.reminder = r
        } else {
            result.reminder = nil
        }
        // Пока лист был открыт, запись могли использовать, отметить или убрать в корзину из быстрой панели:
        // редактор меняет только свои поля, остальное берём из хранилища, а не из снимка на момент открытия.
        if !isNew {
            guard let current = store.entry(result.id) else { return nil }
            result.favorite = current.favorite
            result.deletedAt = current.deletedAt
            result.useCount = current.useCount
            result.lastUsedAt = current.lastUsedAt
            result.history = current.history
            // Passkey сохраняют из браузера, пока лист открыт — редактор их не трогает.
            result.passkeys = current.passkeys
            result.passwordUpdatedAt = current.passwordUpdatedAt
            result.createdAt = current.createdAt
            // «Сделано» могли отметить в быстрой панели (⌘D) — не откатываем отметку снимком редактора.
            if result.reminder != nil { result.reminder?.lastDoneAt = current.reminder?.lastDoneAt }
        }
        return result
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        guard let result = prepared() else {
            saveError = "Запись удалили, пока её редактировали"
            return
        }
        // Не сохранилось — лист остаётся открытым, введённое не пропадает.
        guard await store.save(result, requireExisting: !isNew) else {
            saveError = store.lastError
            store.lastError = nil
            return
        }
        let staysInView = (nav.currentProjectID != nil && nav.currentProjectID == result.projectID)
            || (nav.currentServiceID != nil && nav.currentServiceID == result.serviceID)
        finished = true
        await store.removeDraft(result.id)
        if !staysInView { nav.open(result) }
        dismiss()
    }
}

/// Простой перенос чипов по строкам.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
