import Foundation
import Darwin
import Security

/// Unix-сокет, через который помощник браузера (его запускает Chrome по native messaging) говорит с Ward.
/// Каждое соединение сначала проходит `admit` (кто на том конце), затем кадры JSON идут в `handle`;
/// ответы на параллельные запросы пишутся по одному, под замком.
public final class BrowserBridgeServer: @unchecked Sendable {
    public struct Peer: Sendable {
        public let pid: pid_t
        public let auditToken: audit_token_t
    }

    public typealias Handler = @Sendable (_ connection: UUID, _ request: Data, _ reply: @escaping @Sendable (Data) -> Void) -> Void

    public let socketPath: String
    private let admit: @Sendable (Peer) -> Bool
    private let handle: Handler
    private let disconnected: @Sendable (UUID) -> Void
    private let connected: @Sendable (UUID, Peer) -> Void
    private var source: DispatchSourceRead?
    private var stopped: DispatchSemaphore?
    private let lock = NSLock()
    private var connections: [UUID: Int32] = [:]
    public static let maxConnections = 8
    public static let maxPendingRequests = 32

    public init(socketPath: String, admit: @escaping @Sendable (Peer) -> Bool,
                disconnected: @escaping @Sendable (UUID) -> Void = { _ in },
                connected: @escaping @Sendable (UUID, Peer) -> Void = { _, _ in }, handle: @escaping Handler) {
        self.socketPath = socketPath
        self.admit = admit
        self.handle = handle
        self.disconnected = disconnected
        self.connected = connected
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        var address = sockaddr_un()
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SSHAgentServer.Failure.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path + [0]) }

        // Старый сокет прошлого запуска удаляем, только если это сокет.
        var info = stat()
        if lstat(socketPath, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw SSHAgentServer.Failure.notASocket(socketPath) }
            if Self.isListening(address) { throw SSHAgentServer.Failure.alreadyRunning }
            unlink(socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHAgentServer.Failure.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SSHAgentServer.Failure.system("bind", code)
        }
        chmod(socketPath, 0o600)
        var boundInfo = stat()
        lstat(socketPath, &boundInfo)
        let identity = (boundInfo.st_dev, boundInfo.st_ino)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(socketPath)
            throw SSHAgentServer.Failure.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "ward.browser.accept"))
        let stopped = DispatchSemaphore(value: 0)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { [socketPath] in
            close(fd)
            var current = stat()
            if lstat(socketPath, &current) == 0, current.st_dev == identity.0, current.st_ino == identity.1 {
                unlink(socketPath)
            }
            stopped.signal()
        }
        self.source = source
        self.stopped = stopped
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = self.source, stopped = self.stopped
        self.source = nil
        self.stopped = nil
        for client in connections.values { shutdown(client, SHUT_RDWR) }
        lock.unlock()
        guard let source else { return }
        source.cancel()
        _ = stopped?.wait(timeout: .now() + 2)
    }

    deinit { stop() }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let connection = UUID()
            lock.lock()
            let accepted = source != nil && connections.count < Self.maxConnections
            if accepted { connections[connection] = client }
            lock.unlock()
            guard accepted else { close(client); continue }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var idle = timeval(tv_sec: 65, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))
            let thread = Thread { [weak self, admit, disconnected, connected, handle] in
                Self.serve(client, connection: connection, admit: admit, disconnected: disconnected, connected: connected, handle: handle)
                if let self {
                    self.lock.lock()
                    self.connections.removeValue(forKey: connection)
                    close(client)
                    self.lock.unlock()
                } else { close(client) }
            }
            thread.name = "ward.browser.connection"
            thread.start()
        }
    }

    private static func serve(_ fd: Int32, connection: UUID, admit: @Sendable (Peer) -> Bool,
                              disconnected: @Sendable (UUID) -> Void, connected: @Sendable (UUID, Peer) -> Void,
                              handle: @escaping Handler) {
        var notified = false
        defer {
            if !notified { disconnected(connection) }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0,
              admit(Peer(pid: pid, auditToken: token)) else { return }
        connected(connection, Peer(pid: pid, auditToken: token))

        let writeLock = NSLock()
        let pending = DispatchGroup()
        let capacity = Capacity(limit: maxPendingRequests)
        let controlCapacity = Capacity(limit: 4)
        while let header = readExactly(fd, 4), let length = NativeMessaging.length(ofHeader: Data(header)),
              let body = readExactly(fd, length) {
            let object = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
            let budget = object?["type"] as? String == "cancel" ? controlCapacity : capacity
            let accepted = budget.acquire()
            guard accepted else {
                let failure: [String: Any] = ["id": object?["id"] ?? NSNull(), "ok": false, "error": "busy"]
                let data = (try? JSONSerialization.data(withJSONObject: failure)) ?? Data("{}".utf8)
                writeLock.lock()
                _ = writeAll(fd, [UInt8](NativeMessaging.frame(data)))
                writeLock.unlock()
                continue
            }
            pending.enter()
            handle(connection, Data(body)) { response in
                writeLock.lock()
                _ = writeAll(fd, [UInt8](NativeMessaging.frame(response)))
                writeLock.unlock()
                budget.release()
                pending.leave()
            }
        }
        disconnected(connection)
        notified = true
        // Помощник закрыл соединение — ждём уже начатые ответы, чтобы не писать в закрытый дескриптор.
        pending.wait()
    }

    private final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var count = 0

        init(limit: Int) { self.limit = limit }

        func acquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard count < limit else { return false }
            count += 1
            return true
        }

        func release() {
            lock.lock()
            count -= 1
            lock.unlock()
        }
    }

    private static func isListening(_ address: sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = address
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0 || errno != ECONNREFUSED
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            offset += n
        }
        return buffer
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}

/// Кого пускать к мосту: помощника Ward (подпись той же команды, что у самого Ward), запущенного браузером.
public enum BrowserPeerCheck {
    /// Идентификатор подписи помощника браузера (см. build.sh).
    public static let hostIdentifier = WardIdentity.browserHostID
    /// Google Chrome (и его бета/канареечные сборки) — команда Google.
    public static let chromeTeam = "EQHXZ8M8AV"

    /// Команда, которой подписан сам Ward; `nil` — подпись без команды (самоподписанная, ad-hoc):
    /// тогда проверить помощника не по чему, и мост не включается.
    public static func ownTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Помощник на том конце — именно наш: проверка по audit token соединения (не по PID, который могут подменить).
    public static func isOurHost(_ token: audit_token_t, team: String) -> Bool {
        var token = token
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return satisfies(code, "identifier \"\(hostIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
    }

    /// Помощника запустил браузер: родитель подписан командой Chrome. Иначе любой процесс мог бы запустить
    /// помощника сам и получить пароли.
    public static func isLaunchedByBrowser(hostPID: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(hostPID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        let parent = pid_t(info.pbi_ppid)
        guard parent > 1 else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: parent] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return satisfies(code, "anchor apple generic and certificate leaf[subject.OU] = \"\(chromeTeam)\"")
    }

    private static func satisfies(_ code: SecCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
