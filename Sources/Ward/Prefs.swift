import AppKit
import Carbon.HIToolbox
import WardCore

struct HotkeySpec: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var label: String

    static let standard = HotkeySpec(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), label: "⌥ Пробел")

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func label(flags: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        let key: String
        switch Int(keyCode) {
        case kVK_Space: key = "Пробел"
        case kVK_Return: key = "⏎"
        case kVK_Tab: key = "⇥"
        case kVK_Escape: key = "Esc"
        case kVK_LeftArrow: key = "←"
        case kVK_RightArrow: key = "→"
        case kVK_UpArrow: key = "↑"
        case kVK_DownArrow: key = "↓"
        default: key = (characters ?? "").uppercased()
        }
        return symbols + " " + key
    }
}

enum EnterAction: String, CaseIterable {
    case password, code, open

    var title: String {
        switch self {
        case .password: return "копирует пароль"
        case .code: return "копирует код 2FA"
        case .open: return "открывает запись"
        }
    }
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    private let defaults = UserDefaults.standard

    private enum K {
        static let autoLockMinutes = "autoLockMinutes"
        static let lockOnSleep = "lockOnSleep"
        static let lockOnScreenLock = "lockOnScreenLock"
        static let hotkey = "hotkey"
        static let enterAction = "enterAction"
        static let clipboardClearSeconds = "clipboardClearSeconds"
        static let concealClipboard = "concealClipboard"
        static let backupsToKeep = "backupsToKeep"
        static let generator = "generator"
        static let copyCodeAfterFill = "copyCodeAfterFill"
        static let mirrorBackupPath = "mirrorBackupPath"
        static let hideData = "hideData"
    }

    // Настройки безопасности хранятся в зашифрованном хранилище (см. `SecuritySettings`), здесь — только их копия.
    /// 0 — не блокировать по простою.
    @Published var autoLockMinutes: Int { didSet { securityChanged() } }
    @Published var lockOnSleep: Bool { didSet { securityChanged() } }
    @Published var lockOnScreenLock: Bool { didSet { securityChanged() } }
    @Published var hotkey: HotkeySpec { didSet { store(hotkey, K.hotkey) } }
    @Published var enterAction: EnterAction { didSet { defaults.set(enterAction.rawValue, forKey: K.enterAction) } }
    @Published var clipboardClearSeconds: Int { didSet { securityChanged() } }
    @Published var concealClipboard: Bool { didSet { securityChanged() } }
    @Published var sshAgentEnabled = false { didSet { securityChanged() } }
    @Published var sshAgentConfirm = true { didSet { securityChanged() } }
    @Published var browserEnabled = false { didSet { securityChanged() } }
    @Published var commandAccessEnabled = false { didSet { securityChanged() } }
    @Published var commandApprovalMinutes = 15 { didSet { securityChanged() } }
    /// 0 — хранить все копии.
    @Published var backupsToKeep: Int { didSet { securityChanged() } }
    @Published var generator: GeneratorOptions { didSet { store(generator, K.generator) } }
    @Published var copyCodeAfterFill: Bool { didSet { defaults.set(copyCodeAfterFill, forKey: K.copyCodeAfterFill) } }
    /// Скрывать логины, адреса, коды и заметки от тех, кто рядом: остаются названия и кнопки копирования.
    /// Не настройка безопасности (подсмотреть пароль ослаблением нельзя), поэтому в UserDefaults.
    @Published var hideData: Bool { didSet { defaults.set(hideData, forKey: K.hideData) } }
    /// Пусто — зеркало копий выключено.
    @Published var mirrorBackupPath: String { didSet { securityChanged() } }

    var onSecurityChange: ((SecuritySettings) -> Void)?
    private var applying = false

    private init() {
        let secure = SecuritySettings()
        defaults.register(defaults: [
            K.autoLockMinutes: secure.autoLockMinutes,
            K.lockOnSleep: secure.lockOnSleep,
            K.lockOnScreenLock: secure.lockOnScreenLock,
            K.enterAction: EnterAction.password.rawValue,
            K.clipboardClearSeconds: secure.clipboardClearSeconds,
            K.concealClipboard: secure.concealClipboard,
            K.backupsToKeep: 20,
            K.copyCodeAfterFill: true,
        ])
        autoLockMinutes = defaults.integer(forKey: K.autoLockMinutes)
        lockOnSleep = defaults.bool(forKey: K.lockOnSleep)
        lockOnScreenLock = defaults.bool(forKey: K.lockOnScreenLock)
        enterAction = EnterAction(rawValue: defaults.string(forKey: K.enterAction) ?? "") ?? .password
        clipboardClearSeconds = defaults.integer(forKey: K.clipboardClearSeconds)
        concealClipboard = defaults.bool(forKey: K.concealClipboard)
        backupsToKeep = defaults.integer(forKey: K.backupsToKeep)
        copyCodeAfterFill = defaults.bool(forKey: K.copyCodeAfterFill)
        mirrorBackupPath = defaults.string(forKey: K.mirrorBackupPath) ?? ""
        hideData = defaults.bool(forKey: K.hideData)
        hotkey = Self.load(HotkeySpec.self, defaults.data(forKey: K.hotkey)) ?? .standard
        generator = Self.load(GeneratorOptions.self, defaults.data(forKey: K.generator)) ?? GeneratorOptions()
    }

    var security: SecuritySettings {
        var s = SecuritySettings()
        s.autoLockMinutes = autoLockMinutes
        s.lockOnSleep = lockOnSleep
        s.lockOnScreenLock = lockOnScreenLock
        s.clipboardClearSeconds = clipboardClearSeconds
        s.concealClipboard = concealClipboard
        s.sshAgentEnabled = sshAgentEnabled
        s.sshAgentConfirm = sshAgentConfirm
        s.browserEnabled = browserEnabled
        s.commandAccessEnabled = commandAccessEnabled
        s.commandApprovalMinutes = commandApprovalMinutes
        s.backupsToKeep = backupsToKeep
        s.mirrorBackupPath = mirrorBackupPath
        return s
    }

    func apply(_ settings: SecuritySettings) {
        applying = true
        defer { applying = false }
        autoLockMinutes = settings.autoLockMinutes
        lockOnSleep = settings.lockOnSleep
        lockOnScreenLock = settings.lockOnScreenLock
        clipboardClearSeconds = settings.clipboardClearSeconds
        concealClipboard = settings.concealClipboard
        sshAgentEnabled = settings.sshAgentEnabled
        sshAgentConfirm = settings.sshAgentConfirm
        browserEnabled = settings.browserEnabled
        commandAccessEnabled = settings.commandAccessEnabled
        commandApprovalMinutes = settings.commandApprovalMinutes
        // Старое хранилище без этих настроек — остаются прежние значения, их затем перенесут внутрь.
        if let keep = settings.backupsToKeep { backupsToKeep = keep }
        if let path = settings.mirrorBackupPath { mirrorBackupPath = path }
    }

    /// После переноса в хранилище старые значения в UserDefaults больше не читаются.
    func forgetLegacySecurity() {
        for key in [K.autoLockMinutes, K.lockOnSleep, K.lockOnScreenLock, K.clipboardClearSeconds, K.concealClipboard,
                    K.backupsToKeep, K.mirrorBackupPath] {
            defaults.removeObject(forKey: key)
        }
    }

    private func securityChanged() {
        guard !applying else { return }
        onSecurityChange?(security)
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
