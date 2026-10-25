import AppKit
import SwiftUI
import WardCore

struct EntryDetailPane: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        if let entry = store.entry(nav.selection) {
            EntryDetail(entry: entry)
        } else {
            Text("Выберите запись")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EntryDetail: View {
    let entry: Entry
    var onClose: (() -> Void)?
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var prefs: Prefs
    @State private var reveal = false
    @State private var showHistory = false
    @State private var confirmPurge = false
    @State private var revealedFields: Set<UUID> = []
    @State private var deletingPasskey: Passkey?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if entry.isDeleted { trashBanner }
                    issueBanner
                    if let reminder = entry.reminder { reminderCard(reminder) }
                    if showsFieldsCard { fieldsCard }
                    if entry.isConnection { connectionUsersCard }
                    if !entry.passkeys.isEmpty { passkeysCard }
                    if !entry.fields.isEmpty { customFieldsCard }
                    if let resolved = store.sshKey(for: entry) {
                        SSHKeyCard(entry: entry, ssh: resolved.key, source: resolved.source)
                    } else if entry.sshKeyEntryID != nil {
                        BrokenLinkCard(what: "SSH-ключ")
                    }
                    if let resolved = store.certificate(for: entry) {
                        CertificateCard(entry: entry, bundle: resolved.bundle, source: resolved.source)
                    } else if entry.certificateEntryID != nil {
                        BrokenLinkCard(what: "Сертификат")
                    }
                    if !entry.notes.isEmpty { notesCard }
                    meta
                }
                .padding(.horizontal, 48)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .onChange(of: entry.id) {
            reveal = false
            revealedFields = []
        }
    }

    // MARK: - Части

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let onClose {
                IconButton(systemName: "xmark", label: "Закрыть", size: 30, focusable: false, action: onClose)
            }
            Spacer()
            if entry.isDeleted {
                Button("Восстановить") { Task { await store.restore(entry.id) } }.buttonStyle(SecondaryButtonStyle(height: 30))
            } else {
                Button("Изменить") { nav.edit(entry) }
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    .keyboardShortcut("e", modifiers: .command)
                Menu {
                    Button("Дублировать") {
                        var copy = entry
                        copy.id = UUID()
                        copy.title += " (копия)"
                        copy.history = []
                        copy.useCount = 0
                        copy.lastUsedAt = nil
                        nav.editing = Navigator.Draft(entry: copy, isNew: true)
                    }
                    if let totp = entry.totp {
                        Button("Скопировать ссылку otpauth://") {
                            Clipboard.copy(OTPAuthURI.build(totp), sensitive: true)
                            toast("Ссылка 2FA скопирована")
                        }
                    }
                    if SudoCredentials(entry: entry) != nil {
                        Button("Скопировать команду sudo для Codex") {
                            let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ward").path
                            Clipboard.copy(SudoRequest.quote(cli) + " sudo " + entry.id.uuidString + " -- /usr/bin/id", sensitive: false)
                            toast("Команда скопирована")
                        }
                    }
                    Divider()
                    Button("В корзину", role: .destructive) {
                        Task { await store.trash(entry.id) }
                        onClose?()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 30)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1)))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Avatar(title: entry.title, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(entry.title)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    ForEach(entry.environments, id: \.self) { EnvBadge(env: $0) }
                }
                Text(store.whereLabel(entry)).font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if !entry.isDeleted {
                Button { Task { await store.toggleFavorite(entry.id) } } label: {
                    Image(systemName: entry.favorite ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundStyle(entry.favorite ? Theme.accent : Theme.text3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .help(entry.favorite ? "Убрать из избранного" : "В избранное")
            }
        }
    }

    private var trashBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash").foregroundStyle(Theme.text2)
            Text("Запись в корзине").font(.system(size: 13)).foregroundStyle(Theme.textSoft)
            Spacer()
            Button("Удалить навсегда") { confirmPurge = true }.buttonStyle(DangerButtonStyle())
        }
        .confirmationDialog("Удалить «\(entry.title)» навсегда?", isPresented: $confirmPurge) {
            Button("Удалить", role: .destructive) { Task { await store.purge(entry.id) } }
        } message: {
            Text(purgeWarning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cardStyle()
    }

    @ViewBuilder
    private var issueBanner: some View {
        if !entry.isDeleted, let keyIssue = store.keyIssue(entry) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                Text(keyIssue).font(.system(size: 13)).foregroundStyle(Theme.dangerText)
                Spacer()
                Button("Изменить") { nav.edit(entry) }.buttonStyle(DangerButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.danger.opacity(0.28)))
        }
        let issues = store.issues(entry, reuse: store.reuseCounts())
        let problems = passwordProblems(issues)
        if !entry.isDeleted && !problems.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                Text(problems.joined(separator: ". ")).font(.system(size: 13)).foregroundStyle(Theme.dangerText)
                Spacer()
                // Сгенерировать новый можно только пароль — токен выдаёт сервис, его заменяют вручную.
                if entry.authKind == .password {
                    Button("Заменить") { nav.edit(entry, regenerate: true) }.buttonStyle(DangerButtonStyle())
                } else {
                    Button("Изменить") { nav.edit(entry) }.buttonStyle(DangerButtonStyle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.danger.opacity(0.28)))
        }
    }

    private func passwordProblems(_ issues: (weak: Bool, reusedWith: Int)) -> [String] {
        var problems: [String] = []
        let breached = store.breachCount(entry)
        if breached > 0 { problems.append("Пароль найден в утечках (\(breached.formatted()) раз) — смените его") }
        let reused = issues.reusedWith > 0
            ? "стоит ещё в " + Format.plural(issues.reusedWith, "записи", "записях", "записях") : ""
        switch (issues.weak, reused.isEmpty) {
        case (true, false): problems.append("Слабый пароль, и он же " + reused)
        case (true, true): problems.append("Слабый пароль")
        case (false, false): problems.append("Этот пароль " + reused)
        case (false, true): break
        }
        if let hygiene = entry.hygieneIssue() { problems.append(hygiene) }
        return problems
    }

    private func reminderCard(_ reminder: Reminder) -> some View {
        let due = reminder.isDue()
        return HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 18)).foregroundStyle(due ? Theme.accent : Theme.text2)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.task).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                Text(reminderSubtitle(reminder, due: due)).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if due && !entry.isDeleted {
                Button("Сделано") {
                    Task {
                        if await store.markReminderDone(entry.id) { toast("«\(reminder.task)» — сделано") }
                    }
                }
                .buttonStyle(AccentButtonStyle(height: 30))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(due ? Theme.accent.opacity(0.08) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(due ? Theme.accent.opacity(0.3) : Theme.hairline))
    }

    private func reminderSubtitle(_ r: Reminder, due: Bool) -> String {
        var text = "Каждый месяц " + Format.reminderWindow(r)
        if due { text += " · пора" }
        if let done = r.lastDoneAt { text += " · последний раз " + Format.day(done) }
        return text
    }

    private var purgeWarning: String {
        var parts: [String] = []
        let users = store.entriesLinking(to: entry.id).map(\.title)
        if !users.isEmpty {
            parts.append("Её ключ или сертификат используют: \(users.joined(separator: ", ")) — у них он пропадёт.")
        }
        let viaConnection = store.entriesUsing(connection: entry.id).map(\.title)
        if !viaConnection.isEmpty {
            parts.append("Через это подключение входят: \(viaConnection.joined(separator: ", ")) — у них пропадёт этот шаг.")
        }
        parts.append("Запись исчезнет из Ward. В автоматических копиях она останется, пока их не вытеснят новые.")
        return parts.joined(separator: " ")
    }

    /// Подключение открывается там же, где открыта запись: в листе — листом, в окне — выбором в списке.
    private func openConnection(_ id: UUID) {
        guard let target = store.entry(id) else { return }
        if onClose != nil { nav.inspecting = target } else { nav.open(target) }
    }

    private var passkeysCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.passkeys.enumerated()), id: \.element.id) { index, passkey in
                if index > 0 { Hairline() }
                row("Passkey") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(passkey.userName.isEmpty ? passkey.userDisplayName : passkey.userName).privacySensitive()
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.text)
                        Text("\(passkey.rpID) · создан \(Format.day(passkey.createdAt))"
                             + (passkey.lastUsedAt.map { " · вход \(Format.dayTime($0))" } ?? ""))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    IconButton(systemName: "trash", label: "Удалить passkey") { deletingPasskey = passkey }
                        .disabled(entry.isDeleted)
                }
            }
        }
        .cardStyle()
        .confirmationDialog("Удалить passkey для \(deletingPasskey?.rpID ?? "")?",
                            isPresented: Binding(get: { deletingPasskey != nil }, set: { if !$0 { deletingPasskey = nil } })) {
            Button("Удалить", role: .destructive) {
                if let passkey = deletingPasskey { Task { await store.removePasskey(passkey.id, from: entry.id) } }
                deletingPasskey = nil
            }
        } message: {
            Text("Войти на сайт этим passkey больше не получится — на сайте его тоже стоит удалить.")
        }
    }

    private var connectionUsersCard: some View {
        let users = store.entriesUsing(connection: entry.id)
        return VStack(spacing: 0) {
            row("Через него входят") {
                if users.isEmpty {
                    Text("пока никто — выберите его шагом «Перед входом» у записи")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                } else {
                    FlowRow {
                        ForEach(users) { user in
                            Button { openConnection(user.id) } label: {
                                Chip(text: user.title).hoverBackground(Theme.chipHover, cornerRadius: 12)
                            }
                                .buttonStyle(.plain)
                                .help("Открыть «\(user.title)»")
                        }
                    }
                }
                Spacer()
            }
        }
        .cardStyle()
    }

    // Карта, документ, ключ без пароля — не учётная запись: пустые «Пароль: не задан» и «Добавить 2FA» им не нужны.
    private var showsSecretRow: Bool {
        !(entry.authKind == .password && entry.secret.isEmpty && (entry.hasSSH || entry.hasCertificate || !entry.fields.isEmpty))
    }
    private var showsTOTPRow: Bool {
        entry.totp != nil || !entry.login.isEmpty || !entry.url.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var showsAddress: Bool { !entry.url.trimmingCharacters(in: .whitespaces).isEmpty }
    private var showsFieldsCard: Bool {
        !entry.login.isEmpty || showsSecretRow || showsTOTPRow || showsAddress || !entry.preSteps.isEmpty
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            if !entry.login.isEmpty {
                row(Format.loginLabel(entry.loginKind)) {
                    Text(entry.login).privacySensitive().font(.system(size: 15)).foregroundStyle(Theme.text).textSelection(.enabled)
                    Spacer()
                    copyButton("Скопировать") { copy(entry.login, sensitive: false, "\(Format.loginLabel(entry.loginKind)) скопирован") }
                }
            }
            if showsSecretRow {
                if !entry.login.isEmpty { Hairline() }
                secretRow
            }
            if showsTOTPRow {
                if !entry.login.isEmpty || showsSecretRow { Hairline() }
                totpRow
            }
            if showsAddress {
                if !entry.login.isEmpty || showsSecretRow || showsTOTPRow { Hairline() }
                addressRows
            }
            if !entry.preSteps.isEmpty {
                if !entry.login.isEmpty || showsSecretRow || showsTOTPRow || showsAddress { Hairline() }
                row("Перед входом") {
                    StepsChain(steps: entry.preSteps, open: openConnection)
                    Spacer()
                }
            }
        }
        .cardStyle()
    }

    private var totpRow: some View {
        row("Код 2FA", minHeight: 72) {
            if let totp = entry.totp {
                TOTPCodeView(config: totp, fontSize: 30, ringSize: 24, showsSeconds: true)
                Spacer()
                copyButton("Скопировать код") { copy(TOTP.code(totp), sensitive: true, "Код скопирован") }
            } else {
                Button { nav.edit(entry) } label: {
                    Label("Добавить 2FA", systemImage: "plus").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .hoverLink()
                .disabled(entry.isDeleted)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var addressRows: some View {
        if let address = entry.address {
            row(entry.openURL != nil ? "Сайт" : "Адрес") {
                if let url = entry.openURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text(entry.displayURL).privacySensitive().font(.system(size: 15)).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .hoverLink()
                } else {
                    Text(address.hostPort).privacySensitive().font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text)
                        .textSelection(.enabled).lineLimit(1)
                }
                Spacer()
                copyButton("Скопировать адрес") {
                    copy(entry.openURL != nil ? entry.url.trimmingCharacters(in: .whitespaces) : address.hostPort,
                         sensitive: false, "Адрес скопирован")
                }
                if let url = entry.openURL {
                    IconButton(systemName: "arrow.up.right.square", label: "Открыть в браузере") { NSWorkspace.shared.open(url) }
                }
            }
            if address.looksLikeSSH || entry.hasSSH {
                let command = address.sshCommand(login: entry.login)
                Hairline()
                row("Подключение") {
                    Text(command).privacySensitive().font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    copyButton("Скопировать команду") { copy(command, sensitive: false, "Команда скопирована") }
                }
            }
        } else {
            row("Адрес") {
                Text(entry.url).privacySensitive().font(.system(size: 15)).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(1)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var secretRow: some View {
        switch entry.authKind {
        case .sso:
            row("Вход через") {
                if let target = store.entry(entry.ssoEntryID) {
                    Button { nav.inspecting = nil; nav.open(target) } label: {
                        HStack(spacing: 8) {
                            Avatar(title: target.title, size: 22)
                            Text(target.title).font(.system(size: 15)).foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("другой аккаунт — не выбран").font(.system(size: 15)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
        case .token:
            row("Токен") {
                // Без выделения: ⌘C из текста обошёл бы скрытие от менеджеров буфера и автоочистку.
                Text(reveal ? entry.secret : entry.maskedToken).privacySensitive()
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(reveal ? nil : 1)
                Spacer()
                IconButton(systemName: reveal ? "eye.slash" : "eye", label: reveal ? "Скрыть" : "Показать") { reveal.toggle() }
                copyButton("Скопировать токен") { copy(entry.secret, sensitive: true, "Токен скопирован") }
            }
        case .password:
            let strength = entry.strength
            row("Пароль", alignTop: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if entry.secret.isEmpty {
                        Text("не задан").font(.system(size: 15)).foregroundStyle(Theme.text3)
                    } else {
                        Text(reveal ? entry.secret : String(repeating: "•", count: 14)).privacySensitive()
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                    if !entry.secret.isEmpty {
                        HStack(spacing: 10) {
                            StrengthBar(score: strength.score)
                            Text("\(Theme.strengthLabel(strength.score)) · " + Format.plural(entry.secret.count, "символ", "символа", "символов"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                }
                .padding(.top, 5)
                Spacer()
                if !entry.secret.isEmpty {
                    IconButton(systemName: reveal ? "eye.slash" : "eye", label: reveal ? "Скрыть пароль" : "Показать пароль") { reveal.toggle() }
                    copyButton("Скопировать пароль") { copy(entry.secret, sensitive: true, passwordCopied) }
                }
            }
        }
    }

    private var passwordCopied: String {
        let clear = prefs.clipboardClearSeconds
        return "Пароль скопирован" + (clear > 0 ? " · очистится через \(clear) с" : "")
    }

    private var customFieldsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 { Hairline() }
                let shown = !field.hidden || revealedFields.contains(field.id)
                row(field.name.isEmpty ? "Поле" : field.name) {
                    // Скрытые — без выделения: ⌘C обошёл бы скрытие от менеджеров буфера и автоочистку.
                    if field.hidden {
                        Text(shown ? field.value : String(repeating: "•", count: 8)).privacySensitive()
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                    } else {
                        Text(field.value).privacySensitive().font(.system(size: 15)).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(2)
                    }
                    Spacer()
                    if field.hidden {
                        IconButton(systemName: shown ? "eye.slash" : "eye", label: shown ? "Скрыть" : "Показать") {
                            if shown { revealedFields.remove(field.id) } else { revealedFields.insert(field.id) }
                        }
                    }
                    if !field.value.isEmpty {
                        copyButton("Скопировать") {
                            copy(field.value, sensitive: field.hidden, "«\(field.name)» скопировано")
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Заметки").font(.system(size: 13)).foregroundStyle(Theme.text2)
            Text(entry.notes).privacySensitive()
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Theme.textChip)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .cardStyle()
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text("Создано \(Format.day(entry.createdAt))")
            Text("·")
            Text("Изменено \(Format.day(entry.updatedAt))")
            if !entry.history.isEmpty {
                Text("·")
                Button("История пароля (\(entry.history.count))") { showHistory = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .popover(isPresented: $showHistory) { history }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text3)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Прежние пароли").font(.system(size: 13, weight: .semibold))
                Spacer()
                IconButton(systemName: reveal ? "eye.slash" : "eye", label: reveal ? "Скрыть пароли" : "Показать пароли",
                           size: 28) { reveal.toggle() }
            }
            ForEach(Array(entry.history.enumerated()), id: \.offset) { _, change in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reveal ? change.value : String(repeating: "•", count: 14)).privacySensitive()
                            .font(.system(size: 13, design: .monospaced))
                        Text("до \(Format.day(change.changedAt))").font(.system(size: 11)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    copyButton("Скопировать") { copy(change.value, sensitive: true, "Старый пароль скопирован") }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - Помощники

    private func row<Content: View>(_ label: String, minHeight: CGFloat = 56, alignTop: Bool = false,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        DetailRow(label: label, minHeight: minHeight, alignTop: alignTop, content: content)
    }

    private func copyButton(_ label: String, action: @escaping () -> Void) -> some View {
        IconButton(systemName: "doc.on.doc", label: label, action: action)
    }

    private func copy(_ text: String, sensitive: Bool, _ message: String) {
        Clipboard.copy(text, sensitive: sensitive)
        Task { await store.markUsed(entry.id) }
        toast(message)
    }

    private func toast(_ message: String) {
        Toast.shared.show(message, over: NSApp.keyWindow)
    }
}

/// «VPN A → Basic auth». Шаг-подключение кликабелен: открывает свою запись с адресом, логином и настройками.
struct StepsChain: View {
    let steps: [PreStep]
    var open: ((UUID) -> Void)?
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Text("→").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                switch step {
                case .text(let text):
                    Chip(text: text)
                case .entry(let id):
                    Button { open?(id) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "network").font(.system(size: 10))
                            Text(store.title(of: step)).underline(open != nil)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Theme.chip, in: Capsule())
                        .hoverBackground(Theme.chipHover, cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(open == nil || store.entry(id) == nil)
                    .help("Открыть подключение")
                }
            }
        }
    }
}
