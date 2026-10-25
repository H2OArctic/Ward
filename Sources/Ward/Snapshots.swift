#if DEBUG
import AppKit
import WardCore

/// `WARD_SNAPSHOT=<папка> ./Ward.app/Contents/MacOS/Ward` — рисует основные экраны на демо-данных
/// в PNG и выходит. Нужен, чтобы проверять вёрстку без права на запись экрана.
@MainActor
enum Snapshots {
    static func run(into directory: URL, main: MainWindowController, panel: QuickPanelController,
                    settings: SettingsWindowController) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = VaultStore.shared
        let nav = Navigator.shared
        let demo = demoVault()
        let commandPrompt = CommandPrompt()
        var commandDemo = demo
        commandDemo.entries = demo.entries.filter { $0.address?.looksLikeSSH == true }.enumerated().map { index, entry in
            var server = entry
            server.title = "Сервер приложения"
            server.secret = "snapshot-only"
            server.environment = index == 0 ? "Production" : "Stage"
            return server
        }
        let commandServers = CommandServerMatch.find(CommandServerSearch(query: "сервер"), in: commandDemo)
        await store.loadDemo(demo)
        let billing = demo.projects.first { $0.name == "Биллинг" }!

        var steps: [(String, () -> NSWindow?)] = [
            ("1-panel", { panel.show(); return NSApp.windows.first { $0 is KeyPanel } }),
            ("2-main-personal", {
                panel.hide()
                main.show()
                nav.switchSpace(.personal)
                nav.selection = demo.entries.first { $0.title == "Госуслуги" }?.id
                return main.nsWindow
            }),
            ("3-main-weak", {
                nav.selection = demo.entries.first { $0.title == "Роутер" }?.id
                return main.nsWindow
            }),
            ("3a-card", {
                nav.selection = demo.entries.first { $0.title == "Карта Т-Банк" }?.id
                return main.nsWindow
            }),
            ("3b-ssh", {
                nav.switchSpace(.work)
                nav.company = demo.companies[0].id
                nav.selection = demo.entries.first { $0.title == "Прод-сервер" }?.id
                return main.nsWindow
            }),
            ("3c-certificate", {
                nav.selection = demo.entries.first { $0.title == "API mTLS" }?.id
                return main.nsWindow
            }),
            ("3d-nebula", {
                nav.selection = demo.entries.first { $0.title == "Nebula · prod-server" }?.id
                return main.nsWindow
            }),
            ("4-project", {
                nav.switchSpace(.work)
                nav.section = .project(billing.id)
                return main.nsWindow
            }),
            ("4c-subproject", {
                nav.section = .project(demo.projects.first { $0.name == "Платежи" }!.id)
                return main.nsWindow
            }),
            ("4d-service", {
                nav.section = .service(demo.services[1].id)
                return main.nsWindow
            }),
            ("4e-service-api", {
                nav.section = .service(demo.services[0].id)
                return main.nsWindow
            }),
            ("4f-shared", {
                nav.section = .shared
                nav.selection = demo.entries.first { $0.title == "Google Workspace" }?.id
                return main.nsWindow
            }),
            ("4g-hidden", {
                Prefs.shared.hideData = true
                nav.section = .all
                nav.selection = demo.entries.first { $0.title == "Google Workspace" }?.id
                return main.nsWindow
            }),
            ("4h-hidden-project", {
                nav.section = .project(billing.id)
                return main.nsWindow
            }),
            ("4i-inspect", {
                Prefs.shared.hideData = false
                nav.inspecting = demo.entries.first { $0.title == "Админка" && $0.environment == "Production" }
                return nil
            }),
            ("4j-connection", {
                nav.inspecting = nil
                nav.section = .shared
                nav.selection = demo.entries.first { $0.title == "VPN «Офис»" }?.id
                return main.nsWindow
            }),
            ("4b-import", {
                nav.editing = nil
                nav.section = .importExport
                return main.nsWindow
            }),
            ("5-editor", {
                nav.edit(demo.entries.first { $0.title == "Админка" && $0.environment == "Production" }!)
                return nil
            }),
            ("5b-editor-sso", {
                nav.editing = nil
                // Лист закрывается анимацией — новый открываем после паузы, иначе останется прежний.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    nav.edit(demo.entries.first { $0.title == "Grafana" }!)
                }
                return nil
            }),
            ("5c-editor-ssh", {
                nav.editing = nil
                // Лист закрывается анимацией — новый открываем после паузы, иначе останется прежний.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    nav.edit(demo.entries.first { $0.title == "Бэкап-сервер" }!)
                }
                return nil
            }),
            ("5e-drafts", {
                nav.editing = nil
                var edited = demo.entries.first { $0.title == "Госуслуги" }!
                edited.secret = "новый-пароль-после-смены-7"
                Task { await store.saveDraft(EntryDraft(entry: edited, isNew: false, reminderOn: false,
                                           reminder: Reminder(task: "", dayFrom: 1, dayTo: 1))) }
                nav.switchSpace(.personal)
                return main.nsWindow
            }),
            ("5f-editor-draft", {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let draft = store.drafts.first { nav.resume(draft) }
                }
                return nil
            }),
            ("5g-editor-envs", {
                nav.editing = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    nav.edit(demo.entries.first { $0.title == "Jump-хост" }!)
                }
                return nil
            }),
            ("5d-editor-card", {
                nav.editing = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    nav.edit(demo.entries.first { $0.title == "Карта Т-Банк" }!)
                }
                return nil
            }),
            ("6-settings", {
                nav.editing = nil
                settings.show()
                return NSApp.windows.first { $0.title == "Настройки" }
            }),
            ("8-approval", {
                ApprovalPanel.shared.show(ApprovalPanel.Request(keyTitle: "Прод-сервер", client: "ssh из git",
                                                                purpose: "вход как deploy", forwarded: false,
                                                                canRemember: true)) { _ in }
                return NSApp.windows.first { $0 is KeyPanel && $0.isVisible && $0.frame.width == 460 }
            }),
            ("8b-approval-forwarded", {
                ApprovalPanel.shared.cancelAll()
                ApprovalPanel.shared.show(ApprovalPanel.Request(keyTitle: "Прод-сервер", client: "ssh",
                                                                purpose: "вход как git", forwarded: true,
                                                                canRemember: true)) { _ in }
                return NSApp.windows.first { $0 is KeyPanel && $0.isVisible && $0.frame.width == 460 }
            }),
            ("8c-command-selection", {
                ApprovalPanel.shared.cancelAll()
                Task {
                    _ = await commandPrompt.select(commandServers,
                        query: "сервер", caller: "Codex")
                }
                return nil
            }),
            ("8d-command-approval", {
                commandPrompt.cancelAll()
                if let server = commandServers.first {
                    Task { _ = await commandPrompt.authorize(server, caller: "Codex", command: ["/usr/bin/id"], rememberMinutes: 15) }
                }
                return nil
            }),
            ("8e-command-many", {
                commandPrompt.cancelAll()
                let servers = (0..<7).compactMap { index -> CommandServerMatch? in
                    guard var server = commandServers.first else { return nil }
                    server.entryID = UUID()
                    server.title = index == 0 ? "Сервер обработки платежей и фоновых задач" : "Сервер приложения \(index + 1)"
                    server.location = "Компания › Платформа › Платежи › Обработка входящих операций · Хостинг"
                    return server
                }
                Task { _ = await commandPrompt.select(servers, query: "платежи", caller: "Codex") }
                return nil
            }),
            ("7-locked", {
                commandPrompt.cancelAll()
                ApprovalPanel.shared.cancelAll()
                store.lock(reason: .idle)
                return main.nsWindow
            }),
        ]
        steps.reverse()

        func next() {
            guard let (name, action) = steps.popLast() else {
                NSApp.terminate(nil)
                return
            }
            let window = action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                // Лист появляется асинхронно — берём его уже после паузы.
                let approval = name.hasPrefix("8") ? NSApp.windows.first { $0 is KeyPanel && $0.isVisible && [460, 480].contains($0.frame.width) } : nil
                if let target = approval ?? window ?? main.nsWindow?.attachedSheet {
                    save(target, to: directory.appendingPathComponent("\(name).png"))
                }
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
    }

    /// `WARD_AGENT_DEMO=<приватный ключ> WARD_AGENT_SOCKET=<сокет>`: демо-хранилище с этим ключом и включённым
    /// агентом без подтверждений — для проверки из терминала (`ssh-add -L`, `ssh-keygen -Y sign`). Выход — kill.
    static func runAgentDemo(keyPath: String, main: MainWindowController) async {
        let store = VaultStore.shared
        var demo = demoVault()
        var entry = Entry(title: "Ключ из демо", space: .work)
        var key = SSHKey(passphrase: ProcessInfo.processInfo.environment["WARD_AGENT_PASSPHRASE"] ?? "")
        _ = key.absorb((try? String(contentsOfFile: keyPath, encoding: .utf8)) ?? "")
        entry.ssh = key
        demo.entries.append(entry)
        await store.loadDemo(demo)
        Prefs.shared.apply({ var s = SecuritySettings(); s.sshAgentEnabled = true; s.sshAgentConfirm = false; return s }())
        AgentController.shared.start(store: store)
        main.show()
    }

    /// `WARD_BROWSER_DEMO=approve WARD_BROWSER_MANIFEST_DIR=<профиль Chrome>/NativeMessagingHosts`: демо-хранилище
    /// с учёткой для http://localhost и включённым мостом браузера — проверка расширения без настоящего хранилища.
    /// `approve` — окна подтверждения сами выбирают первый вариант (для автоматической проверки).
    static func runBrowserDemo(main: MainWindowController) async {
        let store = VaultStore.shared
        var demo = demoVault()
        var site = Entry(title: "Тестовый сайт")
        site.url = "http://localhost"
        site.login = "alice"
        site.secret = "demo-password-1"
        demo.entries.append(site)
        await store.loadDemo(demo)
        Prefs.shared.apply({ var s = SecuritySettings(); s.browserEnabled = true; return s }())
        BrowserController.shared.start(store: store)
        main.show()
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func demoVault() -> Vault {
        func secret() -> TOTPConfig { TOTPConfig(secret: Data((0..<20).map { _ in UInt8.random(in: 0...255) })) }
        let now = Date()

        let company = Company(name: "Ромашка")
        let client = Company(name: "Клиент «Альфа»")
        let billing = Project(name: "Биллинг", space: .work, environments: ["Stage", "Production"], companyID: company.id)
        let payments = Project(name: "Платежи", space: .work, environments: ["Stage", "Production"], parentID: billing.id,
                               companyID: company.id)
        let reports = Project(name: "Отчёты", space: .work, environments: ["Production"], parentID: billing.id,
                              companyID: company.id)
        let partner = Service(name: "API банка-партнёра", space: .work, companyID: company.id, url: "api.partner-bank.example",
                              environments: ["Sandbox", "Production"], projectIDs: [payments.id, reports.id])
        let hosting = Service(name: "Hetzner", space: .work, companyID: company.id, url: "console.hetzner.com")
        let common = Project(name: "Общее", space: .work, companyID: company.id)
        let alfaSite = Project(name: "Сайт", space: .work, environments: ["Production"], companyID: client.id)
        let home = Project(name: "Дом", space: .personal)

        func entry(_ title: String, _ space: VaultSpace, project: Project? = nil, env: String? = nil,
                   login: String = "", secretText: String = "", url: String = "", totp: Bool = false,
                   uses: Int = 0, configure: (inout Entry) -> Void = { _ in }) -> Entry {
            var e = Entry(title: title, space: space, now: now.addingTimeInterval(-86400 * 40))
            e.projectID = project?.id
            e.environment = env
            e.login = login
            e.loginKind = LoginKind.detect(login)
            e.secret = secretText
            e.url = url
            e.totp = totp ? secret() : nil
            e.useCount = uses
            e.lastUsedAt = uses > 0 ? now.addingTimeInterval(-Double(uses) * 3600) : nil
            configure(&e)
            return e
        }

        let google = entry("Рабочий Google", .work, project: common, login: "you@company.example",
                           secretText: "h3N!w8Qz-Rt5vYp2kLm", url: "accounts.google.com", totp: true, uses: 30)
        let vpn = entry("VPN «Офис»", .work, login: "you@company.example", secretText: "Vp4#nQ8r-Lm2x",
                        url: "vpn.romashka.example") {
            $0.isConnection = true
            $0.companyID = company.id
            $0.fields = [CustomField(name: "Протокол", value: "WireGuard"),
                         CustomField(name: "Сервер", value: "vpn.romashka.example:51820"),
                         CustomField(name: "Конфигурация", value: "[Interface]\nAddress = 10.8.0.5/32", hidden: true)]
        }
        let entries: [Entry] = [
            google,
            vpn,
            entry("Админка", .work, project: billing, env: "Production", login: "you@company.example",
                  secretText: "vK7#qP2m!xR9-tLw4zN8", url: "admin.billing.example", totp: true, uses: 12) {
                $0.preSteps = [.entry(vpn.id), .text("Basic auth")]
            },
            entry("Jump-хост", .work, project: billing, login: "jump", url: "bastion.billing.example:22") {
                $0.environments = ["Stage", "Production"]
            },
            entry("API", .work, project: billing, env: "Production", secretText: "demo-production-api-token",
                  url: "api.billing.example") { $0.authKind = .token },
            entry("PostgreSQL (чтение)", .work, project: billing, env: "Production", login: "billing_ro",
                  secretText: "Zp4-mWq8-Lr2n-Xv6t", url: "db.prod.internal:5432") { $0.preSteps = [.text("SSH-туннель")] },
            entry("Grafana", .work, project: billing, env: "Production", url: "grafana.billing.example") {
                $0.authKind = .sso
                $0.ssoEntryID = google.id
            },
            entry("Админка", .work, project: billing, env: "Stage", login: "qa@company.example",
                  secretText: "Ty7!kP3q#Wm9", url: "admin.stage.billing.example", uses: 4),
            entry("API", .work, project: billing, env: "Stage", secretText: "demo-stage-api-token",
                  url: "api.stage.billing.example") { $0.authKind = .token },
            entry("Шлюз оплаты", .work, project: payments, env: "Production", secretText: "demo-payment-gateway-token",
                  url: "pay.billing.example") { $0.authKind = .token },
            entry("Ключ API", .work, env: "Production", login: "merchant-4410", secretText: "demo-partner-production-token",
                  url: "api.partner-bank.example") {
                $0.authKind = .token
                $0.serviceID = partner.id
            },
            entry("Ключ API", .work, env: "Sandbox", login: "merchant-test", secretText: "demo-partner-sandbox-token",
                  url: "sandbox.partner-bank.example") {
                $0.authKind = .token
                $0.serviceID = partner.id
            },
            entry("Секрет вебхука", .work, env: "Production", secretText: "demo-webhook-secret",
                  url: "api.partner-bank.example") {
                $0.authKind = .token
                $0.serviceID = partner.id
            },
            entry("Владелец аккаунта", .work, login: "it@romashka.example", secretText: "Hz9!pQ2w-Lm4-Rt7",
                  url: "accounts.hetzner.com", totp: true) {
                $0.serviceID = hosting.id
            },
            entry("Проект «Платежи»", .work, project: payments, login: "payments-ops", secretText: "Kp3#wN8x-Qa5z",
                  url: "console.hetzner.com") {
                $0.serviceID = hosting.id
            },
            entry("Проект «Отчёты»", .work, project: reports, login: "reports-ops", secretText: "Vb6!tM2q-Zr9k",
                  url: "console.hetzner.com") {
                $0.serviceID = hosting.id
            },
            entry("Google Workspace", .work, login: "admin@romashka.example", secretText: "Gw4#kR8p!Ls2",
                  url: "admin.google.com", totp: true, uses: 6) {
                $0.companyID = company.id
            },
            entry("Банк-клиент", .work, login: "romashka-director", secretText: "Bk7!qW3e-Rt6y",
                  url: "online.bank.example") {
                $0.companyID = company.id
            },
            entry("Админка сайта", .work, project: alfaSite, env: "Production", login: "admin",
                  secretText: "Al5#fA9s-Kd2m", url: "alfa.example/admin"),
            entry("GitHub", .personal, login: "you@example.com", secretText: "vK7#qP2m!xR9-tLw4zN8x",
                  url: "github.com", totp: true, uses: 25) { $0.favorite = true },
            entry("Госуслуги", .personal, login: "+7 900 000-00-00", secretText: "river-candle-orbit-mango-5",
                  url: "gosuslugi.ru", uses: 3) {
                $0.notes = "Лицевой счёт: [НОМЕР]"
            },
            entry("Мосэнергосбыт", .personal, project: home, login: "you@example.com", secretText: "Mb8$wLq2Rz5n",
                  url: "my.mosenergosbyt.ru", uses: 2) {
                $0.reminder = Reminder(task: "Передать показания", dayFrom: 20, dayTo: 30)
            },
            entry("Роутер", .personal, project: home, login: "admin", secretText: "Qwerty2024!", url: "192.168.1.1"),
            entry("Figma", .personal, login: "you@example.com", secretText: "Qwerty2024!", url: "figma.com", uses: 1),
            entry("Прод-сервер", .work, project: billing, env: "Production", login: "deploy", url: "10.20.0.5:22") {
                $0.ssh = SSHKey(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPOKI3sNSZGj/x1SPrVtk8op1VMPVv+nVgy/V5hQpGhB deploy@billing")
                $0.preSteps = [.entry(vpn.id)]
            },
            entry("Бэкап-сервер", .work, project: billing, env: "Production", login: "deploy", url: "10.20.0.9:2222"),
            entry("Nebula · prod-server", .work, project: billing, env: "Production") {
                $0.certificate = CertificateBundle(certificate: """
                -----BEGIN NEBULA CERTIFICATE V2-----
                MIG6oFSAC3Byb2Qtc2VydmVyoQcEBQoqAAUQow4MB3NlcnZlcnMMA3NzaIUEardp
                lIYEbJidE4cg3YDQ4HJmnhjqPXyqAC6duyLmemAM0yLdQxrRaKX3ymqCIHchq+ib
                wlXGc82utUnNJ5RKlJ4b/iI/1kQOdnaCnFtig0Bi7L0Nzjn1o2V1l99RkMJ5EPgL
                HQMB090sDuLCfkORwG7B92GJblUC3muQZhkQkaON/NEno4Wirseq6BhP17cI
                -----END NEBULA CERTIFICATE V2-----
                -----BEGIN NEBULA CERTIFICATE V2-----
                MIGBoBuACldhcmQgQ0EgdjKEAf+FBGq3aZSGBGyYnRSCICPooc1hzYYZjDXnpqsl
                u0XMa0WOYUUrX+KERjFmHkfYg0DBMGjKUYETnt8Xcm96kyGYBNPix8m0DKniFAom
                3hYlcHQjmBtVG22buuRpotPFT3Mm04FpuOSJEuFNl5iaeeIJ
                -----END NEBULA CERTIFICATE V2-----

                """)
            },
            entry("API mTLS", .work, project: billing, env: "Production", url: "https://api.billing.example:8443") {
                $0.certificate = CertificateBundle(certificate: """
                -----BEGIN CERTIFICATE-----
                MIIBtTCCAVugAwIBAgIUCIWM9mH7hqFk6wkgEqRwkM/02EYwCgYIKoZIzj0EAwIw
                MDEcMBoGA1UEAwwTYXBpLmJpbGxpbmcuZXhhbXBsZTEQMA4GA1UECgwHQmlsbGlu
                ZzAeFw0yNjA5MjYwNTQ5MjRaFw0zNjA5MjMwNTQ5MjRaMDAxHDAaBgNVBAMME2Fw
                aS5iaWxsaW5nLmV4YW1wbGUxEDAOBgNVBAoMB0JpbGxpbmcwWTATBgcqhkjOPQIB
                BggqhkjOPQMBBwNCAATXBI/5491uf9knK/FaNXV5KtYNjl/Na41C3DI97u/qaQE5
                FcSfeFQQ8qlOSsiBiefa8njkv8JYR5LUBH96Klcoo1MwUTAdBgNVHQ4EFgQUYYj7
                +m1Q4BGiKG1wbMhEL9B1M80wHwYDVR0jBBgwFoAUYYj7+m1Q4BGiKG1wbMhEL9B1
                M80wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiAA0WGoNwADrVyc
                in26IUmVkQdrDjDLtl0PqyQkPyRuFgIhAIjvrX/szu0eeWu7oaZZOLXlj9yzvfk8
                GMEd7tCUSCKg
                -----END CERTIFICATE-----

                """)
            },
            entry("Карта Т-Банк", .personal, uses: 5) {
                $0.fields = [CustomField(name: "Номер карты", value: "5536 9137 0000 0000"),
                             CustomField(name: "Срок (ММ/ГГ)", value: "08/29"),
                             CustomField(name: "CVV", value: "000", hidden: true),
                             CustomField(name: "PIN", value: "0000", hidden: true)]
            },
            entry("Proton Mail", .personal, login: "you@mail.example", secretText: "Zx9#vB2m!Qa7-Lk3", url: "account.proton.me",
                  totp: true, uses: 8),
        ]
        var linked = entries
        if let holder = linked.first(where: { $0.title == "Прод-сервер" }),
           let i = linked.firstIndex(where: { $0.title == "Бэкап-сервер" }) {
            linked[i].sshKeyEntryID = holder.id
        }
        return Vault(companies: [company, client], projects: [billing, payments, reports, common, alfaSite, home],
                     services: [partner, hosting], entries: linked)
    }
}
#endif
