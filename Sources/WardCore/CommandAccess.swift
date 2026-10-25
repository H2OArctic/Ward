import Foundation
import Darwin
import Security

public struct SudoRequest: Codable, Sendable {
    public var entryID: UUID
    public var arguments: [String]
    public var selectionRequired: Bool?

    public init(entryID: UUID, arguments: [String]) {
        self.entryID = entryID
        self.arguments = arguments
    }

    public var isValid: Bool {
        !arguments.isEmpty && !arguments[0].isEmpty && arguments.count <= 256
            && arguments.reduce(0, { $0 + $1.utf8.count }) <= 32_768
            && arguments.allSatisfy { !$0.contains("\0") }
    }

    public func remoteCommand(prompt: String, passwordless: Bool = false) -> String {
        // Даже при NOPASSWD команда не должна получить строку пароля из stdin.
        let command = ["/bin/sh", "-c", "exec \"$@\" </dev/null", "ward"] + arguments
        let sudo = passwordless ? "sudo -k -n" : "sudo -k -S -p " + Self.quote(prompt)
        return sudo + " -- " + command.map(Self.quote).joined(separator: " ")
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct SudoCredentials: Codable, Equatable, Sendable {
    public var host: String
    public var login: String
    public var port: Int
    public var password: String

    public init?(entry: Entry) {
        guard !entry.isDeleted, entry.authKind == .password, let address = entry.address,
              address.scheme == nil || address.scheme == "ssh",
              entry.secret.utf8.count <= 4096,
              !entry.secret.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
        let login = address.user ?? entry.login
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        guard !login.isEmpty, !login.hasPrefix("-"), !address.host.hasPrefix("-"),
              login.unicodeScalars.allSatisfy({ safe.contains($0) }),
              address.host.unicodeScalars.allSatisfy({ safe.contains($0) }) else { return nil }
        host = address.host
        self.login = login
        port = address.port ?? 22
        password = entry.secret
    }

    public func sshArguments(for request: SudoRequest, prompt: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
         "-o", "ClearAllForwardings=yes", "-p", String(port), "-l", login, "--", host,
         request.remoteCommand(prompt: prompt, passwordless: password.isEmpty)]
    }
}

public struct SudoPromptFilter {
    private let marker: Data
    private var pending = Data()

    public init(marker: String) {
        precondition(!marker.isEmpty)
        self.marker = Data(marker.utf8)
    }

    public mutating func consume(_ data: Data, end: Bool = false) -> (output: Data, prompts: Int) {
        pending.append(data)
        var output = Data()
        var prompts = 0
        while let range = pending.range(of: marker) {
            output.append(pending.prefix(upTo: range.lowerBound))
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            prompts += 1
        }
        var keep = 0
        if !end, !pending.isEmpty, marker.count > 1 {
            for count in 1...min(pending.count, marker.count - 1) {
                if pending.suffix(count) == marker.prefix(count) { keep = count }
            }
        }
        output.append(pending.prefix(pending.count - keep))
        pending = Data(pending.suffix(keep))
        return (output, prompts)
    }
}

public final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var clipped = false

    public init(limit: Int = 65_536) { self.limit = max(0, limit) }

    public var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clipped
    }

    public func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { clipped = true }
    }

    public func text(redacting secret: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        var text = String(decoding: data, as: UTF8.self)
        guard !secret.isEmpty else { return text }
        text = text.replacingOccurrences(of: secret, with: "<REDACTED>")
        if clipped {
            for length in stride(from: min(secret.count - 1, text.count), through: 1, by: -1) {
                if text.hasSuffix(String(secret.prefix(length))) {
                    text.removeLast(length)
                    text += "<REDACTED>"
                    break
                }
            }
        }
        return text
    }
}

public struct CommandResponse: Codable, Sendable {
    public var credentials: SudoCredentials?
    public var selectedEntryID: UUID?
    public var error: String?

    public init(credentials: SudoCredentials? = nil, error: String? = nil) {
        self.credentials = credentials
        self.error = error
    }
}

public struct CommandServerSearch: Codable, Sendable {
    public let type: String
    public var query: String

    public init(query: String) {
        type = "findServer"
        self.query = query
    }

    public var isValid: Bool {
        type == "findServer" && query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            && query.utf8.count <= 256 && !query.contains(where: { $0.isNewline || $0 == "\0" })
    }
}

public struct CommandServerMatch: Codable, Equatable, Sendable {
    public var entryID: UUID
    public var title: String
    public var host: String
    public var login: String
    public var port: Int
    public var environments: [String]
    public var location: String

    public init(entry: Entry, credentials: SudoCredentials, in vault: Vault) {
        entryID = entry.id
        title = entry.title
        host = credentials.host
        login = credentials.login
        port = credentials.port
        environments = entry.environments
        let space = entry.space == .work ? "Работа" : "Личное"
        let path = vault.location(of: entry)
        let company = vault.companies.count == 1 ? vault.company(vault.companyID(of: entry))?.name : nil
        let context = [company, path.isEmpty ? nil : path].compactMap { $0 }.joined(separator: " › ")
        location = context.isEmpty ? space : context
    }

    public static func find(_ request: CommandServerSearch, in vault: Vault) -> [Self] {
        guard request.isValid else { return [] }
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(vault.entries.compactMap { entry -> Self? in
            guard let credentials = SudoCredentials(entry: entry),
                  entry.title.localizedCaseInsensitiveContains(query) || credentials.host.localizedCaseInsensitiveContains(query)
                    || vault.searchContext(of: entry).localizedCaseInsensitiveContains(query) else { return nil }
            return Self(entry: entry, credentials: credentials, in: vault)
        }.sorted { $0.title < $1.title }.prefix(20))
    }
}

public struct CommandGrants {
    private struct Grant {
        var credentials: SudoCredentials
        var expires: Date
    }
    private var grants: [String: Grant] = [:]

    public init() {}

    public mutating func allow(entryID: UUID, identity: String, credentials: SudoCredentials, minutes: Int, now: Date = Date()) {
        guard minutes > 0 else { return }
        grants[key(entryID, identity)] = Grant(credentials: credentials, expires: now.addingTimeInterval(Double(min(minutes, 60)) * 60))
    }

    public mutating func permits(entryID: UUID, identity: String, credentials: SudoCredentials, now: Date = Date()) -> Bool {
        grants = grants.filter { $0.value.expires > now }
        return grants[key(entryID, identity)]?.credentials == credentials
    }

    public mutating func revokeAll() { grants = [:] }

    private func key(_ entryID: UUID, _ identity: String) -> String { entryID.uuidString + "|" + identity }
}

public enum CommandPeerCheck {
    public static let identifier = WardIdentity.commandHelperID

    public static func matches(_ token: audit_token_t, identifier: String, team: String) -> Bool {
        var token = token
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    public static func caller(of pid: pid_t) -> (identity: String, path: String)? {
        var current = pid
        for _ in 0..<12 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
            current = pid_t(info.pbi_ppid)
            var parent = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &parent, size) == size else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(current, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let path = String(cString: buffer)
            let name = (path as NSString).lastPathComponent
            if !SSHAgentClient.shells.contains(name) {
                return ("\(current):\(parent.pbi_start_tvsec):\(parent.pbi_start_tvusec):\(path)", path)
            }
        }
        return nil
    }
}

public enum CommandWire {
    public static let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ward/commands.sock").path

    public static func write(_ data: Data, to fd: Int32) throws {
        let frame = NativeMessaging.frame(data)
        var offset = 0
        while offset < frame.count {
            let count = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, frame.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.connection }
            offset += count
        }
    }

    public static func read(from fd: Int32) throws -> Data {
        func exactly(_ count: Int) throws -> Data {
            var buffer = Data(count: count)
            var offset = 0
            while offset < count {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.connection }
                offset += n
            }
            return buffer
        }
        let header = try exactly(4)
        guard let length = NativeMessaging.length(ofHeader: header) else { throw Failure.connection }
        return try exactly(length)
    }

    public enum Failure: Error { case connection }
}
