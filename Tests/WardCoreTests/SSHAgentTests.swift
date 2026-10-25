import XCTest
@testable import WardCore

/// Ключи создаются системным `ssh-keygen`, подписи проверяются им же — независимая сверка с OpenSSH.
final class SSHAgentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // Короткий путь: у unix-сокета ограничение ~104 байта, а временная папка macOS длинная.
        dir = URL(fileURLWithPath: "/tmp/ward-agent-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], env: [String: String] = [:], input: Data? = nil,
                     expectSuccess: Bool = true) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment
        environment.merge(env) { $1 }
        process.environment = environment
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
        if expectSuccess {
            XCTAssertEqual(result.0, 0, "\(tool) \(args.joined(separator: " ")): \(result.2)")
        }
        return result
    }

    private func keygen(_ name: String, type: String, bits: Int? = nil, passphrase: String = "",
                        extra: [String] = []) throws -> (privateKey: String, publicBlob: Data) {
        var args = ["-q", "-t", type, "-N", passphrase, "-C", name, "-f", name] + extra
        if let bits { args += ["-b", String(bits)] }
        try run("/usr/bin/ssh-keygen", args)
        let pub = try String(contentsOf: dir.appendingPathComponent(name + ".pub"), encoding: .utf8)
        let blob = try XCTUnwrap(SSHKeyParser.publicKey(pub)?.blob)
        return (try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8), blob)
    }

    // MARK: - Загрузка ключей

    func testLoadsEveryOpenSSHKeyTypePlainAndEncrypted() throws {
        let cases: [(String, Int?)] = [("ed25519", nil), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521), ("rsa", 2048), ("rsa", 3072)]
        for (type, bits) in cases {
            let plain = try keygen("plain-\(type)\(bits ?? 0)", type: type, bits: bits)
            XCTAssertEqual(try SSHPrivateKeyLoader.load(plain.privateKey, passphrase: "").publicBlob, plain.publicBlob, "\(type) \(bits ?? 0)")

            // Стандартные 16 раундов bcrypt — у Ed25519; остальным хватает 4, чтобы тест не шёл минутами.
            let enc = try keygen("enc-\(type)\(bits ?? 0)", type: type, bits: bits, passphrase: "фраза пароль",
                                 extra: type == "ed25519" ? [] : ["-a", "4"])
            XCTAssertThrowsError(try SSHPrivateKeyLoader.load(enc.privateKey, passphrase: "")) {
                XCTAssertEqual($0 as? SSHSigningKey.Failure, .needsPassphrase)
            }
            XCTAssertThrowsError(try SSHPrivateKeyLoader.load(enc.privateKey, passphrase: "не та")) {
                XCTAssertEqual($0 as? SSHSigningKey.Failure, .wrongPassphrase)
            }
            XCTAssertEqual(try SSHPrivateKeyLoader.load(enc.privateKey, passphrase: "фраза пароль").publicBlob, enc.publicBlob,
                           "bcrypt_pbkdf + aes256-ctr: \(type) \(bits ?? 0)")
        }
    }

    func testOtherCiphers() throws {
        for cipher in ["aes128-ctr", "aes256-cbc", "aes256-gcm@openssh.com"] {
            let key = try keygen("c-\(cipher.prefix(10))", type: "ed25519", passphrase: "secret", extra: ["-Z", cipher, "-a", "4"])
            XCTAssertEqual(try SSHPrivateKeyLoader.load(key.privateKey, passphrase: "secret").publicBlob, key.publicBlob, cipher)
            XCTAssertThrowsError(try SSHPrivateKeyLoader.load(key.privateKey, passphrase: "wrong"), cipher)
        }
        let chacha = try keygen("chacha", type: "ed25519", passphrase: "secret", extra: ["-Z", "chacha20-poly1305@openssh.com"])
        XCTAssertThrowsError(try SSHPrivateKeyLoader.load(chacha.privateKey, passphrase: "secret")) {
            guard case .unsupported = $0 as? SSHSigningKey.Failure else { return XCTFail("\($0)") }
        }
    }

    func testPEMFormats() throws {
        for (type, bits, format) in [("rsa", 2048, "PEM"), ("ecdsa", 256, "PEM"), ("ecdsa", 384, "PKCS8"), ("rsa", 2048, "PKCS8")] {
            let key = try keygen("pem-\(type)-\(format)", type: type, bits: bits, extra: ["-m", format])
            XCTAssertEqual(try SSHPrivateKeyLoader.load(key.privateKey, passphrase: "").publicBlob, key.publicBlob, "\(type) \(format)")
        }
        // Системный LibreSSL не умеет Ed25519 — нужен OpenSSL из Homebrew.
        guard let openssl = ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        try run(openssl, ["genpkey", "-algorithm", "ed25519", "-out", "ed.pem"])
        let pem = try String(contentsOf: dir.appendingPathComponent("ed.pem"), encoding: .utf8)
        let loaded = try SSHPrivateKeyLoader.load(pem, passphrase: "")
        // Открытый ключ Ed25519 — последние 32 байта SubjectPublicKeyInfo.
        try run(openssl, ["pkey", "-in", "ed.pem", "-pubout", "-outform", "DER", "-out", "ed.pub.der"])
        let spki = try Data(contentsOf: dir.appendingPathComponent("ed.pub.der"))
        XCTAssertEqual(loaded.publicBlob.suffix(32), spki.suffix(32), "Ed25519 из PKCS#8 (openssl)")
    }

    // MARK: - Агент целиком, против настоящего OpenSSH

    private final class TestBackend: SSHAgentBackend {
        var keys: [SSHSigningKey] = []
        var allow = true
        private(set) var requests: [(client: SSHAgentClient, description: String?)] = []
        private let lock = NSLock()

        func identities(for client: SSHAgentClient) -> [SSHAgentIdentity] {
            keys.map { SSHAgentIdentity(blob: $0.publicBlob, comment: "Ward: \($0.type)") }
        }

        func sign(blob: Data, data: Data, flags: UInt32, client: SSHAgentClient) -> Data? {
            lock.lock()
            requests.append((client, SSHAgentRequest.describe(data)))
            lock.unlock()
            guard allow, let key = keys.first(where: { $0.publicBlob == blob }) else { return nil }
            return try? key.sign(data, flags: flags)
        }
    }

    func testAgentWorksWithOpenSSH() throws {
        let backend = TestBackend()
        var pubs: [String] = []
        for (type, bits) in [("ed25519", nil), ("ecdsa", 256), ("ecdsa", 521), ("rsa", 3072)] as [(String, Int?)] {
            let name = "agent-\(type)\(bits ?? 0)"
            let key = try keygen(name, type: type, bits: bits)
            backend.keys.append(try SSHPrivateKeyLoader.load(key.privateKey, passphrase: ""))
            pubs.append(name + ".pub")
            // Приватных файлов рядом быть не должно — ssh-keygen обязан идти за подписью в агент.
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        let socket = dir.appendingPathComponent("agent.sock").path
        let server = SSHAgentServer(socketPath: socket, backend: backend)
        try server.start()
        defer { server.stop() }
        let env = ["SSH_AUTH_SOCK": socket]

        let listed = try run("/usr/bin/ssh-add", ["-L"], env: env).out
        for pub in pubs {
            let blob = try String(contentsOf: dir.appendingPathComponent(pub), encoding: .utf8).split(separator: " ")[1]
            XCTAssertTrue(listed.contains(blob), "ssh-add -L видит \(pub)")
        }

        let message = Data("сообщение для подписи".utf8)
        try message.write(to: dir.appendingPathComponent("msg.txt"))
        for pub in pubs {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("msg.txt.sig"))
            try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", pub, "-n", "file", "msg.txt"], env: env)
            let sig = try String(contentsOf: dir.appendingPathComponent("msg.txt.sig"), encoding: .utf8)
            XCTAssertEqual(try run("/usr/bin/ssh-keygen", ["-Y", "check-novalidate", "-n", "file", "-s", "msg.txt.sig"],
                                   input: message).status, 0, "подпись \(pub) проверяется OpenSSH: \(sig.prefix(40))")
            XCTAssertEqual(try run("/usr/bin/ssh-add", ["-T", pub], env: env).status, 0, "ssh-add -T \(pub)")
        }
        XCTAssertTrue(backend.requests.contains { $0.description == "подпись «file»" })
        XCTAssertTrue(backend.requests.allSatisfy { $0.client.executable?.hasSuffix("ssh-keygen") == true
            || $0.client.executable?.hasSuffix("ssh-add") == true }, "\(backend.requests.map(\.client))")
        XCTAssertTrue(backend.requests.allSatisfy { $0.client.signing == .apple }, "системный OpenSSH подписан Apple")

        backend.allow = false
        XCTAssertNotEqual(try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", pubs[0], "-n", "file", "msg.txt"],
                                  env: env, expectSuccess: false).status, 0, "отказ — подписи нет")

        let extra = try keygen("extra", type: "ed25519")
        _ = extra
        XCTAssertNotEqual(try run("/usr/bin/ssh-add", ["extra"], env: env, expectSuccess: false).status, 0,
                          "добавлять ключи в агент Ward нельзя")
    }

    /// Своя программа с именем «ssh» не выдаёт себя в окне подтверждения за системный ssh.
    func testUnsignedClientIsShownWithFullPath() throws {
        let clang = "/usr/bin/clang"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: clang), "нет clang")
        let source = """
        #include <string.h>
        #include <sys/socket.h>
        #include <sys/un.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            struct sockaddr_un a = { .sun_family = AF_UNIX };
            strncpy(a.sun_path, argv[1], sizeof(a.sun_path) - 1);
            if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) return 1;
            unsigned char request[] = { 0, 0, 0, 10, 13, 0, 0, 0, 1, 'k', 0, 0, 0, 0 };
            unsigned char reply[5];
            write(fd, request, sizeof(request));
            return read(fd, reply, sizeof(reply)) == 5 ? 0 : 2;
        }
        """
        try source.write(to: dir.appendingPathComponent("client.c"), atomically: true, encoding: .utf8)
        try run(clang, ["-o", "ssh", "client.c"])

        let backend = TestBackend()
        backend.allow = false
        let socket = dir.appendingPathComponent("agent.sock").path
        let server = SSHAgentServer(socketPath: socket, backend: backend)
        try server.start()
        defer { server.stop() }
        try run(dir.appendingPathComponent("ssh").path, [socket])

        let client = try XCTUnwrap(backend.requests.first?.client)
        XCTAssertEqual(client.signing, .notApple)
        XCTAssertTrue(client.displayName.hasSuffix("/\(dir.lastPathComponent)/ssh (без подписи Apple)"), client.displayName)
    }

    func testClientTextCannotDrawItsOwnLegend() {
        var w = SSHWriter()
        w.string(Data(repeating: 1, count: 32))
        w.byte(50)
        w.string("deploy\n\nРазрешено администратором\u{202E}")
        XCTAssertEqual(SSHAgentRequest.describe(w.data), "вход как deployРазрешено администратором")
    }

    func testStaleSocketIsReplacedButLiveOneIsNot() throws {
        let socket = dir.appendingPathComponent("s.sock").path
        let first = SSHAgentServer(socketPath: socket, backend: TestBackend())
        try first.start()
        XCTAssertThrowsError(try SSHAgentServer(socketPath: socket, backend: TestBackend()).start(), "второй агент не крадёт сокет")
        // Остановка синхронная: сразу за ней путь свободен (раньше тест прятал гонку за паузой).
        first.stop()
        let restarted = SSHAgentServer(socketPath: socket, backend: TestBackend())
        try restarted.start()
        restarted.stop()

        FileManager.default.createFile(atPath: socket, contents: Data("не сокет".utf8))
        XCTAssertThrowsError(try SSHAgentServer(socketPath: socket, backend: TestBackend()).start(), "обычный файл не удаляется")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))
        try FileManager.default.removeItem(atPath: socket)

        let second = SSHAgentServer(socketPath: socket, backend: TestBackend())
        try second.start()
        defer { second.stop() }
        let mode = (try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }

    func testStoppingOldServerDoesNotRemoveNewSocket() throws {
        let socket = dir.appendingPathComponent("r.sock").path
        let old = SSHAgentServer(socketPath: socket, backend: TestBackend())
        try old.start()
        old.stop()
        let new = SSHAgentServer(socketPath: socket, backend: TestBackend())
        try new.start()
        defer { new.stop() }
        old.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "повторная остановка старого не трогает новый сокет")
        XCTAssertEqual(try run("/usr/bin/ssh-add", ["-l"], env: ["SSH_AUTH_SOCK": socket], expectSuccess: false).status, 1,
                       "агент отвечает (ключей нет — код 1, а не 2 «нет соединения»)")
    }

    func testForwardingIsStickyAndNeverRemembered() {
        func bind(forwarding: UInt8) -> [UInt8] {
            var w = SSHWriter()
            w.byte(27)
            w.string("session-bind@openssh.com")
            w.string(Data([1, 2, 3]))
            w.string(Data([4, 5, 6]))
            w.string(Data([7, 8, 9]))
            w.byte(forwarding)
            return Array(w.data)
        }
        var client = SSHAgentClient(pid: 4242, executable: "/usr/bin/ssh", parentExecutable: "/usr/bin/git")
        client.parentPID = 4000
        client.parentStart = 1_700_000_000_000_000
        client.signing = .apple
        XCTAssertNotNil(client.approvalIdentity, "опознанный клиент из программы-родителя запоминается")
        let backend = TestBackend()
        XCTAssertEqual(SSHAgentServer.respond(to: bind(forwarding: 0), client: &client, backend: backend), [5])
        XCTAssertFalse(client.isForwarded)
        _ = SSHAgentServer.respond(to: bind(forwarding: 1), client: &client, backend: backend)
        XCTAssertTrue(client.isForwarded)
        _ = SSHAgentServer.respond(to: bind(forwarding: 0), client: &client, backend: backend)
        XCTAssertTrue(client.isForwarded, "удалённая сторона не может снять признак проброса своим bind")
        XCTAssertNil(client.approvalIdentity, "запросы через проброс не запоминаются")
        XCTAssertNil(SSHAgentClient.describe(pid: 0).approvalIdentity, "неопознанный клиент не запоминается")
        XCTAssertNil(SSHAgentClient.describe(pid: getpid()).approvalIdentity, "без проверки подписи не запоминается")
        var fromShell = SSHAgentClient(pid: 4242, executable: "/usr/bin/ssh", parentExecutable: "/bin/zsh")
        fromShell.parentPID = 4000
        fromShell.parentStart = 1_700_000_000_000_000
        fromShell.signing = .apple
        XCTAssertNil(fromShell.approvalIdentity, "из оболочки ssh может вызвать любая команда этого окна — не запоминаем")
        XCTAssertEqual(SSHAgentServer.respond(to: [17], client: &client, backend: backend), [5], "добавить ключ нельзя")
        XCTAssertEqual(SSHAgentServer.respond(to: [], client: &client, backend: backend), [5])
        XCTAssertEqual(SSHAgentServer.respond(to: [13, 0, 0], client: &client, backend: backend), [5], "обрезанный запрос")
    }

    func testAgentReadinessMatchesWhatCanBeSigned() throws {
        let plain = try keygen("r-plain", type: "ed25519")
        XCTAssertEqual(SSHKey(privateKey: plain.privateKey).agentReadiness.blob, plain.publicBlob)

        let pem = try keygen("r-pem", type: "ecdsa", bits: 256, extra: ["-m", "PEM"])
        let pemOnly = SSHKey(privateKey: pem.privateKey)
        XCTAssertEqual(pemOnly.agentReadiness.blob, pem.publicBlob, "PEM без публичной строки тоже отдаётся")

        let encPEM = try keygen("r-encpem", type: "rsa", bits: 2048, passphrase: "secret", extra: ["-m", "PEM"])
        XCTAssertNotNil(SSHKey(privateKey: encPEM.privateKey, passphrase: "secret").agentReadiness.problem,
                        "зашифрованный PEM агент не расшифрует — и не предлагает")

        let enc = try keygen("r-enc", type: "ed25519", passphrase: "secret", extra: ["-a", "4"])
        XCTAssertEqual(SSHKey(privateKey: enc.privateKey).agentReadiness.problem, "нужна фраза-пароль ключа")
        XCTAssertEqual(SSHKey(privateKey: enc.privateKey, passphrase: "secret").agentReadiness.blob, enc.publicBlob)

        let chacha = try keygen("r-chacha", type: "ed25519", passphrase: "secret", extra: ["-Z", "chacha20-poly1305@openssh.com", "-a", "4"])
        XCTAssertNotNil(SSHKey(privateKey: chacha.privateKey, passphrase: "secret").agentReadiness.problem)

        let other = try keygen("r-other", type: "ed25519")
        var mismatched = SSHKey(privateKey: plain.privateKey)
        mismatched.publicKey = try String(contentsOf: dir.appendingPathComponent("r-other.pub"), encoding: .utf8)
        _ = other
        XCTAssertNotNil(mismatched.agentReadiness.problem, "публичный ключ записи не от приватного — не отдаём")
        XCTAssertNotNil(SSHKey(privateKey: "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n").agentReadiness.problem)
    }

    func testRequestDescriptions() {
        var w = SSHWriter()
        w.string(Data(repeating: 1, count: 32))
        w.byte(50)
        w.string("deploy")
        w.string("ssh-connection")
        w.string("publickey")
        XCTAssertEqual(SSHAgentRequest.describe(w.data), "вход как deploy")
        var sig = SSHWriter()
        sig.string("git")
        XCTAssertEqual(SSHAgentRequest.describe(Data("SSHSIG".utf8) + sig.data), "подпись коммита git")
        XCTAssertNil(SSHAgentRequest.describe(Data([1, 2, 3])))
        var fromGit = SSHAgentClient(pid: 1, executable: "/usr/bin/ssh", parentExecutable: "/usr/bin/git")
        fromGit.signing = .apple
        XCTAssertEqual(fromGit.displayName, "ssh из /usr/bin/git", "имя родителя без проверки подписи — полным путём")
        fromGit.parentSigning = .apple
        XCTAssertEqual(fromGit.displayName, "ssh из git")
        var fromShell = SSHAgentClient(pid: 1, executable: "/usr/bin/ssh", parentExecutable: "/bin/zsh")
        fromShell.signing = .apple
        XCTAssertEqual(fromShell.displayName, "ssh")
        XCTAssertEqual(SSHAgentClient(pid: 1, executable: "/usr/bin/ssh", parentExecutable: "/bin/zsh").displayName,
                       "/usr/bin/ssh (подпись не проверена)")
    }

    func testBigUIntMod() {
        let a = BigUInt(bytes: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05])
        // 2^64 + 5 mod 7: 2^64 mod 7 = 2 (2^3 = 1 mod 7, 64 = 3·21 + 1) → 2 + 5 = 7 → 0
        XCTAssertEqual(a.mod(BigUInt(bytes: [7])).bytes, [0])
        XCTAssertEqual(BigUInt(bytes: [0x10, 0x00]).subtractingOne().bytes, [0x0F, 0xFF])
        XCTAssertEqual(BigUInt(bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).mod(BigUInt(bytes: [0x01, 0x00, 0x00, 0x00, 0x00])).bytes, [0xFF, 0xFF, 0xFF, 0xFF])
    }
}
