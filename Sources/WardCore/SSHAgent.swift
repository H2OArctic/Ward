import Foundation
import Darwin
import Security

/// Кто просит ключ: процесс на другом конце сокета.
public struct SSHAgentClient: Sendable, Equatable {
    public let pid: pid_t
    public var executable: String?
    public let parentExecutable: String?
    public var parentPID: pid_t = 0
    /// Время запуска родителя: PID могут переиспользовать, а пара «PID + время запуска» уникальна.
    public var parentStart: UInt64 = 0
    /// Запрос пришёл с удалённого сервера через проброс агента (ssh -A) — такие всегда подтверждаются.
    public var isForwarded = false
    public var signing: CodeSigning = .unverified
    /// Подпись родителя (проверяется по PID — для имени в окне, а не для решения).
    public var parentSigning: CodeSigning = .unverified

    /// Оболочки и то, что их запускает: из такого родителя ssh может вызвать любая команда в этом окне терминала.
    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "tcsh", "csh", "fish", "nu", "xonsh",
                                      "login", "tmux", "screen", "launchd", "sudo", "env"]

    public enum CodeSigning: Sendable, Equatable {
        /// Программа из macOS или Xcode (`anchor apple`) — как /usr/bin/ssh и git из Command Line Tools.
        case apple
        /// Подпись есть, но не Apple (Homebrew, сторонние программы) или её нет вовсе.
        case notApple
        /// Проверить не удалось: например, процесс успел заменить себя другой программой (exec) после подключения.
        case unverified
    }

    public init(pid: pid_t, executable: String?, parentExecutable: String?) {
        self.pid = pid
        self.executable = executable
        self.parentExecutable = parentExecutable
    }

    /// Для «разрешить на 10 минут»: та же программа, запущенная тем же экземпляром родителя-программы (тот же
    /// git rebase, тот же rsync). Родитель-оболочка не годится: `exec /usr/bin/ssh` из любой команды, запущенной
    /// в этом окне терминала, выглядел бы точно так же. `nil` — запоминать нельзя, каждый запрос подтверждается.
    public var approvalIdentity: String? {
        guard pid > 0, parentPID > 1, parentStart > 0, !isForwarded, signing != .unverified, let executable,
              let parent = parentExecutable, !Self.shells.contains((parent as NSString).lastPathComponent) else { return nil }
        return "\(executable)|\(parentPID)|\(parentStart)"
    }

    /// «ssh», «ssh из git» — родитель-оболочка (zsh, bash…) не интересен. Короткое имя — только у программ Apple:
    /// иначе «/tmp/x/ssh» выглядел бы в окне подтверждения как настоящий ssh.
    public var displayName: String {
        guard signing == .apple else {
            let path = executable ?? "процесс \(pid)"
            return path + (signing == .notApple ? " (без подписи Apple)" : " (подпись не проверена)")
        }
        let name = executable.map { ($0 as NSString).lastPathComponent } ?? "процесс \(pid)"
        guard let parentPath = parentExecutable else { return name }
        let parent = (parentPath as NSString).lastPathComponent
        guard !Self.shells.contains(parent), parent != name else { return name }
        // Родитель по имени «git» может оказаться любой программой — короткое имя только у подписанных Apple.
        return "\(name) из \(parentSigning == .apple ? parent : parentPath)"
    }

    /// Подпись процесса по PID. Для родителя audit token не узнать; PID мог смениться — поэтому только для показа.
    static func signing(pid: pid_t) -> CodeSigning {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return .unverified }
        return check(code)
    }

    private static func check(_ code: SecCode) -> CodeSigning {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return .unverified }
        switch SecCodeCheckValidity(code, [], requirement) {
        case errSecSuccess: return .apple
        case errSecCSReqFailed, errSecCSUnsigned: return .notApple
        default: return .unverified
        }
    }

    /// Подпись проверяется по audit token соединения, а не по PID: токен указывает на ту самую программу,
    /// которая подключилась, и перестаёт действовать, если процесс после подключения выполнил exec.
    static func signing(auditToken: audit_token_t) -> (CodeSigning, path: String?) {
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return (.unverified, nil) }
        var staticCode: SecStaticCode?
        var url: CFURL?
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            SecCodeCopyPath(staticCode, [], &url)
        }
        return (check(code), (url as URL?)?.path)
    }

    static func describe(pid: pid_t, auditToken: audit_token_t? = nil) -> SSHAgentClient {
        guard pid > 0 else { return SSHAgentClient(pid: 0, executable: nil, parentExecutable: nil) }
        func path(_ pid: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            return length > 0 ? String(cString: buffer) : nil
        }
        func info(_ pid: pid_t) -> proc_bsdinfo? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
        }
        let parent = info(pid).map { pid_t($0.pbi_ppid) } ?? 0
        var client = SSHAgentClient(pid: pid, executable: path(pid), parentExecutable: parent > 1 ? path(parent) : nil)
        if parent > 1, let parentInfo = info(parent) {
            client.parentPID = parent
            client.parentStart = parentInfo.pbi_start_tvsec &* 1_000_000 &+ parentInfo.pbi_start_tvusec
            client.parentSigning = signing(pid: parent)
        }
        if let auditToken {
            let (signing, signedPath) = Self.signing(auditToken: auditToken)
            client.signing = signing
            // Путь из подписи — той самой программы, что подключилась; путь по PID мог уже смениться.
            if let signedPath { client.executable = signedPath }
        }
        return client
    }
}

public struct SSHAgentIdentity: Sendable {
    public let blob: Data
    public let comment: String

    public init(blob: Data, comment: String) {
        self.blob = blob
        self.comment = comment
    }
}

/// Приложение решает, какие ключи показать и подписывать ли (спросить человека, разблокировать хранилище).
/// Вызывается с потоков соединений — может блокироваться, пока человек отвечает.
public protocol SSHAgentBackend: AnyObject {
    func identities(for client: SSHAgentClient) -> [SSHAgentIdentity]
    /// Подпись в формате SSH или `nil` — отказ.
    func sign(blob: Data, data: Data, flags: UInt32, client: SSHAgentClient) -> Data?
}

/// Что именно подписывается — для окна подтверждения.
public enum SSHAgentRequest {
    /// «вход как deploy», «подпись коммита git».
    public static func describe(_ data: Data) -> String? {
        let bytes = Array(data)
        if bytes.starts(with: Array("SSHSIG".utf8)) {
            var r = SSHReader(bytes.dropFirst(6))
            guard let namespace = r.string().map(shown) else { return "подпись" }
            return namespace == "git" ? "подпись коммита git" : "подпись «\(namespace)»"
        }
        // SSH_MSG_USERAUTH_REQUEST: string session_id, byte 50, string user, string service, string method…
        var r = SSHReader(bytes)
        guard r.string() != nil, let type = r.byte(), type == 50, let user = r.string() else { return nil }
        return "вход как \(shown(user))"
    }

    /// Текст пишет сам клиент: без управляющих символов и переводов строк он не нарисует в окне свою «легенду».
    static func shown(_ bytes: Data) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }))
        return clean.count > 64 ? String(clean.prefix(64)) + "…" : clean
    }
}

/// SSH-агент на unix-сокете (draft-miller-ssh-agent): список ключей и подпись. Добавлять и удалять ключи
/// через `ssh-add` нельзя — ключи живут только в хранилище Ward.
public final class SSHAgentServer: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case pathTooLong
        case notASocket(String)
        case alreadyRunning
        case system(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .pathTooLong: return "Слишком длинный путь к сокету"
            case .notASocket(let path): return "\(path) уже существует и это не сокет"
            case .alreadyRunning: return "Сокет уже занят другим агентом (запущен второй Ward?)"
            case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    static let failure: UInt8 = 5
    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14
    static let extensionRequest: UInt8 = 27
    /// Одновременных соединений — с запасом для живых ssh-сессий, но не бесконечно.
    static let maxConnections = 64
    /// Как AGENT_MAX_LEN в OpenSSH: больше — не от честного клиента.
    static let maxMessage = 256 * 1024

    public let socketPath: String
    private let backend: SSHAgentBackend
    private var source: DispatchSourceRead?
    private var stopped: DispatchSemaphore?
    private var connections = 0
    private let lock = NSLock()

    public init(socketPath: String, backend: SSHAgentBackend) {
        self.socketPath = socketPath
        self.backend = backend
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
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path + [0]) }

        // Старый сокет от прошлого запуска удаляем, но только если это сокет и его никто не слушает.
        var info = stat()
        if lstat(socketPath, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw Failure.notASocket(socketPath) }
            if Self.isListening(address) { throw Failure.alreadyRunning }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("bind", code)
        }
        chmod(socketPath, 0o600)
        // Удалять при остановке будем только свой сокет: вдруг путь уже занял новый запуск.
        var boundInfo = stat()
        lstat(socketPath, &boundInfo)
        let identity = (boundInfo.st_dev, boundInfo.st_ino)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(socketPath)
            throw Failure.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "ward.ssh-agent.accept"))
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

    /// Синхронно: после возврата сокет закрыт и удалён — сразу за этим можно снова `start()`.
    public func stop() {
        lock.lock()
        let source = self.source, stopped = self.stopped
        self.source = nil
        self.stopped = nil
        lock.unlock()
        guard let source else { return }
        source.cancel()
        _ = stopped?.wait(timeout: .now() + 2)
    }

    deinit { stop() }

    private static func isListening(_ address: sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                // Кончились дескрипторы: слушающий сокет остаётся «готовым», и источник крутился бы вхолостую.
                if errno == EMFILE || errno == ENFILE, let source = currentSource() {
                    source.suspend()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { source.resume() }
                }
                return
            }
            lock.lock()
            let accepted = connections < Self.maxConnections
            if accepted { connections += 1 }
            lock.unlock()
            guard accepted else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            // Иначе запись в сокет, который клиент уже закрыл, убила бы весь Ward сигналом SIGPIPE.
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // Молчащее соединение не держит поток вечно (ssh закрывает своё сразу после входа).
            var idle = timeval(tv_sec: 600, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))
            // Отдельный поток: соединение может ждать ответа человека.
            let thread = Thread { [weak self, backend] in
                Self.serve(client, backend: backend)
                guard let self else { return }
                self.lock.lock()
                self.connections -= 1
                self.lock.unlock()
            }
            thread.name = "ward.ssh-agent.connection"
            thread.start()
        }
    }

    private func currentSource() -> DispatchSourceRead? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }

    private static func serve(_ fd: Int32, backend: SSHAgentBackend) {
        defer { close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        // Только процессы этого же пользователя (права на сокет — вторая линия защиты).
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let hasToken = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0
        var client = SSHAgentClient.describe(pid: pid, auditToken: hasToken ? token : nil)

        while let header = readExactly(fd, 4) {
            let size = header.reduce(0) { $0 << 8 | Int($1) }
            guard size >= 1, size <= maxMessage, let message = readExactly(fd, size) else { return }
            let reply = respond(to: message, client: &client, backend: backend)
            let count = UInt32(reply.count)
            let framed = [UInt8(count >> 24), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)] + reply
            guard writeAll(fd, framed) else { return }
        }
    }

    static func respond(to message: [UInt8], client: inout SSHAgentClient, backend: SSHAgentBackend) -> [UInt8] {
        guard let type = message.first else { return [failure] }
        var r = SSHReader(message.dropFirst())
        switch type {
        case requestIdentities:
            let identities = backend.identities(for: client)
            var w = SSHWriter()
            w.byte(identitiesAnswer)
            w.uint32(UInt32(identities.count))
            for identity in identities {
                w.string(identity.blob)
                w.string(identity.comment)
            }
            return Array(w.data)
        case signRequest:
            guard let blob = r.string(), let data = r.string() else { return [failure] }
            let flags = r.uint32() ?? 0
            guard let signature = backend.sign(blob: blob, data: data, flags: flags, client: client) else { return [failure] }
            var w = SSHWriter()
            w.byte(signResponse)
            w.string(signature)
            return Array(w.data)
        case extensionRequest:
            // session-bind@openssh.com: ssh сообщает, куда подключается и не проброс ли это (ssh -A).
            // Признак проброса — навсегда для соединения: удалённая сторона может прислать свой bind, но снять его не может.
            if let name = r.string(), String(decoding: name, as: UTF8.self) == "session-bind@openssh.com",
               r.string() != nil, r.string() != nil, r.string() != nil, let forwarding = r.byte(), forwarding != 0 {
                client.isForwarded = true
            }
            // Ограничения по хостам Ward не поддерживает — честно отвечаем «нет», ssh продолжает без них.
            return [failure]
        default:
            // Добавление, удаление и блокировка ключей в агенте — не поддерживаются: ключи живут в хранилище.
            return [failure]
        }
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
