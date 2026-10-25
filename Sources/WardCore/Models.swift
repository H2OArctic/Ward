import Foundation

public enum VaultSpace: String, Codable, CaseIterable, Sendable {
    case personal, work
}

public enum LoginKind: String, Codable, CaseIterable, Sendable {
    case email, phone, username

    public static func detect(_ login: String) -> LoginKind {
        if login.contains("@") { return .email }
        let digits = login.filter(\.isNumber)
        let rest = login.filter { !$0.isNumber && !" +-()".contains($0) }
        if digits.count >= 7 && rest.isEmpty { return .phone }
        return .username
    }
}

public enum AuthKind: String, Codable, CaseIterable, Sendable {
    case password, token, sso
}

public struct PasswordChange: Codable, Hashable, Sendable {
    public var value: String
    public var changedAt: Date

    public init(value: String, changedAt: Date) {
        self.value = value
        self.changedAt = changedAt
    }
}

/// Периодическое дело по записи: «передать показания с 20 по 25 число каждого месяца».
public struct Reminder: Codable, Hashable, Sendable {
    public var task: String
    public var dayFrom: Int
    public var dayTo: Int
    public var lastDoneAt: Date?

    public init(task: String, dayFrom: Int, dayTo: Int, lastDoneAt: Date? = nil) {
        self.task = task
        self.dayFrom = dayFrom
        self.dayTo = dayTo
        self.lastDoneAt = lastDoneAt
    }

    /// Окно открыто и в этом месяце ещё не отмечено. Окно может переходить через конец месяца (25 → 5).
    public func isDue(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let start = windowStart(containing: date, calendar: calendar) else { return false }
        if let done = lastDoneAt, done >= start { return false }
        return true
    }

    /// «31 числа» в коротком месяце — это его последний день, иначе окно в феврале не наступило бы никогда.
    func windowStart(containing date: Date, calendar: Calendar) -> Date? {
        let day = calendar.component(.day, from: date)
        let from = min(max(dayFrom, 1), 31)
        let to = min(max(dayTo, 1), 31)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        func length(_ month: Date) -> Int { calendar.range(of: .day, in: .month, for: month)!.count }
        func dayOf(_ month: Date, _ n: Int) -> Date { calendar.date(byAdding: .day, value: n - 1, to: month)! }
        let days = length(monthStart)

        if from <= to {
            let first = min(from, days), last = min(to, days)
            return (first...last).contains(day) ? dayOf(monthStart, first) : nil
        }
        let first = min(from, days)
        if day >= first { return dayOf(monthStart, first) }
        if day <= to {
            let previous = calendar.date(byAdding: .month, value: -1, to: monthStart)!
            return dayOf(previous, min(from, length(previous)))
        }
        return nil
    }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var space: VaultSpace
    public var environments: [String]
    /// Родительский проект: «Магазин › API › Платежи». `nil` — проект верхнего уровня.
    public var parentID: UUID?
    /// Компания (во «Работе»). У подпроектов — всегда та же, что у родителя.
    public var companyID: UUID?

    public init(id: UUID = UUID(), name: String, space: VaultSpace, environments: [String] = [], parentID: UUID? = nil,
                companyID: UUID? = nil) {
        self.id = id
        self.name = name
        self.space = space
        self.environments = environments
        self.parentID = parentID
        self.companyID = companyID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        space = try c.decodeIfPresent(VaultSpace.self, forKey: .space) ?? .work
        environments = try c.decodeIfPresent([String].self, forKey: .environments) ?? []
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        companyID = try c.decodeIfPresent(UUID.self, forKey: .companyID)
    }
}

/// Компания во «Работе»: её общие доступы, проекты и сервисы. Компаний может быть несколько (работа, клиенты).
public struct Company: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Внешний сервис компании: провайдер серверов, SaaS, чужой API. В нём бывают общие учётки (у записи нет проекта)
/// и учётки конкретных проектов (у записи есть и проект, и сервис). Общие учётки видны проектам из `projectIDs`.
public struct Service: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var space: VaultSpace
    public var companyID: UUID?
    /// Сайт или адрес API сервиса — для справки и значка.
    public var url: String
    /// Окружения общих учёток (у чужого API — Sandbox и Production).
    public var environments: [String]
    /// Проекты, которые пользуются общими учётками сервиса.
    public var projectIDs: [UUID]

    public init(id: UUID = UUID(), name: String, space: VaultSpace, companyID: UUID? = nil, url: String = "",
                environments: [String] = [], projectIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.space = space
        self.companyID = companyID
        self.url = url
        self.environments = environments
        self.projectIDs = projectIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        space = try c.decodeIfPresent(VaultSpace.self, forKey: .space) ?? .work
        companyID = try c.decodeIfPresent(UUID.self, forKey: .companyID)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        environments = try c.decodeIfPresent([String].self, forKey: .environments) ?? []
        projectIDs = try c.decodeIfPresent([UUID].self, forKey: .projectIDs) ?? []
    }
}

/// Ключи, под которыми сервисы лежали, пока назывались интеграциями.
enum LegacyKeys: String, CodingKey {
    case integrations, integrationID
    /// Одно окружение у записи — до того, как их стало можно выбирать несколько.
    case environment
}

/// Шаг перед входом: просто текст («Basic auth») или ссылка на запись-подключение («VPN A» со своими данными).
public enum PreStep: Codable, Hashable, Sendable {
    case text(String)
    case entry(UUID)

    private enum CodingKeys: String, CodingKey { case text, entry }

    /// Текстовый шаг хранится строкой — как все шаги до появления ссылок, поэтому старые записи читаются как есть.
    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .text(text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .entry) {
            self = .entry(id)
        } else {
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var c = encoder.singleValueContainer()
            try c.encode(text)
        case .entry(let id):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .entry)
        }
    }
}

/// Произвольное поле записи: номер карты, PIN, секретный вопрос, номер договора.
public struct CustomField: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    /// Скрытое — показывается точками и копируется как пароль.
    public var hidden: Bool

    public init(id: UUID = UUID(), name: String, value: String = "", hidden: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.hidden = hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

public struct Entry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var space: VaultSpace
    public var projectID: UUID?
    /// Учётка во внешнем сервисе. Вместе с `projectID` — учётка этого проекта у сервиса, без — общая.
    public var serviceID: UUID?
    /// Общий доступ компании (без проекта и сервиса). У записей проекта или сервиса компания берётся у них.
    public var companyID: UUID?
    /// Окружения проекта (или сервиса), к которым даёт доступ запись. VPN «Офис» — и к Stage, и к Production.
    public var environments: [String]
    public var loginKind: LoginKind
    public var login: String
    public var authKind: AuthKind
    /// Пароль или токен — в зависимости от `authKind`.
    public var secret: String
    public var ssoEntryID: UUID?
    public var url: String
    /// Что нужно сделать до входа: «VPN A» (запись-подключение), «Basic auth», «SSH-туннель».
    public var preSteps: [PreStep]
    /// Подключение (VPN, туннель, прокси): его можно выбрать шагом «Перед входом» у других записей.
    public var isConnection: Bool
    public var totp: TOTPConfig?
    public var ssh: SSHKey?
    /// Ключ берётся из другой записи — один ключ на много серверов, заменяется в одном месте.
    public var sshKeyEntryID: UUID?
    public var certificate: CertificateBundle?
    public var certificateEntryID: UUID?
    /// Passkey сайта этой записи (WebAuthn): вход без пароля через расширение браузера.
    public var passkeys: [Passkey]
    public var reminder: Reminder?
    public var notes: String
    public var fields: [CustomField]
    public var favorite: Bool
    public var history: [PasswordChange]
    /// Когда пароль последний раз задавали или меняли (в том числе впервые, когда истории ещё нет).
    public var passwordUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), title: String = "", space: VaultSpace = .personal, now: Date = Date()) {
        self.id = id
        self.title = title
        self.space = space
        projectID = nil
        serviceID = nil
        companyID = nil
        environments = []
        loginKind = .email
        login = ""
        authKind = .password
        secret = ""
        ssoEntryID = nil
        url = ""
        preSteps = []
        isConnection = false
        totp = nil
        ssh = nil
        sshKeyEntryID = nil
        certificate = nil
        certificateEntryID = nil
        passkeys = []
        reminder = nil
        notes = ""
        fields = []
        favorite = false
        history = []
        passwordUpdatedAt = nil
        createdAt = now
        updatedAt = now
        lastUsedAt = nil
        useCount = 0
        deletedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, space, projectID, serviceID, companyID, environments, loginKind, login, authKind, secret, ssoEntryID, url,
             preSteps, isConnection, totp, ssh, sshKeyEntryID, certificate, certificateEntryID, passkeys, reminder, notes, fields, favorite, history, passwordUpdatedAt, createdAt, updatedAt, lastUsedAt, useCount, deletedAt
    }

    // Все поля, кроме id, опциональны при чтении — чтобы новые поля не ломали старые хранилища.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        space = try c.decodeIfPresent(VaultSpace.self, forKey: .space) ?? .personal
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        serviceID = try c.decodeIfPresent(UUID.self, forKey: .serviceID)
            ?? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(UUID.self, forKey: .integrationID)
        companyID = try c.decodeIfPresent(UUID.self, forKey: .companyID)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        environments = try c.decodeIfPresent([String].self, forKey: .environments)
            ?? legacy.decodeIfPresent(String.self, forKey: .environment).map { [$0] } ?? []
        loginKind = try c.decodeIfPresent(LoginKind.self, forKey: .loginKind) ?? .email
        login = try c.decodeIfPresent(String.self, forKey: .login) ?? ""
        authKind = try c.decodeIfPresent(AuthKind.self, forKey: .authKind) ?? .password
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        ssoEntryID = try c.decodeIfPresent(UUID.self, forKey: .ssoEntryID)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        preSteps = try c.decodeIfPresent([PreStep].self, forKey: .preSteps) ?? []
        isConnection = try c.decodeIfPresent(Bool.self, forKey: .isConnection) ?? false
        totp = try c.decodeIfPresent(TOTPConfig.self, forKey: .totp)
        ssh = try c.decodeIfPresent(SSHKey.self, forKey: .ssh)
        sshKeyEntryID = try c.decodeIfPresent(UUID.self, forKey: .sshKeyEntryID)
        certificate = try c.decodeIfPresent(CertificateBundle.self, forKey: .certificate)
        certificateEntryID = try c.decodeIfPresent(UUID.self, forKey: .certificateEntryID)
        passkeys = try c.decodeIfPresent([Passkey].self, forKey: .passkeys) ?? []
        reminder = try c.decodeIfPresent(Reminder.self, forKey: .reminder)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        fields = try c.decodeIfPresent([CustomField].self, forKey: .fields) ?? []
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        history = try c.decodeIfPresent([PasswordChange].self, forKey: .history) ?? []
        passwordUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .passwordUpdatedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// Первое окружение записи; присваивание заменяет весь список одним окружением (или очищает).
    public var environment: String? {
        get { environments.first }
        set { environments = newValue.map { [$0] } ?? [] }
    }


    public var address: EntryAddress? { EntryAddress.parse(url) }

    public var host: String? { address?.host }
}

/// Настройки, ослабление которых помогло бы украсть пароль. Живут внутри зашифрованного хранилища:
/// в UserDefaults их мог бы переписать любой процесс пользователя (`defaults write`).
public struct SecuritySettings: Codable, Equatable, Sendable {
    /// 0 — не блокировать по простою.
    public var autoLockMinutes = 5
    public var lockOnSleep = true
    public var lockOnScreenLock = true
    /// 0 — не очищать.
    public var clipboardClearSeconds = 30
    public var concealClipboard = true
    /// SSH-агент: хранилище отдаёт ключи `ssh`/`git` через сокет.
    public var sshAgentEnabled = false
    /// Спрашивать человека перед каждой подписью (иначе — только уведомление).
    public var sshAgentConfirm = true
    /// Расширение браузера (Chrome) может спрашивать у Ward пароли и passkey для открытых сайтов.
    public var browserEnabled = false
    public var commandAccessEnabled = false
    public var commandApprovalMinutes = 15
    /// Сколько последних резервных копий хранить, 0 — все. `nil` — хранилище старше этой настройки.
    public var backupsToKeep: Int?
    /// Папка зеркала копий (внешний диск), пусто — выключено. `nil` — хранилище старше этой настройки.
    public var mirrorBackupPath: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SecuritySettings()
        autoLockMinutes = try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? d.autoLockMinutes
        lockOnSleep = try c.decodeIfPresent(Bool.self, forKey: .lockOnSleep) ?? d.lockOnSleep
        lockOnScreenLock = try c.decodeIfPresent(Bool.self, forKey: .lockOnScreenLock) ?? d.lockOnScreenLock
        clipboardClearSeconds = try c.decodeIfPresent(Int.self, forKey: .clipboardClearSeconds) ?? d.clipboardClearSeconds
        concealClipboard = try c.decodeIfPresent(Bool.self, forKey: .concealClipboard) ?? d.concealClipboard
        sshAgentEnabled = try c.decodeIfPresent(Bool.self, forKey: .sshAgentEnabled) ?? d.sshAgentEnabled
        sshAgentConfirm = try c.decodeIfPresent(Bool.self, forKey: .sshAgentConfirm) ?? d.sshAgentConfirm
        browserEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserEnabled) ?? d.browserEnabled
        commandAccessEnabled = try c.decodeIfPresent(Bool.self, forKey: .commandAccessEnabled) ?? d.commandAccessEnabled
        commandApprovalMinutes = try c.decodeIfPresent(Int.self, forKey: .commandApprovalMinutes) ?? d.commandApprovalMinutes
        backupsToKeep = try c.decodeIfPresent(Int.self, forKey: .backupsToKeep)
        mirrorBackupPath = try c.decodeIfPresent(String.self, forKey: .mirrorBackupPath)
    }
}

/// Незаконченная правка записи: переживает блокировку и перезапуск Ward. Лежит внутри зашифрованного хранилища —
/// в ней пароли и ключи. В поиск, аудит, экспорт и копии-слияния не попадает.
public struct EntryDraft: Codable, Identifiable, Hashable, Sendable {
    /// Совпадает с id записи.
    public var id: UUID { entry.id }
    public var entry: Entry
    /// Запись ещё не сохранялась ни разу.
    public var isNew: Bool
    public var reminderOn: Bool
    public var reminder: Reminder
    public var savedAt: Date

    public init(entry: Entry, isNew: Bool, reminderOn: Bool, reminder: Reminder, savedAt: Date = Date()) {
        self.entry = entry
        self.isNew = isNew
        self.reminderOn = reminderOn
        self.reminder = reminder
        self.savedAt = savedAt
    }
}

public struct Vault: Codable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var companies: [Company]
    public var projects: [Project]
    public var services: [Service]
    public var entries: [Entry]
    public var drafts: [EntryDraft]
    /// `nil` — хранилище создано до переноса настроек внутрь; тогда они берутся из старых UserDefaults.
    public var security: SecuritySettings?

    public init(companies: [Company] = [], projects: [Project] = [], services: [Service] = [], entries: [Entry] = []) {
        format = Self.currentFormat
        self.companies = companies
        self.projects = projects
        self.services = services
        self.entries = entries
        drafts = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        companies = try c.decodeIfPresent([Company].self, forKey: .companies) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        services = try c.decodeIfPresent([Service].self, forKey: .services)
            ?? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent([Service].self, forKey: .integrations) ?? []
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        drafts = try c.decodeIfPresent([EntryDraft].self, forKey: .drafts) ?? []
        security = try c.decodeIfPresent(SecuritySettings.self, forKey: .security)
    }
}
