import AppKit
import SwiftUI
import WardCore

struct Avatar: View {
    let title: String
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(Theme.tile(for: title))
            .frame(width: size, height: size)
            .overlay(
                Text(String(title.first ?? "•").uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF4F4F5))
            )
    }
}

struct EnvBadge: View {
    let env: String

    var body: some View {
        let colors = Theme.envColors(env)
        Text(env.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(colors.bg, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}

struct Chip: View {
    let text: String
    var height: CGFloat = 22

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textChip)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(Theme.chip, in: Capsule())
            .fixedSize()
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textChip)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.14)))
    }
}

struct CountdownRing: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: size * 0.14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

struct TOTPCodeView: View {
    let config: TOTPConfig
    var fontSize: CGFloat = 17
    var ringSize: CGFloat = 18
    var showsSeconds = false

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), by: 1)) { context in
            let left = TOTP.secondsRemaining(period: config.period, at: context.date)
            HStack(spacing: 10) {
                Text(TOTP.formatted(TOTP.code(config, at: context.date))).privacySensitive()
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .tracking(fontSize * 0.04)
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                CountdownRing(progress: Double(left) / Double(max(config.period, 1)),
                              color: left <= 5 ? Theme.danger : Theme.accent, size: ringSize)
                if showsSeconds {
                    Text("обновится через \(left) с")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .fixedSize()
                }
            }
        }
    }
}

struct StrengthBar: View {
    let score: Int
    var width: CGFloat = 120

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < score ? Theme.strengthColor(score) : Color.white.opacity(0.1))
                    .frame(height: 4)
            }
        }
        .frame(width: width)
    }
}

struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 34
    var iconSize: CGFloat = 15
    var tint: Color = Theme.text2
    /// `false` — кнопка не получает фокус клавиатуры (иначе первая кнопка листа встречает синей рамкой).
    var focusable = true
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(hovering ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(focusable)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
        .pointingHandCursor(isEnabled)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Подсветка под курсором для строк, чипов и карточек без своей кнопочной рамки.
struct HoverBackground: ViewModifier {
    var color: Color = Theme.rowHover
    var cornerRadius: CGFloat = 7
    var enabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(enabled && hovering ? color : .clear, in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovering = $0 }
            .pointingHandCursor()
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Курсор-ладонь над кликабельным. Курсоры в AppKit — стек: каждое «вошёл» кладёт ладонь, «вышел» снимает,
/// поэтому следим, чтобы снятий было столько же, сколько положено, в том числе если элемент исчез под курсором.
struct PointingHandCursor: ViewModifier {
    var enabled = true
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                let want = inside && enabled
                guard want != pushed else { return }
                pushed = want
                if want { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onChange(of: enabled) {
                if !enabled && pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed { NSCursor.pop() }
                pushed = false
            }
    }
}

/// Текстовые ссылки («Добавить 2FA», адрес сайта): под курсором чуть светлеют.
struct HoverLink: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.12 : 0)
            .onHover { hovering = $0 }
            .pointingHandCursor()
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverLink() -> some View { modifier(HoverLink()) }
    func pointingHandCursor(_ enabled: Bool = true) -> some View { modifier(PointingHandCursor(enabled: enabled)) }

    func hoverBackground(_ color: Color = Theme.rowHover, cornerRadius: CGFloat = 7, enabled: Bool = true) -> some View {
        modifier(HoverBackground(color: color, cornerRadius: cornerRadius, enabled: enabled))
    }
}

struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        AccentButtonBody(configuration: configuration, height: height)
    }

    private struct AccentButtonBody: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: height)
                .background((hovering && isEnabled ? Theme.accentHover : Theme.accent).opacity(configuration.isPressed ? 0.8 : 1),
                            in: RoundedRectangle(cornerRadius: 8))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .pointingHandCursor(isEnabled)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, height: height)
    }

    private struct SecondaryButtonBody: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background((hovering && isEnabled ? Theme.cardHover : Theme.card).opacity(configuration.isPressed ? 0.7 : 1),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering && isEnabled ? Color.white.opacity(0.2) : Theme.border))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .pointingHandCursor(isEnabled)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DangerButtonBody(configuration: configuration)
    }

    private struct DangerButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onDanger)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background((hovering ? Theme.dangerHover : Theme.danger).opacity(configuration.isPressed ? 0.8 : 1),
                            in: RoundedRectangle(cornerRadius: 7))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .pointingHandCursor(isEnabled)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Поле ввода Ward. Системная синяя рамка фокуса в окнах отключена — поле под курсором ввода
/// обводится своим цветом, чтобы было видно, куда печатаешь.
struct FieldBackground: ViewModifier {
    var focused = false
    var height: CGFloat? = 38
    /// Фокус экрана, который сам ставит курсор в поле (разблокировка). Вторая привязка на том же поле
    /// перебивала бы первую — поэтому своя используется, только когда внешней нет.
    var focus: FocusState<Bool>.Binding?
    @FocusState private var ownFocus: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        let active = focused || (focus?.wrappedValue ?? ownFocus)
        content
            .textFieldStyle(.plain)
            .focused(focus ?? $ownFocus)
            .font(.system(size: 14))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(active ? Theme.accent : (hovering ? Color.white.opacity(0.2) : Theme.border),
                              lineWidth: active ? 1.5 : 1))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

extension View {
    func wardField(focused: Bool = false, focus: FocusState<Bool>.Binding? = nil, height: CGFloat? = 38) -> some View {
        modifier(FieldBackground(focused: focused, height: height, focus: focus))
    }

    func cardStyle() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}

struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2)
    }
}

/// Маленький переключатель вариантов, как «почте / телефону / логину» в макете.
struct MiniSegments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(selection == value ? Theme.text : Theme.text2)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(selection == value ? Theme.segmentOn : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .hoverBackground(cornerRadius: 5, enabled: selection != value)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct CheckToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSoft)
        }
        .toggleStyle(.checkbox)
        .tint(Theme.accent)
    }
}

extension Entry {
    var strength: PasswordStrength { PasswordStrength.evaluate(secret) }

    var authSummary: String {
        switch authKind {
        case .token:
            return "API-токен"
        case .sso:
            return "Вход через аккаунт"
        case .password:
            var parts: [String] = []
            if !login.isEmpty { parts.append(Format.loginLabel(loginKind)) }
            if secret.isEmpty && !hasSSH && !hasCertificate && totp == nil && !fields.isEmpty {
                return Format.plural(fields.count, "поле", "поля", "полей")
            }
            if !secret.isEmpty || (!hasSSH && !hasCertificate) { parts.append("пароль") }
            if hasSSH { parts.append("SSH-ключ") }
            if hasCertificate { parts.append("сертификат") }
            if totp != nil { parts.append("2FA") }
            let text = parts.joined(separator: " + ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    var hasSSH: Bool { ssh != nil || sshKeyEntryID != nil }
    var hasCertificate: Bool { certificate != nil || certificateEntryID != nil }

    var maskedToken: String {
        guard secret.count > 8 else { return String(repeating: "•", count: 8) }
        var prefix = ""
        if let underscore = secret.lastIndex(of: "_"),
           secret.distance(from: secret.startIndex, to: underscore) < 12 {
            prefix = String(secret[...underscore])
        }
        return prefix + "••••••••" + secret.suffix(4)
    }

    /// «https://admin.example.com/» → «admin.example.com», порт и путь остаются.
    var displayURL: String {
        var text = url.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Только веб-адреса: `file://`, `smb://` и схемы приложений из чужого CSV запускали бы программы и монтировали диски,
    /// а «10.0.0.5:22» — это SSH, а не сайт.
    var openURL: URL? {
        guard let address, let url = address.webURL(original: self.url),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

/// Чип-переключатель: окружения записи, фильтры.
struct ToggleChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? Theme.onAccent : Theme.textChip)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(isOn ? (hovering ? Theme.accentHover : Theme.accent) : (hovering ? Theme.chipHover : Theme.chip), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
