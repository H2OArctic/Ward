import SwiftUI
import WardCore

struct UnlockView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var prefs: Prefs
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            LockBadge()
            VStack(spacing: 6) {
                Text("Хранилище заблокировано")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Введите мастер-пароль, чтобы открыть записи")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text2)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SecureField("Мастер-пароль", text: $password)
                        .onSubmit(submit)
                        .wardField(focus: $focused, height: 44)
                    Button(action: submit) {
                        Group {
                            if busy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.right").font(.system(size: 17, weight: .bold))
                            }
                        }
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                        .hoverBackground(Color.white.opacity(0.15), cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                    // Курсор ввода — в поле пароля, а не на этой кнопке.
                    .focusable(false)
                    .accessibilityLabel("Разблокировать")
                    .disabled(busy)
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
            }
            .frame(width: 340)
            if let unavailable = store.unavailableReason {
                VStack(spacing: 10) {
                    Text("Не удалось прочитать хранилище: \(unavailable)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(width: 420)
                    Button("Повторить") {
                        error = nil
                        Task { await store.reload() }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                }
            } else if let reason {
                Text(reason).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
        }
        .padding(40)
        .defaultFocus($focused, true)
        .onAppear {
            focused = true
            // Окно становится главным чуть позже появления — повторяем, когда оно уже может принять фокус.
            DispatchQueue.main.async { focused = true }
        }
    }

    private var reason: String? {
        switch store.lockReason {
        case .idle: return "Заблокировано автоматически после \(prefs.autoLockMinutes) мин простоя"
        case .sleep: return "Заблокировано при переходе в сон"
        case .screenLock: return "Заблокировано вместе с экраном"
        case .manual: return "Заблокировано вручную"
        case .launch: return nil
        }
    }

    private func submit() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await store.unlock(password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct SetupView: View {
    @EnvironmentObject private var store: VaultStore
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 24) {
            LockBadge()
            VStack(spacing: 6) {
                Text("Создайте мастер-пароль")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Им шифруется всё хранилище. Записи лежат в связке ключей этого Mac и никуда не уходят.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .frame(width: 420)
            }
            VStack(alignment: .leading, spacing: 10) {
                SecureField("Мастер-пароль", text: $password).wardField(height: 44)
                let strength = PasswordStrength.evaluate(password)
                HStack(spacing: 10) {
                    StrengthBar(score: strength.score, width: 96)
                    Text(password.isEmpty ? "Минимум \(MasterPasswordPolicy.minLength) символов" : Theme.strengthLabel(strength.score))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                }
                SecureField("Ещё раз", text: $confirm)
                    .onSubmit(submit)
                    .wardField(height: 44)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.accent)
                    Text("Восстановить забытый мастер-пароль нельзя — ни нам, ни Apple.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSoft)
                }
                .padding(.top, 4)
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                Button(action: submit) {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Создать хранилище")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle(height: 40))
                .disabled(busy)
                .padding(.top, 6)
            }
            .frame(width: 340)
        }
        .padding(40)
    }

    private func submit() {
        guard !busy else { return }
        if let problem = MasterPasswordPolicy.problem(password) { error = problem; return }
        guard password == confirm else { error = "Пароли не совпадают"; return }
        busy = true
        error = nil
        Task {
            do {
                try await store.setup(password: password)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct LockBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.accent.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.3)))
            .overlay(Image(systemName: "lock").font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.accent))
            .frame(width: 64, height: 64)
    }
}
