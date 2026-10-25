import AppKit
import SwiftUI
import WardCore

/// Проект: путь до него, подпроекты, сервисы и колонки окружений с карточками доступов.
struct ProjectPane: View {
    let project: Project
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @State private var editingProject: Project?
    @State private var editingService: Service?

    var body: some View {
        let all = store.active.filter { $0.projectID == project.id }
        let children = store.children(of: project.id)
        let services = store.services(of: project.id)
        let companyServices = store.services(in: project.space, company: project.companyID)
        let unlinked = companyServices.filter { !$0.projectIDs.contains(project.id) }

        VStack(spacing: 0) {
            PaneHeader(title: project.name,
                       breadcrumbs: store.ancestors(of: project.id).map { ancestor in
                           (ancestor.name, { nav.section = .project(ancestor.id) })
                       },
                       subtitle: [Format.plural(project.environments.count, "окружение", "окружения", "окружений"),
                                  Format.plural(all.count, "доступ", "доступа", "доступов")].joined(separator: " · "),
                       searchPrompt: "Поиск в проекте",
                       onConfigure: { editingProject = project }) {
                Button { nav.newEntry(project: project, environment: project.environments.first) } label: {
                    Label("Доступ", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle(height: 32))
            }

            VStack(alignment: .leading, spacing: 10) {
                LinkStrip(title: "Подпроекты", icon: "folder") {
                    ForEach(children) { child in
                        LinkChip(title: child.name, count: store.active.filter { $0.projectID == child.id }.count) {
                            nav.section = .project(child.id)
                        }
                    }
                    AddChip(label: "Подпроект") {
                        editingProject = Project(name: "", space: project.space, environments: project.environments,
                                                 parentID: project.id, companyID: project.companyID)
                    }
                }
                LinkStrip(title: "Сервисы", icon: "shippingbox") {
                    ForEach(services) { service in
                        let own = store.active.filter { $0.serviceID == service.id && $0.projectID == project.id }.count
                        LinkChip(title: service.name, count: own > 0 ? own : nil) {
                            nav.section = .service(service.id)
                        }
                    }
                    Menu {
                        if !companyServices.isEmpty {
                            Section("Своя учётка проекта") {
                                ForEach(companyServices) { service in
                                    Button(service.name) { nav.newEntry(project: project, service: service) }
                                }
                            }
                        }
                        if !unlinked.isEmpty {
                            Section("Пользоваться общими учётками") {
                                ForEach(unlinked) { service in
                                    Button(service.name) {
                                        Task { await store.linkService(service.id, to: project.id) }
                                    }
                                }
                            }
                        }
                        Button("Новый сервис…") {
                            editingService = Service(name: "", space: project.space, companyID: project.companyID,
                                                     projectIDs: [project.id])
                        }
                    } label: {
                        Label("Добавить", systemImage: "plus").font(.system(size: 12))
                    }
                    .menuStyle(.button)
                    .buttonStyle(ChipButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 18)

            EnvironmentBoard(environments: project.environments, entries: filtered(all)) { env in
                nav.newEntry(project: project, environment: env)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .sheet(item: $editingProject) { project in
            ProjectEditor(project: project).environmentObject(store).environmentObject(nav)
        }
        .sheet(item: $editingService) { service in
            ServiceEditor(service: service).environmentObject(store).environmentObject(nav)
        }
    }

    private func filtered(_ entries: [Entry]) -> [Entry] {
        let query = nav.search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? entries : EntrySearch.search(entries, query: query)
    }
}

/// Сервис компании: общие учётки по его окружениям и учётки проектов — каждая у своего проекта.
struct ServicePane: View {
    let service: Service
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @State private var editing: Service?

    var body: some View {
        let all = store.active.filter { $0.serviceID == service.id }
        let query = nav.search.trimmingCharacters(in: .whitespaces)
        let entries = query.isEmpty ? all : EntrySearch.search(all, query: query)
        let shared = entries.filter { $0.projectID == nil }
        let byProject = Dictionary(grouping: entries.filter { $0.projectID != nil }) { $0.projectID! }
        let projectTree = store.tree(in: service.space, company: service.companyID)
        let withAccounts = projectTree.filter { byProject[$0.project.id] != nil }

        VStack(spacing: 0) {
            PaneHeader(title: service.name,
                       breadcrumbs: [],
                       subtitle: (["Сервис", service.url].filter { !$0.isEmpty }
                                  + [Format.plural(all.count, "учётка", "учётки", "учёток")]).joined(separator: " · "),
                       searchPrompt: "Поиск в сервисе",
                       onConfigure: { editing = service }) {
                Menu {
                    Button("Общая учётка") { nav.newEntry(service: service, environment: service.environments.first) }
                    if !projectTree.isEmpty {
                        Section("Учётка проекта") {
                            ForEach(projectTree, id: \.project.id) { item in
                                Button(store.path(of: item.project.id)) { nav.newEntry(project: item.project, service: service) }
                            }
                        }
                    }
                } label: {
                    Label("Учётка", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(AccentButtonStyle(height: 32))
                .menuIndicator(.hidden)
                .fixedSize()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LinkStrip(title: "Пользуются", icon: "folder") {
                        ForEach(service.projectIDs, id: \.self) { id in
                            if store.project(id) != nil {
                                LinkChip(title: store.path(of: id), count: nil) { nav.section = .project(id) }
                            }
                        }
                        if service.projectIDs.isEmpty {
                            Text("никто — отметьте проекты в настройках сервиса")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                    }

                    SectionTitle(title: "Общие учётки", detail: "учётки компании, не одного проекта")
                    EnvironmentBoard(environments: service.environments, entries: shared, padded: false, scrolls: false) { env in
                        nav.newEntry(service: service, environment: env)
                    }

                    ForEach(withAccounts, id: \.project.id) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button { nav.section = .project(item.project.id) } label: {
                                    SectionTitle(title: store.path(of: item.project.id), detail: "учётки проекта")
                                }
                                .buttonStyle(.plain)
                                .help("Открыть проект")
                                Spacer()
                                IconButton(systemName: "plus", label: "Ещё учётка проекта", size: 26, iconSize: 12) {
                                    nav.newEntry(project: item.project, service: service)
                                }
                            }
                            CardGrid(entries: byProject[item.project.id] ?? [])
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .sheet(item: $editing) { service in
            ServiceEditor(service: service).environmentObject(store).environmentObject(nav)
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
    }
}

/// Карточки учёток в две колонки, с окружением на каждой.
private struct CardGrid: View {
    let entries: [Entry]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), spacing: 20, alignment: .top)],
                  alignment: .leading, spacing: 10) {
            ForEach(entries) { entry in ProjectCard(entry: entry, showsEnvironment: true) }
        }
    }
}

/// Заголовок страницы проекта или сервиса: путь, название, поиск, настройка и главное действие.
private struct PaneHeader<Action: View>: View {
    let title: String
    let breadcrumbs: [(String, () -> Void)]
    let subtitle: String
    let searchPrompt: String
    let onConfigure: () -> Void
    @ViewBuilder let action: Action
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Avatar(title: title, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                if !breadcrumbs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { _, crumb in
                            Button(crumb.0, action: crumb.1).buttonStyle(.plain).foregroundStyle(Theme.accent).hoverLink()
                            Text("›").foregroundStyle(Theme.text3)
                        }
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }
                Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.text3)
                TextField(searchPrompt, text: $nav.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            IconButton(systemName: "slider.horizontal.3", label: "Настроить", size: 32, action: onConfigure)
            action
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 16)
    }
}

/// Строка «Подпроекты: [API] [Админка] [+]».
private struct LinkStrip<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .frame(width: 130, alignment: .leading)
            ScrollView(.horizontal) {
                HStack(spacing: 6) { content }
            }
            .scrollIndicators(.never)
        }
        .frame(height: 30)
    }
}

private struct LinkChip: View {
    let title: String
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                if let count { Text("\(count)").foregroundStyle(Theme.text3) }
            }
            .font(.system(size: 12))
        }
        .buttonStyle(ChipButtonStyle())
    }
}

private struct AddChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(label, systemImage: "plus").font(.system(size: 12)) }
            .buttonStyle(ChipButtonStyle())
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Theme.text : Theme.textSoft)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background((hovering ? Theme.cardHover : Theme.card).opacity(configuration.isPressed ? 0.7 : 1),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hovering ? Theme.border : Theme.hairline))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointingHandCursor()
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Колонки окружений с карточками доступов; записи с неизвестным окружением — в колонке «Без окружения».
private struct EnvironmentBoard: View {
    let environments: [String]
    let entries: [Entry]
    /// Свои поля и прокрутка колонок — когда доска занимает всю страницу; внутри страницы сервиса — без них.
    var padded = true
    var scrolls = true
    let onAdd: (String) -> Void
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let known = Set(environments)
        // Запись для нескольких окружений (VPN для Stage и Production) показывается в каждой их колонке.
        let loose = entries.filter { !$0.environments.contains(where: known.contains) }
        let columns = environments.map { env in (env, entries.filter { $0.environments.contains(env) }) }
            + (loose.isEmpty ? [] : [("Без окружения", loose)])

        // Без окружений — одна колонка «Все».
        let shown = environments.isEmpty ? [("Все", entries)] : columns
        // До трёх окружений колонки делят ширину, больше — листаются вбок.
        if shown.count <= 3 {
            HStack(alignment: .top, spacing: 20) {
                ForEach(shown, id: \.0) { env, items in
                    column(env: env, items: items, addable: known.contains(env) || environments.isEmpty)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, padded ? 32 : 0)
            .padding(.bottom, padded ? 28 : 0)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(shown, id: \.0) { env, items in
                        column(env: env, items: items, addable: known.contains(env)).frame(width: 340)
                    }
                }
                .padding(.horizontal, padded ? 32 : 0)
                .padding(.bottom, padded ? 28 : 0)
            }
        }
    }

    private func column(env: String, items: [Entry], addable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                EnvBadge(env: env)
                Text(Format.plural(items.count, "доступ", "доступа", "доступов"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                Spacer()
                if addable {
                    IconButton(systemName: "plus", label: "Новый доступ в \(env)", size: 26, iconSize: 12) {
                        onAdd(environments.contains(env) ? env : "")
                    }
                }
            }
            .frame(height: 28)
            if scrolls {
                ScrollView { cards(items, column: env) }.scrollIndicators(.never)
            } else {
                cards(items, column: env)
            }
        }
    }

    private func cards(_ items: [Entry], column: String) -> some View {
        VStack(spacing: 10) {
            ForEach(items) { entry in
                ProjectCard(entry: entry, column: environments.contains(column) ? column : nil)
            }
            if items.isEmpty {
                Text("Пусто")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
        }
    }
}

private struct ProjectCard: View {
    let entry: Entry
    var showsEnvironment = false
    /// Колонка, в которой стоит карточка: запись для Stage и Production в колонке Stage — не боевая.
    var column: String?
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { nav.inspecting = entry } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        if !entry.url.isEmpty {
                            Text(entry.displayURL).privacySensitive()
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Открыть запись")

                if let totp = entry.totp {
                    Button {
                        copy(TOTP.code(totp), "Код скопирован")
                    } label: {
                        TOTPCodeView(config: totp, fontSize: 15, ringSize: 16)
                            .padding(.leading, 10)
                            .padding(.trailing, 8)
                            .frame(height: 30)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Скопировать код 2FA")
                }
                if !entry.login.isEmpty {
                    small(Format.loginLabel(entry.loginKind)) { copy(entry.login, "\(Format.loginLabel(entry.loginKind)) скопирован", sensitive: false) }
                }
                switch entry.authKind {
                case .password where !entry.secret.isEmpty:
                    small("Пароль") { copy(entry.secret, "Пароль скопирован") }
                case .token where !entry.secret.isEmpty:
                    small("Токен") { copy(entry.secret, "Токен скопирован") }
                default:
                    EmptyView()
                }
            }
            HStack(spacing: 6) {
                if showsEnvironment { ForEach(entry.environments, id: \.self) { EnvBadge(env: $0) } }
                if let service = store.service(entry.serviceID), nav.currentServiceID != service.id {
                    Chip(text: service.name)
                }
                ForEach(Array(entry.preSteps.enumerated()), id: \.offset) { _, step in
                    Chip(text: store.title(of: step))
                    Text("→").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Chip(text: entry.authSummary)
                if entry.authKind == .sso, let target = store.entry(entry.ssoEntryID) {
                    Text("через «\(target.title)»").font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                } else if entry.authKind == .token {
                    Text(entry.maskedToken).privacySensitive().font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2).lineLimit(1)
                } else if !entry.login.isEmpty && entry.preSteps.isEmpty {
                    Text(entry.login).privacySensitive().font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(hovering ? Theme.cardHover : Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isProduction ? Theme.danger.opacity(0.22) : Theme.hairline))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Изменить") { nav.edit(entry) }
            Button("В корзину", role: .destructive) { Task { await store.trash(entry.id) } }
        }
    }

    private var isProduction: Bool {
        column.map { Theme.isProduction($0) } ?? entry.environments.contains(where: Theme.isProduction)
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSoft)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .hoverBackground(Color.white.opacity(0.07), cornerRadius: 7)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1)))
            .fixedSize()
    }

    private func copy(_ text: String, _ message: String, sensitive: Bool = true) {
        Clipboard.copy(text, sensitive: sensitive)
        Task { await store.markUsed(entry.id) }
        Toast.shared.show(message, over: NSApp.keyWindow)
    }
}
