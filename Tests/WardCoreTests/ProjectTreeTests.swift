import XCTest
@testable import WardCore

final class ProjectTreeTests: XCTestCase {
    /// Компания «Ромашка»: проект А с дочерними Б и В; Б и В ходят в один чужой API.
    private func sample() -> (Vault, company: Company, a: Project, b: Project, c: Project, api: Service) {
        let company = Company(name: "Ромашка")
        let a = Project(name: "А", space: .work, environments: ["Stage", "Production"], companyID: company.id)
        let b = Project(name: "Б", space: .work, environments: ["Production"], parentID: a.id, companyID: company.id)
        let c = Project(name: "В", space: .work, environments: ["Dev", "Production"], parentID: a.id, companyID: company.id)
        var vault = Vault(companies: [company], projects: [a, b, c])
        let api = Service(name: "Чужой API", space: .work, companyID: company.id, url: "api.partner.com",
                          environments: ["Sandbox", "Production"], projectIDs: [b.id, c.id])
        vault.upsert(api)
        return (vault, company, a, b, c, api)
    }

    func testTreeAndPaths() {
        let (vault, company, a, b, c, api) = sample()
        XCTAssertEqual(vault.tree(in: .work, company: company.id).map { "\($0.depth) \($0.project.name)" }, ["0 А", "1 Б", "1 В"])
        XCTAssertEqual(vault.tree(in: .work, company: UUID()).count, 0, "проекты другой компании не видны")
        XCTAssertEqual(vault.path(of: b.id), "А › Б")
        XCTAssertEqual(vault.children(of: a.id, in: .work, company: company.id).map(\.name), ["Б", "В"])
        XCTAssertEqual(vault.subtree(of: a.id), [a.id, b.id, c.id])
        XCTAssertEqual(vault.services(of: b.id).map(\.name), ["Чужой API"])
        XCTAssertEqual(vault.services(of: a.id), [], "у А сервиса нет")

        var key = Entry(title: "Ключ API", space: .work)
        key.serviceID = api.id
        key.environment = "Sandbox"
        XCTAssertEqual(vault.location(of: key), "Чужой API")
        XCTAssertEqual(vault.companyID(of: key), company.id)
        XCTAssertTrue(vault.searchContext(of: key).contains("А › В"), "общая учётка находится по проекту, который ей пользуется")
        XCTAssertTrue(vault.searchContext(of: key).contains("Ромашка"))
    }

    /// Провайдер серверов: у каждого проекта своя учётка, и ещё общая учётка компании.
    func testProjectAccountsAtProvider() {
        var (vault, company, _, b, c, _) = sample()
        let hosting = Service(name: "Hetzner", space: .work, companyID: company.id)
        vault.upsert(hosting)
        var shared = Entry(title: "Владелец", space: .work)
        shared.serviceID = hosting.id
        var forB = Entry(title: "Учётка Б", space: .work)
        forB.serviceID = hosting.id
        forB.projectID = b.id
        vault.entries += [shared, forB]

        XCTAssertEqual(Set(vault.services(of: b.id).map(\.name)), ["Hetzner", "Чужой API"], "своя учётка — значит, сервис проекта")
        XCTAssertFalse(vault.services(of: c.id).contains { $0.id == hosting.id })
        XCTAssertEqual(vault.location(of: forB), "А › Б · Hetzner")
        XCTAssertEqual(vault.location(of: shared), "Hetzner")

        vault.removeService(hosting.id)
        XCTAssertEqual(vault.entries.first { $0.id == forB.id }?.projectID, b.id, "учётка проекта остаётся у проекта")
        let orphan = vault.entries.first { $0.id == shared.id }
        XCTAssertEqual(orphan.map { vault.companyID(of: $0) }, company.id, "общая учётка — общим доступом компании")
        XCTAssertEqual(orphan.map { vault.location(of: $0) }, "Общие доступы")
    }

    func testParentCannotCreateCycleOrCrossCompany() {
        var (vault, company, a, b, _, _) = sample()
        XCTAssertFalse(vault.possibleParents(for: a).contains { $0.id == b.id }, "в своего потомка нельзя")
        var moved = a
        moved.parentID = b.id
        vault.upsert(moved)
        XCTAssertNil(vault.project(a.id)?.parentID, "цикл не записывается — проект остаётся в корне")

        let other = Company(name: "Клиент")
        vault.upsert(other)
        var foreign = Project(name: "Чужой", space: .work, companyID: other.id)
        vault.upsert(foreign)
        foreign.parentID = a.id
        vault.upsert(foreign)
        XCTAssertEqual(vault.project(foreign.id)?.companyID, company.id, "подпроект — в компании родителя")

        var root = vault.project(a.id)!
        root.companyID = other.id
        vault.upsert(root)
        XCTAssertEqual(vault.project(b.id)?.companyID, other.id, "потомки переезжают вслед за корнем")
    }

    /// Повреждённые данные (цикл, пропавший родитель) не вешают обход и не прячут проекты.
    func testBrokenLinksStayVisible() {
        var x = Project(name: "X", space: .work)
        var y = Project(name: "Y", space: .work)
        x.parentID = y.id
        y.parentID = x.id
        var orphan = Project(name: "Сирота", space: .work)
        orphan.parentID = UUID()
        let vault = Vault(projects: [x, y, orphan])
        XCTAssertEqual(Set(vault.tree(in: .work).map(\.project.name)), ["X", "Y", "Сирота"])
        XCTAssertEqual(vault.path(of: orphan.id), "Сирота")
        XCTAssertEqual(vault.ancestors(of: x.id).count, 1)
    }

    func testRemovingProjectKeepsChildrenEntriesAndServices() {
        var (vault, company, a, b, c, api) = sample()
        var own = Entry(title: "Админка Б", space: .work)
        own.projectID = b.id
        own.environment = "Production"
        vault.entries.append(own)

        vault.removeProject(a.id)
        XCTAssertNil(vault.project(b.id)?.parentID, "дочерние поднимаются на место удалённого")
        XCTAssertNil(vault.project(c.id)?.parentID)

        vault.removeProject(b.id)
        XCTAssertEqual(vault.service(api.id)?.projectIDs, [c.id], "сервис остаётся у других проектов")
        XCTAssertNil(vault.entries[0].projectID)
        XCTAssertEqual(vault.companyID(of: vault.entries[0]), company.id, "запись осталась в компании")
    }

    func testServiceEnvironmentsRenameAndLinks() {
        var (vault, _, _, b, _, api) = sample()
        var key = Entry(title: "Ключ", space: .work)
        key.serviceID = api.id
        key.environment = "Sandbox"
        vault.entries.append(key)

        var renamed = api
        renamed.environments = ["Test", "Production"]
        renamed.projectIDs += [b.id, UUID()]
        vault.upsert(renamed, renamingEnvironments: ["Sandbox": "Test"])
        XCTAssertEqual(vault.entries[0].environment, "Test")
        XCTAssertEqual(vault.service(api.id)?.projectIDs.count, 2, "без дублей и ссылок в никуда")
    }

    func testCompanyDeletedOnlyWhenEmpty() {
        var (vault, company, _, _, _, _) = sample()
        XCTAssertFalse(vault.removeCompany(company.id), "с проектами — нельзя")
        let empty = Company(name: "Пустая")
        vault.upsert(empty)
        XCTAssertTrue(vault.removeCompany(empty.id))
        XCTAssertNil(vault.company(empty.id))
    }

    /// Хранилище до компаний: всё рабочее переезжает в одну новую компанию, личное не трогается.
    func testOldWorkDataMovesIntoCompany() {
        let root = Project(name: "Биллинг", space: .work)
        let child = Project(name: "API", space: .work, parentID: root.id)
        let home = Project(name: "Дом", space: .personal)
        let api = Service(name: "Stripe", space: .work)
        var loose = Entry(title: "Почта", space: .work)
        loose.projectID = UUID()
        let personal = Entry(title: "GitHub", space: .personal)
        var vault = Vault(projects: [root, child, home], services: [api], entries: [loose, personal])

        XCTAssertTrue(vault.assignOrphansToCompany(defaultName: "Компания"))
        let company = vault.companies.first!
        XCTAssertEqual(vault.companies.map(\.name), ["Компания"])
        XCTAssertEqual(vault.project(root.id)?.companyID, company.id)
        XCTAssertEqual(vault.project(child.id)?.companyID, company.id)
        XCTAssertNil(vault.project(home.id)?.companyID)
        XCTAssertEqual(vault.service(api.id)?.companyID, company.id)
        XCTAssertEqual(vault.companyID(of: vault.entries[0]), company.id, "запись с пропавшим проектом — общим доступом")
        XCTAssertNil(vault.entries[1].companyID)
        XCTAssertFalse(vault.assignOrphansToCompany(defaultName: "Компания"), "второй раз ничего не меняет")
    }

    func testDecodesVaultsFromEarlierVersions() throws {
        let service = "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
        let json = """
        {"format":1,"projects":[],"integrations":[{"id":"\(service)","name":"Stripe","space":"work"}],
         "entries":[{"id":"7F9619FF-8B86-D011-B42D-00CF4FC964FF","integrationID":"\(service)"}]}
        """
        let vault = try JSONDecoder().decode(Vault.self, from: Data(json.utf8))
        XCTAssertEqual(vault.services.first?.name, "Stripe", "интеграции читаются как сервисы")
        XCTAssertEqual(vault.entries.first?.serviceID?.uuidString, service)
        XCTAssertEqual(vault.companies, [])
        let old = try JSONDecoder().decode(Vault.self, from: Data(#"{"format":1,"projects":[],"entries":[]}"#.utf8))
        XCTAssertTrue(old.services.isEmpty)
    }

    func testMergeBringsCompaniesAndServices() {
        let (source, company, _, _, _, api) = sample()
        var target = Vault()
        target.merge(source)
        XCTAssertEqual(target.service(api.id)?.name, "Чужой API")
        XCTAssertEqual(target.company(company.id)?.name, "Ромашка")
        XCTAssertEqual(target.tree(in: .work, company: company.id).count, 3)
    }

    /// VPN для Stage и Production: одна запись в нескольких окружениях; старое поле `environment` читается.
    func testEntryInSeveralEnvironments() throws {
        let old = #"{"id":"7F9619FF-8B86-D011-B42D-00CF4FC964FF","environment":"Production"}"#
        XCTAssertEqual(try JSONDecoder().decode(Entry.self, from: Data(old.utf8)).environments, ["Production"])

        var (vault, _, a, _, _, _) = sample()
        var vpn = Entry(title: "VPN", space: .work)
        vpn.projectID = a.id
        vpn.environments = ["Stage", "Production"]
        vault.entries.append(vpn)
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(vpn))
        XCTAssertEqual(decoded.environments, ["Stage", "Production"])

        var merged = a
        merged.environments = ["Production"]
        vault.upsert(merged, renamingEnvironments: ["Stage": "Production"])
        XCTAssertEqual(vault.entries.last?.environments, ["Production"], "слияние окружений не оставляет дублей")
    }
}
