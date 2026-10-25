import AppKit
import SwiftUI
import WardCore

@MainActor
final class Navigator: ObservableObject {
    static let shared = Navigator()

    enum Section: Hashable {
        case all, due, favorites, withCode, recent, shared, project(UUID), service(UUID), generator, audit, importExport, trash
    }

    enum SortMode: String, CaseIterable {
        case usage, title, updated

        var title: String {
            switch self {
            case .usage: return "По частоте использования"
            case .title: return "По названию"
            case .updated: return "По изменению"
            }
        }
    }

    struct Draft: Identifiable {
        let id = UUID()
        /// Запись, как она лежит в хранилище (или пустая новая) — с ней сравниваются правки.
        var entry: Entry
        var isNew: Bool
        var regenerate = false
        /// Сохранённый черновик, с которого продолжается правка.
        var restored: EntryDraft?
    }

    @Published var space: VaultSpace = .personal
    /// Текущая компания во «Работе».
    @Published var company: UUID?
    @Published var section: Section = .all
    @Published var selection: UUID?
    @Published var editing: Draft?
    @Published var inspecting: Entry?
    @Published var search = ""
    @Published var sort: SortMode = .usage

    var currentProjectID: UUID? {
        if case .project(let id) = section { return id }
        return nil
    }

    var currentServiceID: UUID? {
        if case .service(let id) = section { return id }
        return nil
    }

    /// Свёрнутые в боковой панели проекты (по умолчанию дерево раскрыто).
    @Published var collapsed: Set<UUID> = []

    func switchSpace(_ space: VaultSpace) {
        guard space != self.space else { return }
        self.space = space
        section = .all
        selection = nil
    }

    func switchCompany(_ id: UUID) {
        guard id != company else { return }
        company = id
        section = .all
        selection = nil
    }

    /// Запись видна в текущем разделе: во «Работе» — только записи текущей компании.
    @MainActor
    func inScope(_ entry: Entry, store: VaultStore) -> Bool {
        entry.space == space && (space != .work || store.companyID(of: entry) == company)
    }

    func open(_ entry: Entry) {
        space = entry.space
        if entry.space == .work, let company = VaultStore.shared.companyID(of: entry) { self.company = company }
        section = entry.isDeleted ? .trash : .all
        search = ""
        selection = entry.id
    }

    func newEntry(title: String = "", project: Project? = nil, service: Service? = nil, environment: String? = nil) {
        // Открытый редактор не подменяем: несохранённые правки в нём пропали бы молча.
        guard editing == nil else {
            Toast.shared.show("Сначала сохраните или закройте открытую запись")
            return
        }
        var entry = Entry(title: title, space: project?.space ?? service?.space ?? space)
        if entry.space == .work { entry.companyID = project?.companyID ?? service?.companyID ?? company }
        // Учётка проекта в сервисе — и проект, и сервис; иначе — то, что открыто сейчас.
        if project != nil || service != nil {
            entry.projectID = project?.id
            entry.serviceID = service?.id
        } else {
            entry.projectID = currentProjectID
            entry.serviceID = currentServiceID
        }
        entry.environment = environment.flatMap { $0.isEmpty ? nil : $0 }
        editing = Draft(entry: entry, isNew: true)
    }

    func edit(_ entry: Entry, regenerate: Bool = false) {
        guard editing == nil else {
            Toast.shared.show("Сначала сохраните или закройте открытую запись")
            return
        }
        inspecting = nil
        // Незаконченная правка этой записи продолжается, а не начинается заново.
        let restored = regenerate ? nil : VaultStore.shared.draft(entry.id)
        editing = Draft(entry: entry, isNew: false, regenerate: regenerate, restored: restored)
    }

    /// Продолжить черновик. Если саму запись за это время удалили навсегда — черновик станет новой записью.
    func resume(_ draft: EntryDraft) {
        guard editing == nil else {
            Toast.shared.show("Сначала сохраните или закройте открытую запись")
            return
        }
        inspecting = nil
        if !draft.isNew, let stored = VaultStore.shared.entry(draft.id) {
            editing = Draft(entry: stored, isNew: false, restored: draft)
        } else {
            editing = Draft(entry: Entry(id: draft.id, space: draft.entry.space), isNew: true, restored: draft)
        }
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let store: VaultStore
    private var window: NSWindow?

    init(store: VaultStore) {
        self.store = store
    }

    var nsWindow: NSWindow? { window }

    func show() {
        NSApp.setActivationPolicy(.regular)
        Foreground.show(self.window ?? makeWindow())
    }

    func windowWillClose(_ notification: Notification) {
        // Без главного окна Ward снова живёт только в строке меню.
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.sharingType = .none
        window.title = "Ward"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 620)
        window.backgroundColor = NSColor(Theme.window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView()
            .environmentObject(store)
            .environmentObject(Navigator.shared)
            .environmentObject(Prefs.shared))
        window.center()
        window.setFrameAutosaveName("WardMainWindow")
        self.window = window
        return window
    }
}

struct MainView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var prefs: Prefs

    var body: some View {
        Group {
            switch store.state {
            case .unlocked: unlocked
            case .locked: UnlockView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsSetup: SetupView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(Theme.window)
        .ignoresSafeArea()
        // Для всех состояний окна, включая разблокировку: иначе фокус с полем обводит системной синей рамкой кнопку.
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        // Листы только поверх открытого хранилища: иначе редактор мог бы всплыть над экраном блокировки.
        .sheet(item: Binding(get: { store.state == .unlocked ? nav.editing : nil }, set: { nav.editing = $0 })) { draft in
            EntryEditor(draft: draft)
                .environmentObject(store)
                .environmentObject(nav)
                .environmentObject(Prefs.shared)
        }
        .sheet(item: Binding(get: { store.state == .unlocked ? nav.inspecting : nil }, set: { nav.inspecting = $0 })) { entry in
            InspectSheet(entryID: entry.id)
                .environmentObject(store)
                .environmentObject(nav)
                .environmentObject(Prefs.shared)
        }
        .onChange(of: store.state) {
            if store.state != .unlocked {
                nav.editing = nil
                nav.inspecting = nil
            }
        }
        .alert("Ошибка", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var unlocked: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 220)
            Hairline(vertical: true)
            VStack(spacing: 0) {
                if !store.drafts.isEmpty && nav.editing == nil {
                    DraftsBar()
                    Hairline()
                }
                content
            }
        }
        .redacted(reason: prefs.hideData ? .privacy : [])
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch nav.section {
        case .generator:
            GeneratorPane()
        case .importExport:
            ImportExportPane()
        case .project(let id):
            // Простая группа без окружений, подпроектов и интеграций — обычным списком.
            if let project = store.project(id),
               !project.environments.isEmpty || !store.children(of: id).isEmpty || !store.services(of: id).isEmpty {
                ProjectPane(project: project)
            } else {
                listAndDetail
            }
        case .service(let id):
            if let service = store.service(id) {
                ServicePane(service: service)
            } else {
                listAndDetail
            }
        default:
            listAndDetail
        }
    }

    private var listAndDetail: some View {
        HStack(spacing: 0) {
            EntryListColumn().frame(width: 340)
            Hairline(vertical: true)
            EntryDetailPane()
        }
    }
}

private struct InspectSheet: View {
    let entryID: UUID
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var prefs: Prefs

    var body: some View {
        VStack(spacing: 0) {
            if let entry = store.entry(entryID) {
                EntryDetail(entry: entry, onClose: { nav.inspecting = nil })
            }
        }
        .frame(width: 720, height: 640)
        .redacted(reason: prefs.hideData ? .privacy : [])
        // Как в главном окне: лист — отдельное окно и не наследует это, иначе первую кнопку обводит синей рамкой.
        .focusEffectDisabled()
        .background(Theme.window)
        .environment(\.colorScheme, .dark)
    }
}

/// Незаконченные правки (после блокировки или перезапуска): продолжить или удалить.
private struct DraftsBar: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator
    @State private var deleting: EntryDraft?

    var body: some View {
        let drafts = store.drafts
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.clock").foregroundStyle(Theme.accent)
            Text(drafts.count == 1 ? "Несохранённый черновик" : "Несохранённые черновики")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(drafts) { draft in
                        HStack(spacing: 4) {
                            Button { nav.resume(draft) } label: {
                                Text("«\(title(draft))» · \(Format.dayTime(draft.savedAt))").lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .hoverLink()
                            .help("Продолжить правку")
                            IconButton(systemName: "xmark", label: "Удалить черновик", size: 20, iconSize: 9) {
                                deleting = draft
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                        .frame(height: 26)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(Theme.sidebar)
        .confirmationDialog("Удалить черновик «\(deleting.map(title) ?? "")»?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Удалить", role: .destructive) {
                if let deleting { Task { await store.removeDraft(deleting.id) } }
                deleting = nil
            }
        } message: {
            Text("Несохранённые правки пропадут. Сама запись, если она уже была, останется как есть.")
        }
    }

    private func title(_ draft: EntryDraft) -> String {
        let title = draft.entry.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? (draft.isNew ? "Новая запись" : "Без названия") : title
    }
}
