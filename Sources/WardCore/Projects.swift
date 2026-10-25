import Foundation

/// Компании, дерево проектов и сервисы. Связи задаются ссылками (`parentID`, `companyID`, `serviceID`), поэтому
/// данные из повреждённой копии могут содержать цикл или ссылку в никуда — обход везде защищён от этого.
extension Vault {
    public func company(_ id: UUID?) -> Company? {
        guard let id else { return nil }
        return companies.first { $0.id == id }
    }

    public func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func service(_ id: UUID?) -> Service? {
        guard let id else { return nil }
        return services.first { $0.id == id }
    }

    public var sortedCompanies: [Company] {
        companies.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Компания, к которой относится запись: через проект, через сервис или напрямую (общий доступ).
    public func companyID(of entry: Entry) -> UUID? {
        guard entry.space == .work else { return nil }
        if let project = project(entry.projectID) { return project.companyID }
        if let service = service(entry.serviceID) { return service.companyID }
        return entry.companyID
    }

    /// Предки от корня к родителю: для «Магазин › API › Платежи» у «Платежей» — [Магазин, API].
    public func ancestors(of id: UUID) -> [Project] {
        var chain: [Project] = []
        var seen: Set<UUID> = [id]
        var current = project(id)?.parentID
        while let parentID = current, seen.insert(parentID).inserted, let parent = project(parentID) {
            chain.insert(parent, at: 0)
            current = parent.parentID
        }
        return chain
    }

    /// «Магазин › API › Платежи».
    public func path(of id: UUID) -> String {
        (ancestors(of: id) + [project(id)].compactMap { $0 }).map(\.name).joined(separator: " › ")
    }

    /// Проекты одного пространства и одной компании (в «Личном» компании нет).
    private func peers(space: VaultSpace, company: UUID?) -> [Project] {
        projects.filter { $0.space == space && (space != .work || $0.companyID == company) }
    }

    /// Прямые дочерние проекты. У `nil` — корни, включая проекты, чей родитель пропал, в цикле или в другой
    /// компании: они не должны исчезнуть из дерева.
    public func children(of id: UUID?, in space: VaultSpace, company: UUID? = nil) -> [Project] {
        let group = peers(space: space, company: company)
        let known = Set(group.map(\.id))
        return group.filter { project in
            guard let id else { return project.parentID.map { !known.contains($0) || isInCycle($0) } ?? true }
            return project.parentID == id && project.id != id
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Проект и все его потомки.
    public func subtree(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in projects where child.parentID == next && result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    /// Куда можно перенести проект: в то же пространство и ту же компанию, но не в себя и не в своих потомков.
    public func possibleParents(for project: Project) -> [Project] {
        let excluded = subtree(of: project.id)
        return peers(space: project.space, company: project.companyID).filter { !excluded.contains($0.id) }
    }

    /// Проекты в порядке дерева с глубиной — для боковой панели и меню выбора.
    public func tree(in space: VaultSpace, company: UUID? = nil) -> [(project: Project, depth: Int)] {
        var result: [(Project, Int)] = []
        var seen = Set<UUID>()
        func walk(_ id: UUID?, _ depth: Int) {
            for child in children(of: id, in: space, company: company) where seen.insert(child.id).inserted {
                result.append((child, depth))
                walk(child.id, depth + 1)
            }
        }
        walk(nil, 0)
        return result
    }

    /// Сервисы проекта: подключённые общие учётки и те, где у проекта своя учётка.
    public func services(of projectID: UUID) -> [Service] {
        let own = Set(entries.filter { $0.projectID == projectID && !$0.isDeleted }.compactMap(\.serviceID))
        return services.filter { $0.projectIDs.contains(projectID) || own.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func services(in space: VaultSpace, company: UUID? = nil) -> [Service] {
        services.filter { $0.space == space && (space != .work || $0.companyID == company) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Родитель — в цикле, если, поднимаясь от него, возвращаемся к нему же: такие проекты показываются в корне.
    private func isInCycle(_ id: UUID) -> Bool {
        var seen: Set<UUID> = []
        var current: UUID? = id
        while let next = current {
            guard seen.insert(next).inserted else { return true }
            current = project(next)?.parentID
        }
        return false
    }

    /// Где лежит запись, без пространства: «Ромашка › А › Б · Hetzner», «Ромашка › Hetzner»,
    /// «Ромашка › Общие доступы». Пусто — вне проектов и компаний.
    public func location(of entry: Entry) -> String {
        var parts: [String] = []
        if let company = company(companyID(of: entry)), companies.count > 1 { parts.append(company.name) }
        var place: String?
        if let id = entry.projectID, project(id) != nil { place = path(of: id) }
        if let service = service(entry.serviceID) { place = place.map { "\($0) · \(service.name)" } ?? service.name }
        if place == nil, entry.space == .work, company(companyID(of: entry)) != nil { place = "Общие доступы" }
        if let place { parts.append(place) }
        return parts.joined(separator: " › ")
    }

    /// Для поиска: имя компании всегда, а общая учётка сервиса находится и по проектам, которые ей пользуются.
    public func searchContext(of entry: Entry) -> String {
        var parts = [location(of: entry), company(companyID(of: entry))?.name ?? ""]
        if entry.projectID == nil, let service = service(entry.serviceID) {
            parts += service.projectIDs.map { path(of: $0) }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Изменения

    /// Родитель из другого пространства или компании, сам проект или его потомок дал бы цикл — такой проект встаёт
    /// в корень. Подпроект всегда в компании родителя; сменили компанию корня — вслед переезжают потомки.
    public mutating func upsert(_ project: Project) {
        var project = project
        if project.space != .work { project.companyID = nil }
        if let parentID = project.parentID {
            if let parent = self.project(parentID), parent.space == project.space { project.companyID = parent.companyID }
            if !possibleParents(for: project).contains(where: { $0.id == parentID }) { project.parentID = nil }
        }
        if let i = projects.firstIndex(where: { $0.id == project.id }) {
            projects[i] = project
        } else {
            projects.append(project)
        }
        for id in subtree(of: project.id) where id != project.id {
            if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].companyID = project.companyID }
        }
    }

    /// Проект с переименованными окружениями: записи переезжают вслед за именем, а не теряются в «Без окружения».
    public mutating func upsert(_ project: Project, renamingEnvironments renames: [String: String]) {
        upsert(project)
        for i in entries.indices where entries[i].projectID == project.id {
            entries[i].environments = Self.renamed(entries[i].environments, renames)
        }
    }

    /// Записи проекта остаются в компании (общими доступами или учётками сервиса). Дочерние проекты поднимаются
    /// на его место, сервисы остаются у других проектов.
    public mutating func removeProject(_ id: UUID) {
        let removed = project(id)
        projects.removeAll { $0.id == id }
        for i in projects.indices where projects[i].parentID == id { projects[i].parentID = removed?.parentID }
        for i in services.indices { services[i].projectIDs.removeAll { $0 == id } }
        for i in entries.indices where entries[i].projectID == id {
            entries[i].projectID = nil
            entries[i].environments = []
            if entries[i].serviceID == nil { entries[i].companyID = removed?.companyID }
        }
    }

    /// Сервис с переименованными окружениями: общие учётки переезжают вслед за именем.
    /// Ссылки на проекты другой компании или несуществующие — отбрасываются.
    public mutating func upsert(_ service: Service, renamingEnvironments renames: [String: String] = [:]) {
        var service = service
        if service.space != .work { service.companyID = nil }
        let allowed = Set(peers(space: service.space, company: service.companyID).map(\.id))
        var linked: [UUID] = []
        for id in service.projectIDs where allowed.contains(id) && !linked.contains(id) { linked.append(id) }
        service.projectIDs = linked
        if let i = services.firstIndex(where: { $0.id == service.id }) {
            services[i] = service
        } else {
            services.append(service)
        }
        for i in entries.indices where entries[i].serviceID == service.id && entries[i].projectID == nil {
            entries[i].environments = Self.renamed(entries[i].environments, renames)
        }
    }

    /// Учётки сервиса остаются: учётки проектов — у своих проектов, общие — общими доступами компании.
    public mutating func removeService(_ id: UUID) {
        let removed = service(id)
        services.removeAll { $0.id == id }
        for i in entries.indices where entries[i].serviceID == id {
            entries[i].serviceID = nil
            if entries[i].projectID == nil {
                entries[i].environments = []
                entries[i].companyID = removed?.companyID
            }
        }
    }

    /// Окружения после переименования: слияние «Production» → «Prod» не оставляет дублей.
    private static func renamed(_ environments: [String], _ renames: [String: String]) -> [String] {
        var result: [String] = []
        for env in environments.map({ renames[$0] ?? $0 }) where !result.contains(env) { result.append(env) }
        return result
    }

    public mutating func upsert(_ company: Company) {
        if let i = companies.firstIndex(where: { $0.id == company.id }) {
            companies[i] = company
        } else {
            companies.append(company)
        }
    }

    /// Пустая компания: ни проектов, ни сервисов, ни записей (в том числе в корзине).
    public func isEmpty(company id: UUID) -> Bool {
        !projects.contains { $0.companyID == id } && !services.contains { $0.companyID == id }
            && !entries.contains { companyID(of: $0) == id }
    }

    /// Удаляется только пустая компания — её содержимое не должно пропасть или оказаться «нигде».
    @discardableResult
    public mutating func removeCompany(_ id: UUID) -> Bool {
        guard isEmpty(company: id) else { return false }
        companies.removeAll { $0.id == id }
        return true
    }

    /// Всё рабочее без компании (хранилище до появления компаний, импорт, восстановление из копии) — в первую
    /// компанию; компаний нет, а рабочее есть — создаётся компания `defaultName`. `true` — что-то изменилось.
    @discardableResult
    public mutating func assignOrphansToCompany(defaultName: String) -> Bool {
        let known = Set(companies.map(\.id))
        let orphanProjects = projects.indices.filter {
            projects[$0].space == .work && projects[$0].parentID.flatMap(project) == nil
                && !known.contains(projects[$0].companyID ?? UUID())
        }
        let orphanServices = services.indices.filter {
            services[$0].space == .work && !known.contains(services[$0].companyID ?? UUID())
        }
        let orphanEntries = entries.indices.filter {
            entries[$0].space == .work && entries[$0].projectID.flatMap(project) == nil
                && entries[$0].serviceID.flatMap(service) == nil && !known.contains(entries[$0].companyID ?? UUID())
        }
        let childrenOutOfLine = projects.contains { child in
            child.space == .work && project(child.parentID).map { $0.companyID != child.companyID } == true
        }
        guard !orphanProjects.isEmpty || !orphanServices.isEmpty || !orphanEntries.isEmpty || childrenOutOfLine else {
            return false
        }
        if companies.isEmpty { companies.append(Company(name: defaultName)) }
        let target = sortedCompanies[0].id
        for i in orphanProjects { projects[i].companyID = target }
        for i in orphanServices { services[i].companyID = target }
        for i in orphanEntries {
            entries[i].companyID = target
            entries[i].projectID = nil
            entries[i].serviceID = nil
        }
        // Подпроекты — в компанию своего корня.
        for root in projects where root.space == .work && root.parentID.flatMap(project) == nil {
            for id in subtree(of: root.id) {
                if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].companyID = root.companyID }
            }
        }
        return true
    }

    // MARK: - Подключения

    /// Подключения, которые можно выбрать шагом у записи: того же пространства и той же компании, живые.
    public func connections(for entry: Entry) -> [Entry] {
        let company = companyID(of: entry) ?? entry.companyID
        return entries.filter {
            $0.isConnection && !$0.isDeleted && $0.id != entry.id && $0.space == entry.space
                && (entry.space != .work || companyID(of: $0) == company)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Как показать шаг: текст или название подключения (удалённое навсегда — уже снято `purge`).
    public func title(of step: PreStep) -> String {
        switch step {
        case .text(let text): return text
        case .entry(let id): return entries.first { $0.id == id }?.title ?? "Подключение удалено"
        }
    }

    /// Записи, которые входят через это подключение, — чтобы предупредить перед удалением.
    public func entriesUsing(connection id: UUID) -> [Entry] {
        entries.filter { !$0.isDeleted && $0.preSteps.contains(.entry(id)) }
    }

    // MARK: - Черновики

    public func draft(_ id: UUID) -> EntryDraft? { drafts.first { $0.id == id } }

    public mutating func saveDraft(_ draft: EntryDraft) {
        if let i = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[i] = draft
        } else {
            drafts.append(draft)
        }
    }

    public mutating func removeDraft(_ id: UUID) {
        drafts.removeAll { $0.id == id }
    }
}
