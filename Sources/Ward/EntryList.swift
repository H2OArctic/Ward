import SwiftUI
import WardCore

extension Navigator {
    @MainActor
    func entries(in store: VaultStore) -> [Entry] {
        let reuse = store.reuseCounts()
        var list: [Entry]
        switch section {
        case .trash:
            list = store.trashed.filter { inScope($0, store: store) }
        default:
            list = store.active.filter { inScope($0, store: store) }
        }
        switch section {
        case .due: list = list.filter { $0.reminder != nil }
        case .favorites: list = list.filter(\.favorite)
        case .withCode: list = list.filter { $0.totp != nil }
        case .recent: list = list.filter { $0.lastUsedAt != nil }
        case .project(let id): list = list.filter { $0.projectID == id }
        case .service(let id): list = list.filter { $0.serviceID == id }
        case .shared: list = list.filter { $0.projectID == nil && $0.serviceID == nil }
        case .audit: list = list.filter { store.hasIssues($0, reuse: reuse) }
        default: break
        }

        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            return EntrySearch.search(list, query: query) { store.searchContext($0) }
        }
        switch section {
        case .recent:
            return Array(list.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }.prefix(30))
        case .due:
            return list.sorted { ($0.reminder?.isDue() == true ? 0 : 1, $0.reminder?.dayFrom ?? 0) < ($1.reminder?.isDue() == true ? 0 : 1, $1.reminder?.dayFrom ?? 0) }
        default:
            break
        }
        switch sort {
        case .usage:
            return list.sorted {
                if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .title:
            return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .updated:
            return list.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

struct EntryListColumn: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @State private var confirmEmptyTrash = false
    @State private var confirmBreachCheck = false
    @State private var breachStatus: String?
    @State private var checkingBreaches = false

    var body: some View {
        let items = nav.entries(in: store)
        let reuse = store.reuseCounts()
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.text3)
                    TextField("Поиск", text: $nav.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))

                Button { nav.newEntry() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Новая запись (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if nav.section == .audit { breachPanel }

            HStack {
                Text(Format.plural(items.count, "запись", "записи", "записей"))
                Spacer()
                if nav.section == .trash, !items.isEmpty {
                    Button("Очистить корзину") { confirmEmptyTrash = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.danger)
                        .confirmationDialog("Удалить навсегда " + Format.plural(store.trashed.count, "запись", "записи", "записей") + "?",
                                            isPresented: $confirmEmptyTrash) {
                            Button("Удалить", role: .destructive) { Task { await store.emptyTrash() } }
                        } message: {
                            let trashed = Set(store.trashed.map(\.id))
                            let users = store.active.filter {
                                ($0.sshKeyEntryID.map(trashed.contains) ?? false) || ($0.certificateEntryID.map(trashed.contains) ?? false)
                            }
                            Text((users.isEmpty ? "" : "Ключ или сертификат из корзины используют: "
                                  + users.map(\.title).joined(separator: ", ") + " — у них он пропадёт. ")
                                 + "Корзина очищается целиком, в обоих пространствах. В автоматических копиях записи останутся, пока их не вытеснят новые.")
                        }
                } else {
                    Menu {
                        ForEach(Navigator.SortMode.allCases, id: \.self) { mode in
                            Button(mode.title) { nav.sort = mode }
                        }
                    } label: {
                        Text(nav.sort.title + " ▾")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { entry in
                        EntryRow(entry: entry, selected: nav.selection == entry.id,
                                 flagged: store.hasIssues(entry, reuse: reuse)) {
                            nav.selection = entry.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .overlay {
                if items.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        }
        .background(Theme.list)
        .onAppear { ensureSelection(items) }
        .onChange(of: items.map(\.id)) { ensureSelection(items) }
    }

    private var breachPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirmBreachCheck = true
            } label: {
                HStack(spacing: 8) {
                    if checkingBreaches { ProgressView().controlSize(.small) } else { Image(systemName: "shield.lefthalf.filled") }
                    Text(checkingBreaches ? "Проверяю…" : "Проверить пароли по базе утечек")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle(height: 32))
            .disabled(checkingBreaches)
            Text(breachStatus ?? store.breachCheckedAt.map { "Проверено " + Format.dayTime($0) } ?? "Have I Been Pwned: наружу уходят только 5 символов хеша")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .confirmationDialog("Проверить пароли по базе утечек?", isPresented: $confirmBreachCheck) {
            Button("Проверить") { runBreachCheck() }
        } message: {
            Text("Ward отправит в Have I Been Pwned только первые 5 символов SHA-1 каждого пароля — сами пароли и их полные хеши не покидают Mac. Нужен интернет.")
        }
    }

    private func runBreachCheck() {
        checkingBreaches = true
        breachStatus = nil
        Task {
            do {
                let result = try await store.checkBreaches()
                breachStatus = result.found == 0
                    ? "Утечек нет — проверено " + Format.plural(result.checked, "пароль", "пароля", "паролей")
                    : "В утечках: " + Format.plural(result.found, "пароль", "пароля", "паролей") + " — смените их"
            } catch {
                breachStatus = "Не удалось проверить: \(error.localizedDescription)"
            }
            checkingBreaches = false
        }
    }

    private var emptyText: String {
        if !nav.search.isEmpty { return "Ничего не найдено" }
        switch nav.section {
        case .due: return "Пока нет повторяющихся дел.\nВключите «Напоминание» в записи — например, «передать показания с 20 по 25 число»."
        case .audit: return "Слабых паролей, ключей и истекающих сертификатов нет"
        case .trash: return "Корзина пуста"
        case .favorites: return "Отметьте запись звёздочкой"
        default: return "Записей нет — нажмите «+»"
        }
    }

    private func ensureSelection(_ items: [Entry]) {
        if let selection = nav.selection, items.contains(where: { $0.id == selection }) { return }
        nav.selection = items.first?.id
    }
}

private struct EntryRow: View {
    let entry: Entry
    let selected: Bool
    let flagged: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Avatar(title: entry.title, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        ForEach(entry.environments, id: \.self) { EnvBadge(env: $0) }
                    }
                    Text(subtitle).privacySensitive()
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if entry.reminder?.isDue() == true {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 13)).foregroundStyle(Theme.accent)
                        .help(entry.reminder?.task ?? "")
                }
                if entry.totp != nil {
                    Image(systemName: "lock.shield").font(.system(size: 13)).foregroundStyle(Theme.text2)
                        .help("Есть 2FA")
                }
                if flagged {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Theme.danger)
                        .help("Слабый пароль, ключ или истекающий сертификат")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 58)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
            .hoverBackground(cornerRadius: 9, enabled: !selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if entry.reminder?.isDue() == true, let task = entry.reminder?.task { return task }
        return entry.login.isEmpty ? (entry.host ?? entry.authSummary) : entry.login
    }
}
