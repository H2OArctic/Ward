import SwiftUI
import WardCore

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

enum Theme {
    static let window = Color(hex: 0x222429)
    static let sidebar = Color(hex: 0x191A1E)
    static let list = Color(hex: 0x1E2025)
    static let card = Color(hex: 0x2A2D33)
    static let field = Color(hex: 0x1B1D21)
    static let sheet = Color(hex: 0x24262B)
    static let sheetFooter = Color(hex: 0x202226)
    static let panel = Color(hex: 0x202227)
    static let panelFooter = Color(hex: 0x1C1E22)
    static let selection = Color(hex: 0x2E3139)
    static let sidebarSelection = Color(hex: 0x2C2F36)
    static let chip = Color(hex: 0x34373E)
    static let control = Color(hex: 0x2F3238)
    static let segment = Color(hex: 0x25272D)
    static let segmentOn = Color(hex: 0x3A3D45)
    // Под курсором: на тон светлее своего фона.
    static let rowHover = Color.white.opacity(0.045)
    static let cardHover = Color(hex: 0x30333A)
    static let chipHover = Color(hex: 0x3F434B)
    static let accentHover = Color(hex: 0xF6BE6E)
    static let dangerHover = Color(hex: 0xFF8C70)

    static let text = Color(hex: 0xECEDEF)
    static let textSoft = Color(hex: 0xC9CBD1)
    static let textChip = Color(hex: 0xD4D6DB)
    static let text2 = Color(hex: 0x9A9EA8)
    static let text3 = Color(hex: 0x8C919B)

    static let accent = Color(hex: 0xF2B155)
    static let onAccent = Color(hex: 0x1B1400)
    static let danger = Color(hex: 0xFF7A59)
    static let onDanger = Color(hex: 0x1E0B05)
    static let dangerText = Color(hex: 0xFFC2B2)
    static let success = Color(hex: 0x7FD6A4)

    static let hairline = Color.white.opacity(0.06)
    static let border = Color.white.opacity(0.12)

    private static let tiles: [UInt32] = [0x343A46, 0x6B4A1E, 0x5A2226, 0x3D2F5C, 0x1F3F5C, 0x4A2E52, 0x23403A, 0x2A3550]

    /// Цвет плитки стабилен между запусками: `hashValue` в Swift рандомизирован, поэтому считаем сами.
    static func tile(for title: String) -> Color {
        let sum = title.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hex: tiles[abs(sum) % tiles.count])
    }

    static func strengthColor(_ score: Int) -> Color {
        score <= 1 ? danger : score == 4 ? success : accent
    }

    static func strengthLabel(_ score: Int) -> String {
        ["—", "Слабый", "Средний", "Хороший", "Надёжный"][min(max(score, 0), 4)]
    }

    static func envColors(_ env: String) -> (bg: Color, fg: Color) {
        let name = env.lowercased()
        if name.contains("prod") || name.contains("прод") {
            return (Color(hex: 0xFF7A59, opacity: 0.18), Color(hex: 0xFFA88F))
        }
        if ["stag", "test", "dev", "qa", "стейдж", "тест"].contains(where: name.contains) {
            return (Color(hex: 0x6FA8FF, opacity: 0.16), Color(hex: 0x9CC2FF))
        }
        return (chip, textChip)
    }

    static func isProduction(_ env: String?) -> Bool {
        guard let env = env?.lowercased() else { return false }
        return env.contains("prod") || env.contains("прод")
    }
}

enum Format {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"
        return f
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func dayTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "сегодня, " + date.formatted(.dateTime.hour().minute())
        }
        return dayTimeFormatter.string(from: date)
    }

    /// 1 запись, 2 записи, 5 записей.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "\(n) \(one)" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) \(few)" }
        return "\(n) \(many)"
    }

    static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func loginLabel(_ kind: LoginKind) -> String {
        switch kind {
        case .email: return "Почта"
        case .phone: return "Телефон"
        case .username: return "Логин"
        }
    }

    static func reminderWindow(_ r: Reminder) -> String {
        r.dayFrom == r.dayTo ? "\(r.dayFrom) числа" : "с \(r.dayFrom) по \(r.dayTo) число"
    }
}
