import XCTest
@testable import Ward
import WardCore

final class CommandLifecycleTests: XCTestCase {
    @MainActor
    private func setup(password: String = "demo-only-password") async -> (VaultStore, Entry, SudoRequest) {
        var entry = Entry(title: "Server")
        entry.url = "ssh://deploy@server.example"
        entry.secret = password
        let store = VaultStore(storage: CommandMemoryStorage(),
            backups: BackupStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), keep: { 1 }))
        await store.loadDemo(Vault(entries: [entry]))
        Prefs.shared.commandAccessEnabled = true
        Prefs.shared.commandApprovalMinutes = 15
        return (store, entry, SudoRequest(entryID: entry.id, arguments: ["/usr/bin/id"]))
    }

    @MainActor
    func testPasswordlessServerCanBeSelectedAndAuthorized() async {
        let (store, entry, original) = await setup(password: "")
        defer { Prefs.shared.commandAccessEnabled = false }
        var prompts = 0
        let controller = CommandController(store: store, approval: { _, _, _, _ in prompts += 1; return 0 })
        let selection = await controller.findServers(CommandServerSearch(query: "server.example"),
            caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertEqual(selection.selectedEntryID, entry.id)
        XCTAssertNil(selection.credentials)
        var request = original
        request.selectionRequired = true
        let response = await controller.approve(request, caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertNil(response.error)
        XCTAssertEqual(response.credentials?.password, "")
        XCTAssertEqual(prompts, 2)
        controller.revoke()
        let denied = await controller.approve(request, caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertNil(denied.credentials)
    }

    @MainActor
    func testPendingApprovalCannotSurviveLockRevokeOrDisconnect() async {
        for action in ["lock", "revoke", "disconnect", "cancel", "disable"] {
            let (store, _, request) = await setup()
            let shown = expectation(description: action)
            var continuation: CheckedContinuation<Int?, Never>?
            var connected = true
            let controller = CommandController(store: store, approval: { _, _, _, _ in
                await withCheckedContinuation { continuation = $0; shown.fulfill() }
            })
            let task = Task { await controller.approve(request, caller: ("process:1", "/demo/codex"), isCurrentPeer: { connected }) }
            await fulfillment(of: [shown], timeout: 1)
            switch action {
            case "lock": store.lock(reason: .manual)
            case "revoke": controller.revoke()
            case "disconnect": connected = false
            case "cancel": task.cancel()
            default: Prefs.shared.commandAccessEnabled = false
            }
            continuation?.resume(returning: 1)
            let response = await task.value
            XCTAssertNil(response.credentials, action)
            XCTAssertNotNil(response.error, action)
        }
        Prefs.shared.commandAccessEnabled = false
    }

    @MainActor
    func testServerPickerReturnsOnlyChosenIDAndMCPRejectsOtherEntries() async throws {
        let (store, entry, original) = await setup()
        var prompts = 0
        let controller = CommandController(store: store, approval: { _, _, _, _ in prompts += 1; return 0 })
        var request = original
        request.selectionRequired = true
        let denied = await controller.approve(request, caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertNil(denied.credentials)
        XCTAssertEqual(prompts, 0)
        let selection = await controller.findServers(CommandServerSearch(query: "server"), caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertEqual(selection.selectedEntryID, entry.id)
        XCTAssertNil(selection.credentials)
        let json = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        XCTAssertFalse(json.contains(entry.secret))
        XCTAssertFalse(json.contains("server.example"))
        XCTAssertFalse(json.contains(entry.login))
        XCTAssertEqual(prompts, 1)
        let allowed = await controller.approve(request, caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertNotNil(allowed.credentials)
        XCTAssertEqual(prompts, 2)
        let other = await controller.approve(request, caller: ("mcp:2", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertNil(other.credentials)
        controller.revoke()
        let revoked = await controller.approve(request, caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { true })
        XCTAssertNil(revoked.credentials)
        Prefs.shared.commandAccessEnabled = false
    }

    @MainActor
    func testServerPickerCannotReturnIDAfterLockDisconnectOrCancellation() async {
        for action in ["lock", "disconnect", "cancel", "revoke"] {
            let (store, _, _) = await setup()
            var connected = true
            let shown = expectation(description: action)
            var continuation: CheckedContinuation<Int?, Never>?
            let controller = CommandController(store: store, approval: { _, _, _, _ in
                await withCheckedContinuation { continuation = $0; shown.fulfill() }
            })
            let task = Task { await controller.findServers(CommandServerSearch(query: "server"), caller: ("mcp:1", "/Ward/mcp"), isCurrentPeer: { connected }) }
            await fulfillment(of: [shown], timeout: 1)
            switch action {
            case "lock": store.lock(reason: .manual)
            case "disconnect": connected = false
            case "cancel": task.cancel()
            default: controller.revoke()
            }
            continuation?.resume(returning: 0)
            let response = await task.value
            XCTAssertNil(response.selectedEntryID, action)
            XCTAssertNil(response.credentials, action)
        }
        Prefs.shared.commandAccessEnabled = false
    }

    @MainActor
    func testTimedApprovalIsReusedOnlyForSameProcessAndRevokedExplicitly() async {
        let (store, _, request) = await setup()
        var count = 0
        let controller = CommandController(store: store, approval: { _, _, _, _ in count += 1; return 1 })
        let first = await controller.approve(request, caller: ("pid:start", "/demo/codex"), isCurrentPeer: { true })
        XCTAssertNotNil(first.credentials)
        var otherCommand = request
        otherCommand.arguments = ["/bin/ls", "/var/log"]
        _ = await controller.approve(otherCommand, caller: ("pid:start", "/demo/codex"), isCurrentPeer: { true })
        XCTAssertEqual(count, 1)
        _ = await controller.approve(request, caller: ("pid:other", "/demo/codex"), isCurrentPeer: { true })
        XCTAssertEqual(count, 2)
        controller.revoke()
        _ = await controller.approve(request, caller: ("pid:start", "/demo/codex"), isCurrentPeer: { true })
        XCTAssertEqual(count, 3)
        Prefs.shared.commandAccessEnabled = false
    }
}

private final class CommandMemoryStorage: VaultStorage {
    private var data: Data?
    func read() throws -> Data? { data }
    func create(_ data: Data) throws { self.data = data }
    func update(_ data: Data) throws { self.data = data }
}
