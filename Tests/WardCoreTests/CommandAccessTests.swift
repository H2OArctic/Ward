import XCTest
@testable import WardCore

final class CommandAccessTests: XCTestCase {
    func testCommandOutputRedactsPasswordAcrossChunksAndAtTruncation() {
        let output = CommandOutput()
        output.append(Data("before super-".utf8))
        output.append(Data("secret after".utf8))
        XCTAssertEqual(output.text(redacting: "super-secret"), "before <REDACTED> after")
        let clipped = CommandOutput(limit: 12)
        clipped.append(Data("before super-secret".utf8))
        XCTAssertTrue(clipped.truncated)
        XCTAssertEqual(clipped.text(redacting: "super-secret"), "before <REDACTED>")
    }

    func testServerSearchDoesNotIncludePasswordsDeletedOrWebEntries() throws {
        var server = entry()
        var deleted = entry()
        deleted.deletedAt = Date()
        var web = entry()
        web.url = "https://server.example"
        server.environments = ["Production"]
        let matches = CommandServerMatch.find(CommandServerSearch(query: "server"), in: Vault(entries: [server, deleted, web]))
        XCTAssertEqual(matches.map(\.entryID), [server.id])
        let json = String(decoding: try JSONEncoder().encode(matches), as: UTF8.self)
        XCTAssertFalse(json.contains(server.secret))
        XCTAssertFalse(CommandServerSearch(query: "").isValid)
        XCTAssertFalse(CommandServerSearch(query: "server\n").isValid)
    }

    func testServerContextIncludesCompanyProjectTreeServiceAndPersonalGroup() {
        let company = Company(name: "Компания")
        let root = Project(name: "Платформа", space: .work, companyID: company.id)
        let project = Project(name: "Биллинг", space: .work, parentID: root.id, companyID: company.id)
        let service = Service(name: "Хостинг", space: .work, companyID: company.id)
        var server = entry()
        server.space = .work
        server.projectID = project.id
        server.serviceID = service.id
        let vault = Vault(companies: [company], projects: [root, project], services: [service], entries: [server])
        let match = CommandServerMatch.find(CommandServerSearch(query: "Биллинг"), in: vault).first
        XCTAssertEqual(match?.location, "Компания › Платформа › Биллинг · Хостинг")
        XCTAssertEqual(match?.entryID, server.id)
        let group = Project(name: "Дом", space: .personal)
        server.space = .personal
        server.projectID = group.id
        server.serviceID = nil
        let personal = Vault(projects: [group], entries: [server])
        XCTAssertEqual(CommandServerMatch.find(CommandServerSearch(query: "Дом"), in: personal).first?.location, "Дом")
    }
    private func entry() -> Entry {
        var entry = Entry(title: "Server")
        entry.url = "ssh://deploy@server.example:2222"
        entry.secret = "sudo-password"
        return entry
    }

    func testServerSearchIncludesSSHEntryWithoutPassword() throws {
        var server = entry()
        server.url = "ssh://deploy@84.32.34.95"
        server.secret = ""
        let matches = CommandServerMatch.find(CommandServerSearch(query: "84.32.34.95"), in: Vault(entries: [server]))
        XCTAssertEqual(matches.map(\.entryID), [server.id])
        let credentials = try XCTUnwrap(SudoCredentials(entry: server))
        let command = credentials.sshArguments(for: SudoRequest(entryID: server.id, arguments: ["id"]), prompt: "marker").last!
        XCTAssertTrue(command.hasPrefix("sudo -k -n -- "))
        XCTAssertFalse(command.contains("marker"))
    }

    func testLegacySecurityKeepsCommandAccessDisabled() throws {
        let settings = try JSONDecoder().decode(SecuritySettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.commandAccessEnabled)
        XCTAssertEqual(settings.commandApprovalMinutes, 15)
        var enabled = settings
        enabled.commandAccessEnabled = true
        enabled.commandApprovalMinutes = 60
        XCTAssertEqual(try JSONDecoder().decode(SecuritySettings.self, from: JSONEncoder().encode(enabled)), enabled)
    }

    func testPasswordlessRemoteCommandExecutesOrFailsWithoutReadingPassword() throws {
        let payload = "a'; echo unexpected; echo '"
        let request = SudoRequest(entryID: UUID(), arguments: ["/usr/bin/printf", "%s", payload])
        for requiresPassword in [false, true] {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", """
            sudo() {
                [ "$1" = '-k' ] && shift
                [ "$1" = '-n' ] || return 99
                shift
                [ "$1" = '--' ] || return 98
                shift
                if [ "$REQUIRES_PASSWORD" = 'yes' ]; then
                    printf 'sudo: a password is required\\n' >&2
                    return 1
                fi
                "$@"
            }
            """ + "\n" + request.remoteCommand(prompt: "marker", passwordless: true)]
            shell.environment = ["REQUIRES_PASSWORD": requiresPassword ? "yes" : "no"]
            shell.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let errors = Pipe()
            shell.standardOutput = output
            shell.standardError = errors
            try shell.run()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, requiresPassword ? 1 : 0)
            XCTAssertEqual(String(decoding: stdout, as: UTF8.self), requiresPassword ? "" : payload)
            XCTAssertEqual(String(decoding: stderr, as: UTF8.self), requiresPassword ? "sudo: a password is required\n" : "")
        }
    }

    func testCredentialsRejectDeletedInvalidAndMultilineEntries() throws {
        let good = entry()
        let credentials = try XCTUnwrap(SudoCredentials(entry: good))
        XCTAssertEqual(credentials.host, "server.example")
        XCTAssertEqual(credentials.login, "deploy")
        XCTAssertEqual(credentials.port, 2222)
        for address in ["https://example.com", "ssh://-bad@example.com", "ssh://user@-bad", "ssh://user@bad%20host"] {
            var bad = good
            bad.url = address
            XCTAssertNil(SudoCredentials(entry: bad), address)
        }
        for password in ["a\nb", "a\rb", "a\0b"] {
            var bad = good
            bad.secret = password
            XCTAssertNil(SudoCredentials(entry: bad))
        }
        var deleted = good
        deleted.deletedAt = Date()
        XCTAssertNil(SudoCredentials(entry: deleted))
    }

    func testSSHArgumentsNeverContainPasswordAndKeepVerificationEnabled() throws {
        let credentials = try XCTUnwrap(SudoCredentials(entry: entry()))
        let request = SudoRequest(entryID: UUID(), arguments: ["printf", "%s", "a'; touch /tmp/evil; echo '"])
        let args = credentials.sshArguments(for: request, prompt: "PROMPT")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ForwardAgent=no"))
        XCTAssertFalse(args.joined().contains(credentials.password))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "set -- " + request.arguments.map(SudoRequest.quote).joined(separator: " ") + "; printf '%s' \"$3\""]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), request.arguments[2])
        XCTAssertTrue(request.remoteCommand(prompt: "PROMPT").contains("</dev/null"))
        XCTAssertFalse(SudoRequest(entryID: UUID(), arguments: []).isValid)
        XCTAssertFalse(SudoRequest(entryID: UUID(), arguments: ["x\0y"]).isValid)
    }

    func testGrantsAreBoundToEntryProcessAndCredentialsAndExpire() throws {
        let entry = entry()
        let credentials = try XCTUnwrap(SudoCredentials(entry: entry))
        let now = Date(timeIntervalSince1970: 100)
        var grants = CommandGrants()
        grants.allow(entryID: entry.id, identity: "pid:start", credentials: credentials, minutes: 5, now: now)
        XCTAssertTrue(grants.permits(entryID: entry.id, identity: "pid:start", credentials: credentials, now: now))
        XCTAssertFalse(grants.permits(entryID: UUID(), identity: "pid:start", credentials: credentials, now: now))
        XCTAssertFalse(grants.permits(entryID: entry.id, identity: "pid:reused", credentials: credentials, now: now))
        var changed = credentials
        changed.password = "changed"
        XCTAssertFalse(grants.permits(entryID: entry.id, identity: "pid:start", credentials: changed, now: now))
        XCTAssertFalse(grants.permits(entryID: entry.id, identity: "pid:start", credentials: credentials, now: now.addingTimeInterval(300)))
        grants.allow(entryID: entry.id, identity: "pid:start", credentials: credentials, minutes: 0, now: now)
        XCTAssertFalse(grants.permits(entryID: entry.id, identity: "pid:start", credentials: credentials, now: now))
        grants.allow(entryID: entry.id, identity: "pid:start", credentials: credentials, minutes: 500, now: now)
        XCTAssertFalse(grants.permits(entryID: entry.id, identity: "pid:start", credentials: credentials, now: now.addingTimeInterval(3600)))
        grants.allow(entryID: entry.id, identity: "pid:start", credentials: credentials, minutes: 5, now: now)
        grants.revokeAll()
        XCTAssertFalse(grants.permits(entryID: entry.id, identity: "pid:start", credentials: credentials, now: now))
    }

    func testSudoPromptIsDetectedAcrossEveryChunkBoundaryWithoutLeakingIt() {
        let marker = "__WARD_PROMPT__"
        let input = Data(("ошибка\n" + marker + "после\n" + marker).utf8)
        for split in 0...input.count {
            var filter = SudoPromptFilter(marker: marker)
            let first = filter.consume(input.prefix(split))
            let second = filter.consume(input.dropFirst(split), end: true)
            XCTAssertEqual(first.output + second.output, Data("ошибка\nпосле\n".utf8))
            XCTAssertEqual(first.prompts + second.prompts, 2)
        }
        var filter = SudoPromptFilter(marker: marker)
        XCTAssertEqual(filter.consume(Data("ordinary error".utf8), end: true).prompts, 0)
        XCTAssertTrue(filter.consume(Data(), end: true).output.isEmpty)
    }
}
