import SwiftUI
import WardCore

struct Sidebar: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var prefs: Prefs
    @State private var editingProject: Project?
    @State private var deletingProject: Project?
    @State private var editingService: Service?
    @State private var deletingService: Service?
    @State private var editingCompany: Company?
    @State private var deletingCompany: Company?

    var body: some View {
        let inSpace = store.active.filter { nav.inScope($0, store: store) }
        let reuse = store.reuseCounts()
        let auditCount = inSpace.filter { store.hasIssues($0, reuse: reuse) }.count
        let dueCount = inSpace.filter { $0.reminder?.isDue() == true }.count
        let trashCount = store.trashed.filter { nav.inScope($0, store: store) }.count

        VStack(alignment: .leading, spacing: 0) {
            spaceSwitcher
                .padding(.top, 44)
            .padding(.bottom, nav.space == .work ? 8 : 14)
            if nav.space == .work {
                companySwitcher.padding(.bottom, 10)
            }

            VStack(spacing: 2) {
                item(.all, "list.bullet", "Все записи", count: inSpace.count)
                if dueCount > 0 || inSpace.contains(where: { $0.reminder != nil }) {
                    item(.due, "calendar.badge.clock", "Сейчас нужно", badge: dueCount)
                }
                item(.favorites, "star", "Избранное", count: inSpace.filter(\.favorite).count)
                item(.withCode, "lock.shield", "С 2FA", count: inSpace.filter { $0.totp != nil }.count)
                item(.recent, "clock", "Недавние")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if nav.space == .work {
                        header("КОМПАНИЯ")
                        item(.shared, "building.2", "Общие доступы",
                             count: inSpace.filter { $0.projectID == nil && $0.serviceID == nil }.count)
                    }
                    projectsSection(inSpace)
                    servicesSection(inSpace)
                    header("ИНСТРУМЕНТЫ")
                    VStack(spacing: 2) {
                        item(.generator, "dice", "Генератор")
                        item(.audit, "exclamationmark.triangle", "Аудит", badge: auditCount, badgeColor: Theme.danger)
                        item(.importExport, "square.and.arrow.down", "Импорт и экспорт")
                        item(.trash, "trash", "Корзина", count: trashCount)
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 12)

            Hairline().padding(.bottom, 8)
            HStack(spacing: 4) {
                IconButton(systemName: "lock", label: "Заблокировать (⌃⌘L)", size: 34) {
                    store.lock(reason: .manual)
                }
                IconButton(systemName: prefs.hideData ? "eye.slash" : "eye",
                           label: prefs.hideData ? "Показать данные (⌘⇧H)" : "Скрыть данные от тех, кто рядом (⌘⇧H)",
                           size: 34, tint: prefs.hideData ? Theme.accent : Theme.text2) {
                    prefs.hideData.toggle()
                }
                Spacer()
                IconButton(systemName: "gearshape", label: "Настройки", size: 34) {
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .focusEffectDisabled()
        .sheet(item: $editingProject) { project in
            ProjectEditor(project: project)
                .environmentObject(store)
                .environmentObject(nav)
        }
        .sheet(item: $editingCompany) { company in
            CompanyEditor(company: company)
                .environmentObject(store)
                .environmentObject(nav)
        }
        .confirmationDialog("Удалить компанию «\(deletingCompany?.name ?? "")»?",
                            isPresented: Binding(get: { deletingCompany != nil }, set: { if !$0 { deletingCompany = nil } })) {
            Button("Удалить", role: .destructive) {
                let company = deletingCompany
                deletingCompany = nil
                Task {
                    if let company, await store.deleteCompany(company.id),
                       let next = store.companies.first { nav.switchCompany(next.id) }
                }
            }
        } message: {
            Text("Удаляется только пустая компания — без проектов, сервисов и записей.")
        }
        // Текущая компания — всегда существующая: после удаления, создания первой или при запуске.
        .onAppear(perform: fixCompany)
        .onChange(of: store.companies.map(\.id)) { fixCompany() }
        .sheet(item: $editingService) { service in
            ServiceEditor(service: service)
                .environmentObject(store)
                .environmentObject(nav)
        }
        .confirmationDialog("Удалить «\(deletingProject?.name ?? "")»?",
                            isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } })) {
            Button("Удалить", role: .destructive) {
                guard let project = deletingProject else { return }
                if nav.section == .project(project.id) { nav.section = .all }
                Task { await store.deleteProject(project.id) }
                deletingProject = nil
            }
        } message: {
            Text(deletingProject.map { store.children(of: $0.id).isEmpty } ?? true
                 ? "Записи проекта не удалятся — останутся без привязки к нему."
                 : "Записи проекта не удалятся, подпроекты поднимутся на уровень выше.")
        }
        .confirmationDialog("Удалить сервис «\(deletingService?.name ?? "")»?",
                            isPresented: Binding(get: { deletingService != nil }, set: { if !$0 { deletingService = nil } })) {
            Button("Удалить", role: .destructive) {
                guard let service = deletingService else { return }
                if nav.section == .service(service.id) { nav.section = .all }
                Task { await store.deleteService(service.id) }
                deletingService = nil
            }
        } message: {
            Text("Учётки проектов останутся у проектов, общие учётки — в «Общих доступах» компании.")
        }
    }

    private func projectsSection(_ inScope: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(nav.space == .work ? "ПРОЕКТЫ" : "ГРУППЫ")
            VStack(spacing: 2) {
                ForEach(visibleTree, id: \.project.id) { item in
                    projectItem(item.project, depth: item.depth,
                                count: inScope.filter { $0.projectID == item.project.id }.count)
                }
                addButton(nav.space == .work ? "Новый проект" : "Новая группа") {
                    editingProject = Project(name: "", space: nav.space,
                                             environments: nav.space == .work ? ["Stage", "Production"] : [],
                                             companyID: nav.space == .work ? nav.company : nil)
                }
            }
        }
    }

    private func servicesSection(_ inScope: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header("СЕРВИСЫ")
            VStack(spacing: 2) {
                ForEach(store.services(in: nav.space, company: nav.company)) { service in
                    serviceItem(service, count: inScope.filter { $0.serviceID == service.id }.count)
                }
                addButton("Новый сервис") {
                    editingService = Service(name: "", space: nav.space, companyID: nav.space == .work ? nav.company : nil)
                }
            }
        }
    }

    /// Компания во «Работе»: выбор, новая, переименование, удаление пустой.
    private var companySwitcher: some View {
        let current = store.company(nav.company)
        return Menu {
            ForEach(store.companies) { company in
                Button { nav.switchCompany(company.id) } label: {
                    if company.id == nav.company { Label(company.name, systemImage: "checkmark") } else { Text(company.name) }
                }
            }
            Divider()
            Button("Новая компания…") { editingCompany = Company(name: "") }
            if let current {
                Button("Переименовать «\(current.name)»…") { editingCompany = current }
                Button("Удалить «\(current.name)»…", role: .destructive) { deletingCompany = current }
                    .disabled(!store.isEmpty(company: current.id) || store.companies.count < 2)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "building.2").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Text(current?.name ?? "Компания").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.segment, in: RoundedRectangle(cornerRadius: 8))
            .hoverBackground(cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Компания")
    }

    private var spaceSwitcher: some View {
        HStack(spacing: 2) {
            ForEach([(VaultSpace.personal, "Личное"), (VaultSpace.work, "Работа")], id: \.0) { space, title in
                Button { nav.switchSpace(space) } label: {
                    Text(title)
                        .font(.system(size: 13, weight: nav.space == space ? .medium : .regular))
                        .foregroundStyle(nav.space == space ? Theme.text : Theme.text2)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(nav.space == space ? Theme.segmentOn : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .hoverBackground(cornerRadius: 6, enabled: nav.space != space)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.segment, in: RoundedRectangle(cornerRadius: 8))
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 10)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func item(_ section: Navigator.Section, _ icon: String, _ title: String,
                      count: Int? = nil, badge: Int = 0, badgeColor: Color = Theme.accent) -> some View {
        let active = nav.section == section
        return Button {
            nav.section = section
            nav.selection = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(badgeColor == Theme.danger ? Theme.onDanger : Theme.onAccent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(badgeColor, in: Capsule())
                } else if let count {
                    Text("\(count)").font(.system(size: 12)).foregroundStyle(active ? Theme.text2 : Theme.text3)
                }
            }
            .foregroundStyle(active ? Theme.text : Theme.textSoft)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(active ? Theme.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .hoverBackground(enabled: !active)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fixCompany() {
        if store.company(nav.company) == nil { nav.company = store.companies.first?.id }
    }

    /// Дерево без потомков свёрнутых проектов.
    private var visibleTree: [(project: Project, depth: Int)] {
        var hiddenBelow: Int?
        return store.tree(in: nav.space, company: nav.company).filter { item in
            if let limit = hiddenBelow {
                if item.depth > limit { return false }
                hiddenBelow = nil
            }
            if nav.collapsed.contains(item.project.id) { hiddenBelow = item.depth }
            return true
        }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 10)
                .hoverBackground()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func projectItem(_ project: Project, depth: Int, count: Int) -> some View {
        let active = nav.section == .project(project.id)
        let hasChildren = !store.children(of: project.id).isEmpty
        let collapsed = nav.collapsed.contains(project.id)
        return Button {
            nav.section = .project(project.id)
            nav.selection = nil
        } label: {
            HStack(spacing: 6) {
                Group {
                    if hasChildren {
                        Button {
                            if collapsed { nav.collapsed.remove(project.id) } else { nav.collapsed.insert(project.id) }
                        } label: {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 12, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(collapsed ? "Показать подпроекты" : "Скрыть подпроекты")
                    } else {
                        Color.clear.frame(width: 12)
                    }
                }
                Avatar(title: project.name, size: 18)
                Text(project.name).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 12)).foregroundStyle(active ? Theme.text2 : Theme.text3)
            }
            .foregroundStyle(active ? Theme.text : Theme.textSoft)
            .padding(.leading, 4 + CGFloat(min(depth, 6)) * 14)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background(active ? Theme.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .hoverBackground(enabled: !active)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Новый подпроект…") {
                editingProject = Project(name: "", space: project.space, environments: project.environments, parentID: project.id)
            }
            Button("Изменить…") { editingProject = project }
            Button("Удалить…", role: .destructive) { deletingProject = project }
        }
    }

    private func serviceItem(_ service: Service, count: Int) -> some View {
        let active = nav.section == .service(service.id)
        return Button {
            nav.section = .service(service.id)
            nav.selection = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 12)).frame(width: 18)
                Text(service.name).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 12)).foregroundStyle(active ? Theme.text2 : Theme.text3)
            }
            .foregroundStyle(active ? Theme.text : Theme.textSoft)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(active ? Theme.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .hoverBackground(enabled: !active)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Изменить…") { editingService = service }
            Button("Удалить…", role: .destructive) { deletingService = service }
        }
    }
}

/// Окружение со стабильным id: удаление строки не ломает привязки полей, а переименование видно по `original`.
struct EnvironmentRow: Identifiable {
    let id = UUID()
    let original: String?
    var name: String

    static func rows(_ environments: [String]) -> [EnvironmentRow] {
        environments.map { EnvironmentRow(original: $0, name: $0) }
    }

    /// Итоговый список без пустых и дублей и переименования старых имён — записи переедут вслед за именем.
    static func result(_ rows: [EnvironmentRow]) -> (environments: [String], renames: [String: String]) {
        var environments: [String] = []
        var renames: [String: String] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // До проверки на дубль: слияние «Production» → «Prod» тоже переносит записи.
            if let original = row.original, original != name { renames[original] = name }
            if !environments.contains(name) { environments.append(name) }
        }
        return (environments, renames)
    }
}

struct EnvironmentsField: View {
    @Binding var rows: [EnvironmentRow]
    let placeholder: String
    let hint: String
    @State private var newEnvironment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Окружения · необязательно")
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField("", text: $row.name).wardField(height: 32)
                    IconButton(systemName: "minus.circle", label: "Убрать окружение") {
                        rows.removeAll { $0.id == row.id }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $newEnvironment)
                    .onSubmit(add)
                    .wardField(height: 32)
                Button("Добавить", action: add).buttonStyle(SecondaryButtonStyle(height: 32))
            }
            Text(hint).font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
    }

    private func add() {
        let name = newEnvironment.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        rows.append(EnvironmentRow(original: nil, name: name))
        newEnvironment = ""
    }
}

/// Подпись проекта в меню: отступ по глубине дерева.
private func indented(_ project: Project, depth: Int) -> String {
    String(repeating: "    ", count: depth) + project.name
}

struct ProjectEditor: View {
    @State private var saving = false
    @State private var project: Project
    @State private var rows: [EnvironmentRow]
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    init(project: Project) {
        _project = State(initialValue: project)
        _rows = State(initialValue: EnvironmentRow.rows(project.environments))
    }

    private var isNew: Bool { store.project(project.id) == nil }

    private var title: String {
        if !isNew { return "Изменить «\(project.name)»" }
        if project.parentID != nil { return "Новый подпроект" }
        return project.space == .work ? "Новый проект" : "Новая группа"
    }

    var body: some View {
        let allowed = Set(store.possibleParents(for: project).map(\.id))
        let parents = store.tree(in: project.space, company: project.companyID).filter { allowed.contains($0.project.id) }

        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Название")
                TextField("", text: $project.name).wardField()
            }

            if project.space == .work && project.parentID == nil && store.companies.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Компания")
                    Picker("", selection: $project.companyID) {
                        ForEach(store.companies) { company in Text(company.name).tag(UUID?.some(company.id)) }
                    }
                    .labelsHidden()
                    Text("Подпроекты переедут вместе с ним.").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Входит в проект")
                Picker("", selection: $project.parentID) {
                    Text("— верхний уровень —").tag(UUID?.none)
                    ForEach(parents, id: \.project.id) { item in
                        Text(indented(item.project, depth: item.depth)).tag(UUID?.some(item.project.id))
                    }
                }
                .labelsHidden()
            }

            EnvironmentsField(rows: $rows, placeholder: "Stage, Production, Dev…",
                              hint: "С окружениями проект показывается колонками Stage / Production.")

            HStack {
                if let saveError {
                    Text(saveError).font(.system(size: 12)).foregroundStyle(Theme.danger).lineLimit(2)
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Сохранить", action: { Task { await save() } })
                    .buttonStyle(AccentButtonStyle())
                    .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(Theme.sheet)
        .disabled(saving)
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        project.name = project.name.trimmingCharacters(in: .whitespaces)
        let (environments, renames) = EnvironmentRow.result(rows)
        project.environments = environments
        guard await store.save(project, renamingEnvironments: renames) else {
            // Ошибку показываем здесь: алерт главного окна за открытым листом не видно, а введённое терять нельзя.
            saveError = store.lastError
            store.lastError = nil
            return
        }
        if let parent = project.parentID { nav.collapsed.remove(parent) }
        if let company = store.project(project.id)?.companyID { nav.company = company }
        nav.section = .project(project.id)
        dismiss()
    }
}

struct ServiceEditor: View {
    @State private var saving = false
    @State private var service: Service
    @State private var rows: [EnvironmentRow]
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    init(service: Service) {
        _service = State(initialValue: service)
        _rows = State(initialValue: EnvironmentRow.rows(service.environments))
    }

    private var isNew: Bool { store.service(service.id) == nil }

    var body: some View {
        let projects = store.tree(in: service.space, company: service.companyID)

        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "Новый сервис" : "Изменить «\(service.name)»")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Сервис")
                    TextField("Hetzner, Stripe, API партнёра…", text: $service.name).wardField()
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Адрес · необязательно")
                    TextField("api.partner.com", text: $service.url).autocorrectionDisabled().wardField()
                }
            }

            EnvironmentsField(rows: $rows, placeholder: "Sandbox, Production…",
                              hint: "Для общих учёток: у чужого API часто Sandbox и Production. У провайдера можно без них.")

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Общими учётками пользуются проекты")
                if projects.isEmpty {
                    Text("Проектов пока нет").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(projects, id: \.project.id) { item in
                            Toggle(isOn: Binding(
                                get: { service.projectIDs.contains(item.project.id) },
                                set: { on in
                                    service.projectIDs.removeAll { $0 == item.project.id }
                                    if on { service.projectIDs.append(item.project.id) }
                                })) {
                                Text(item.project.name).font(.system(size: 13)).foregroundStyle(Theme.text)
                            }
                            .toggleStyle(.checkbox)
                            .padding(.leading, CGFloat(item.depth) * 18)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            HStack {
                if let saveError {
                    Text(saveError).font(.system(size: 12)).foregroundStyle(Theme.danger).lineLimit(2)
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Сохранить", action: { Task { await save() } })
                    .buttonStyle(AccentButtonStyle())
                    .disabled(service.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.sheet)
        .disabled(saving)
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        service.name = service.name.trimmingCharacters(in: .whitespaces)
        service.url = service.url.trimmingCharacters(in: .whitespaces)
        let (environments, renames) = EnvironmentRow.result(rows)
        service.environments = environments
        guard await store.save(service, renamingEnvironments: renames) else {
            saveError = store.lastError
            store.lastError = nil
            return
        }
        // Новый сервис из проекта оставляем на странице проекта: там его и подключали.
        if !isNew || nav.currentProjectID == nil { nav.section = .service(service.id) }
        dismiss()
    }
}

struct CompanyEditor: View {
    @State private var saving = false
    @State private var company: Company
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    init(company: Company) {
        _company = State(initialValue: company)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.company(company.id) == nil ? "Новая компания" : "Переименовать компанию")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Название")
                TextField("Ромашка, клиент…", text: $company.name).wardField()
            }
            HStack {
                if let saveError {
                    Text(saveError).font(.system(size: 12)).foregroundStyle(Theme.danger).lineLimit(2)
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Сохранить", action: { Task { await save() } })
                    .buttonStyle(AccentButtonStyle())
                    .disabled(company.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(Theme.sheet)
        .disabled(saving)
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        company.name = company.name.trimmingCharacters(in: .whitespaces)
        guard await store.save(company) else {
            saveError = store.lastError
            store.lastError = nil
            return
        }
        nav.switchCompany(company.id)
        dismiss()
    }
}
