import XCTest
@testable import WardCore

/// Ключи и сертификаты создаются заново системными `ssh-keygen` и `openssl` — в репозитории нет ни одного ключа,
/// а отпечатки сверяются с тем, что считают сами эти утилиты.
final class KeyMaterialTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ward-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("\(tool) недоступен: \(process.terminationStatus)") }
        return String(decoding: data, as: UTF8.self)
    }

    private func sshKeygen(type: String, bits: Int? = nil, passphrase: String = "", name: String) throws -> (private: String, public: String, fingerprint: String) {
        var args = ["-q", "-t", type, "-N", passphrase, "-C", "test@ward", "-f", name]
        if let bits { args += ["-b", String(bits)] }
        try run("/usr/bin/ssh-keygen", args)
        let fingerprint = try run("/usr/bin/ssh-keygen", ["-lf", name + ".pub"]).split(separator: " ")[1]
        return (try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
                try String(contentsOf: dir.appendingPathComponent(name + ".pub"), encoding: .utf8),
                String(fingerprint))
    }

    // MARK: - SSH

    func testEd25519MatchesSshKeygen() throws {
        let key = try sshKeygen(type: "ed25519", name: "ed")
        let pub = try XCTUnwrap(SSHKeyParser.publicKey(key.public))
        XCTAssertEqual(pub.fingerprint, key.fingerprint)
        XCTAssertEqual(pub.label, "Ed25519")
        XCTAssertEqual(pub.comment, "test@ward")
        XCTAssertNil(pub.weakness)

        let info = try XCTUnwrap(SSHKeyParser.privateKey(key.private))
        XCTAssertEqual(info.format, "OpenSSH")
        XCTAssertFalse(info.encrypted)
        XCTAssertEqual(info.publicKey?.blob, pub.blob, "публичный ключ достаётся из приватного")
    }

    func testEncryptedKeyStillGivesPublicPart() throws {
        let key = try sshKeygen(type: "ed25519", passphrase: "фраза-пароль", name: "enc")
        let info = try XCTUnwrap(SSHKeyParser.privateKey(key.private))
        XCTAssertTrue(info.encrypted)
        XCTAssertEqual(info.publicKey?.fingerprint, key.fingerprint)
    }

    func testRSAAndECDSALabelsAndWeakness() throws {
        let rsa = try sshKeygen(type: "rsa", bits: 3072, name: "rsa")
        let rsaKey = try XCTUnwrap(SSHKeyParser.publicKey(rsa.public))
        XCTAssertEqual(rsaKey.label, "RSA 3072")
        XCTAssertEqual(rsaKey.fingerprint, rsa.fingerprint)
        XCTAssertNil(rsaKey.weakness)

        let ecdsa = try sshKeygen(type: "ecdsa", bits: 384, name: "ec")
        XCTAssertEqual(SSHKeyParser.publicKey(ecdsa.public)?.label, "ECDSA P-384")

        try run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-f", "pem"])
        let pem = try String(contentsOf: dir.appendingPathComponent("pem"), encoding: .utf8)
        XCTAssertEqual(SSHKeyParser.privateKey(pem)?.format, "PEM")
        XCTAssertEqual(SSHKeyParser.privateKey(pem)?.encrypted, false)
    }

    func testShortRSAIsWeak() throws {
        // ssh-keygen не создаёт RSA короче 1024, а новые версии — короче 2048; blob собираем руками.
        func string(_ bytes: [UInt8]) -> [UInt8] {
            let n = UInt32(bytes.count)
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + bytes
        }
        let modulus = [UInt8(0)] + [UInt8(0x80)] + [UInt8](repeating: 1, count: 127)
        let blob = Data(string(Array("ssh-rsa".utf8)) + string([1, 0, 1]) + string(modulus))
        let key = try XCTUnwrap(SSHKeyParser.publicKey("ssh-rsa \(blob.base64EncodedString())"))
        XCTAssertEqual(key.rsaBits, 1024)
        XCTAssertNotNil(key.weakness)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(SSHKeyParser.publicKey("ssh-ed25519 не-base64"))
        XCTAssertNil(SSHKeyParser.publicKey("ssh-rsa " + Data("ssh-ed25519".utf8).base64EncodedString()))
        XCTAssertNil(SSHKeyParser.privateKey("просто текст"))
        XCTAssertNil(SSHKeyParser.privateKey("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"))
    }

    func testPuTTYKey() throws {
        let key = try sshKeygen(type: "ed25519", name: "pt")
        let pub = try XCTUnwrap(SSHKeyParser.publicKey(key.public))
        let b64 = pub.blob.base64EncodedString()
        let ppk = """
        PuTTY-User-Key-File-3: ssh-ed25519
        Encryption: none
        Comment: test
        Public-Lines: 1
        \(b64)
        Private-Lines: 1
        AAAA
        Private-MAC: 00
        """
        let info = try XCTUnwrap(SSHKeyParser.privateKey(ppk))
        XCTAssertEqual(info.format, "PuTTY")
        XCTAssertFalse(info.encrypted)
        XCTAssertEqual(info.publicKey?.fingerprint, key.fingerprint)
    }

    // MARK: - Сертификаты

    private func makeCertificate(days: Int, name: String) throws -> (cert: String, key: String, sha256: String) {
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", name + ".key",
                                     "-out", name + ".crt", "-days", String(days), "-subj", "/CN=ward.test/O=Ward Tests"])
        let fingerprint = try run("/usr/bin/openssl", ["x509", "-in", name + ".crt", "-noout", "-fingerprint", "-sha256"])
        return (try String(contentsOf: dir.appendingPathComponent(name + ".crt"), encoding: .utf8),
                try String(contentsOf: dir.appendingPathComponent(name + ".key"), encoding: .utf8),
                String(fingerprint.split(separator: "=")[1]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testCertificateInfoMatchesOpenSSL() throws {
        let made = try makeCertificate(days: 365, name: "c")
        let info = try XCTUnwrap(CertificateParser.certificates(in: made.cert).first)
        XCTAssertEqual(info.subject, "ward.test")
        XCTAssertEqual(info.issuer, "ward.test", "самоподписанный")
        XCTAssertEqual(info.sha256, made.sha256)
        let notAfter = try XCTUnwrap(info.notAfter)
        XCTAssertEqual(notAfter.timeIntervalSinceNow, 365 * 86400, accuracy: 3600)
        XCTAssertFalse(info.isExpired())
        XCTAssertFalse(info.expiresSoon())

        let key = try XCTUnwrap(PEM.privateKey(in: made.key))
        XCTAssertFalse(key.encrypted)
    }

    func testDERCertificateIsConvertedAndChainsAreKept() throws {
        let a = try makeCertificate(days: 10, name: "a")
        let b = try makeCertificate(days: 400, name: "b")
        try run("/usr/bin/openssl", ["x509", "-in", "a.crt", "-outform", "DER", "-out", "a.cer"])
        let der = try Data(contentsOf: dir.appendingPathComponent("a.cer"))
        let pem = try XCTUnwrap(CertificateParser.pem(fromFile: der))
        XCTAssertEqual(CertificateParser.certificates(in: pem).first?.sha256, a.sha256)
        XCTAssertNil(CertificateParser.pem(fromFile: Data("не сертификат".utf8)))

        let chain = try XCTUnwrap(CertificateParser.pem(fromFile: Data((a.cert + b.cert).utf8)))
        XCTAssertEqual(CertificateParser.certificates(in: chain).map(\.sha256), [a.sha256, b.sha256])
        XCTAssertTrue(try XCTUnwrap(CertificateParser.certificates(in: chain).first).expiresSoon())
    }

    func testEncryptedPrivateKeyDetected() throws {
        try run("/usr/bin/openssl", ["genrsa", "-out", "plain.key", "2048"])
        try run("/usr/bin/openssl", ["pkcs8", "-topk8", "-in", "plain.key", "-out", "enc.key", "-passout", "pass:secret123", "-v2", "aes256"])
        let enc = try String(contentsOf: dir.appendingPathComponent("enc.key"), encoding: .utf8)
        XCTAssertEqual(PEM.privateKey(in: enc)?.encrypted, true)
        XCTAssertEqual(SSHKeyParser.privateKey(enc)?.encrypted, true)
    }

    func testKeyIssuesSurfaceInEntry() throws {
        var entry = Entry(title: "Сервер")
        XCTAssertNil(entry.keyIssue())
        let soon = try makeCertificate(days: 5, name: "soon")
        entry.certificate = CertificateBundle(certificate: soon.cert, privateKey: soon.key)
        XCTAssertEqual(entry.keyIssue(), "Сертификат скоро истечёт")
        XCTAssertEqual(entry.keyIssue(at: Date().addingTimeInterval(10 * 86400)), "Сертификат истёк")
    }

    func testEntryWithKeysRoundTripsAndOldEntriesDecode() throws {
        var entry = Entry(title: "Сервер")
        entry.url = "10.0.0.5:2222"
        entry.ssh = SSHKey(privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END OPENSSH PRIVATE KEY-----\n",
                           publicKey: "ssh-ed25519 AAAA test", passphrase: "фраза")
        entry.certificate = CertificateBundle(certificate: "cert", privateKey: "key", passphrase: "p", pkcs12: Data([1, 2, 3]))
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.ssh, entry.ssh)
        XCTAssertEqual(decoded.certificate, entry.certificate)

        let old = try JSONDecoder().decode(Entry.self, from: Data(#"{"id":"\#(UUID().uuidString)","title":"Старая"}"#.utf8))
        XCTAssertNil(old.ssh)
        XCTAssertNil(old.certificate)
    }

    // MARK: - Приём из файла и буфера

    func testSSHAbsorbDerivesPublicAndDetectsMismatch() throws {
        let a = try sshKeygen(type: "ed25519", name: "a")
        let b = try sshKeygen(type: "ed25519", name: "b")
        var key = SSHKey()
        XCTAssertEqual(key.absorb(a.private.trimmingCharacters(in: .newlines)), .privateKey)
        XCTAssertTrue(key.privateKey.hasSuffix("\n"), "без перевода строки в конце OpenSSH ключ не читает")
        XCTAssertEqual(key.effectivePublicKey?.fingerprint, a.fingerprint, "публичный извлечён из приватного")
        XCTAssertFalse(key.publicMismatch)

        XCTAssertEqual(key.absorb(a.public), .publicKey)
        XCTAssertEqual(key.effectivePublicKey?.comment, "test@ward", "комментарий из .pub")
        XCTAssertEqual(key.absorb(b.public), .publicKey)
        XCTAssertTrue(key.publicMismatch)
        XCTAssertNil(key.absorb("не ключ"))
    }

    func testCertificateAbsorb() throws {
        let made = try makeCertificate(days: 100, name: "m")
        var bundle = CertificateBundle()
        XCTAssertTrue(bundle.absorb(text: made.cert + made.key))
        XCTAssertEqual(CertificateParser.certificates(in: bundle.certificate).first?.sha256, made.sha256)
        XCTAssertFalse(bundle.privateKey.isEmpty)
        XCTAssertFalse(bundle.privateKeyEncrypted)

        try run("/usr/bin/openssl", ["pkcs12", "-export", "-in", "m.crt", "-inkey", "m.key", "-out", "m.p12", "-passout", "pass:p12pass"])
        let p12 = try Data(contentsOf: dir.appendingPathComponent("m.p12"))
        var fromP12 = CertificateBundle()
        XCTAssertTrue(fromP12.absorb(file: p12, name: "m.p12"))
        XCTAssertEqual(fromP12.pkcs12, p12)

        var fromKeyOnly = CertificateBundle()
        XCTAssertTrue(fromKeyOnly.absorb(file: Data(made.key.utf8), name: "m.key"))
        XCTAssertTrue(fromKeyOnly.certificate.isEmpty)
        var nothing = CertificateBundle()
        XCTAssertFalse(nothing.absorb(file: Data("мусор".utf8), name: "x.txt"))
        XCTAssertTrue(nothing.isEmpty)
    }

    func testWindowsLineEndingsStayReadableByOpenSSL() throws {
        let made = try makeCertificate(days: 100, name: "w")
        let crlf = (made.cert + made.key).replacingOccurrences(of: "\n", with: "\r\n")
        var bundle = CertificateBundle()
        XCTAssertTrue(bundle.absorb(text: crlf))
        XCTAssertFalse(bundle.certificate.contains("\n\n"), "CRLF не должен превращаться в пустые строки")
        try Data(bundle.certificate.utf8).write(to: dir.appendingPathComponent("saved.crt"))
        try Data(bundle.privateKey.utf8).write(to: dir.appendingPathComponent("saved.key"))
        let fingerprint = try run("/usr/bin/openssl", ["x509", "-in", "saved.crt", "-noout", "-fingerprint", "-sha256"])
        XCTAssertTrue(fingerprint.contains(made.sha256), "сохранённый из Ward сертификат читается openssl")
        XCTAssertNoThrow(try run("/usr/bin/openssl", ["pkey", "-in", "saved.key", "-noout"]))

        let ssh = try sshKeygen(type: "ed25519", name: "wk")
        var key = SSHKey()
        XCTAssertEqual(key.absorb(ssh.private.replacingOccurrences(of: "\n", with: "\r\n")), .privateKey)
        XCTAssertFalse(key.privateKey.contains("\r"))
        try Data(key.privateKey.utf8).write(to: dir.appendingPathComponent("wk_saved"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("wk_saved").path)
        XCTAssertEqual(try run("/usr/bin/ssh-keygen", ["-y", "-f", "wk_saved"]).split(separator: " ").prefix(2),
                       ssh.public.split(separator: " ").prefix(2), "сохранённый ключ читается ssh-keygen")

        let pub = try XCTUnwrap(SSHKeyParser.publicKey(ssh.public))
        let ppk = "PuTTY-User-Key-File-3: ssh-ed25519\r\nEncryption: none\r\nPublic-Lines: 1\r\n\(pub.blob.base64EncodedString())\r\n"
        XCTAssertEqual(SSHKeyParser.privateKey(ppk)?.publicKey?.fingerprint, ssh.fingerprint, "PuTTY с CRLF")
    }

    // MARK: - Связанные ключи

    func testLinkedKeysResolveAndSurvivePurge() throws {
        let key = SSHKey(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPOKI3sNSZGj/x1SPrVtk8op1VMPVv+nVgy/V5hQpGhB k")
        var holder = Entry(title: "Ключ deploy")
        holder.ssh = key
        holder.certificate = CertificateBundle(certificate: "cert")
        var server = Entry(title: "Прод")
        server.sshKeyEntryID = holder.id
        server.certificateEntryID = holder.id
        var chained = Entry(title: "Цепочка")
        chained.sshKeyEntryID = server.id
        var vault = Vault(entries: [holder, server, chained])

        XCTAssertEqual(vault.sshKey(for: server)?.key, key)
        XCTAssertEqual(vault.sshKey(for: server)?.source?.id, holder.id)
        XCTAssertEqual(vault.certificate(for: server)?.bundle.certificate, "cert")
        XCTAssertNil(vault.sshKey(for: chained), "связь только на запись со своим ключом, без цепочек")
        XCTAssertEqual(vault.sshKey(for: holder)?.source, nil as Entry?)
        XCTAssertEqual(vault.entriesLinking(to: holder.id).map(\.title), ["Прод"])

        holder.ssh = SSHKey(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPOKI3sNSZGj/x1SPrVtk8op1VMPVv+nVgy/V5hQpGhB new")
        vault.upsert(holder)
        XCTAssertEqual(vault.sshKey(for: vault.entries[1])?.key.publicKey.hasSuffix("new"), true, "замена в одном месте видна везде")

        vault.purge([holder.id])
        XCTAssertEqual(vault.entries.map(\.title), ["Прод", "Цепочка"])
        XCTAssertNil(vault.entries[0].sshKeyEntryID, "связь на удалённую запись снимается")
        XCTAssertNil(vault.entries[0].certificateEntryID)
        XCTAssertEqual(vault.entries[1].sshKeyEntryID, server.id, "чужие связи не трогаются")

        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(server))
        XCTAssertEqual(decoded.sshKeyEntryID, holder.id)
        XCTAssertEqual(decoded.certificateEntryID, holder.id)
    }

    func testLinkedExpiredCertificateIsReported() throws {
        let soon = try makeCertificate(days: 3, name: "linked")
        var holder = Entry(title: "mTLS")
        holder.certificate = CertificateBundle(certificate: soon.cert)
        var server = Entry(title: "API")
        server.certificateEntryID = holder.id
        let vault = Vault(entries: [holder, server])
        XCTAssertNil(server.keyIssue(), "у самой записи сертификата нет")
        XCTAssertEqual(vault.keyIssue(for: server), "Сертификат скоро истечёт", "но взятый по связи — проверяется")
    }

    // MARK: - Адреса

    func testCyrillicDomainsAndBareIPv6() {
        XCTAssertTrue(SiteMatch.matches(pageHost: "xn--e1afmkfd.xn--p1ai", entryHost: "пример.рф"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "вход.пример.рф", entryHost: "xn--e1afmkfd.xn--p1ai"))
        XCTAssertTrue(SiteMatch.matches(pageHost: "ВХОД.пример.рф.", entryHost: "вход.пример.рф"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "xn--e1afmkfd.xn--p1ai", entryHost: "другой.рф"))
        XCTAssertEqual(EntryAddress.parse("2001:db8::1")?.webURL(original: "2001:db8::1")?.absoluteString, "https://[2001:db8::1]")
    }

    func testAddressForms() throws {
        let ip = try XCTUnwrap(EntryAddress.parse("10.0.0.5"))
        XCTAssertEqual(ip.host, "10.0.0.5")
        XCTAssertNil(ip.port)
        XCTAssertTrue(ip.isIP)
        XCTAssertTrue(ip.isWeb)

        let ssh = try XCTUnwrap(EntryAddress.parse("10.0.0.5:22"))
        XCTAssertEqual(ssh.port, 22)
        XCTAssertFalse(ssh.isWeb, "10.0.0.5:22 — не сайт")
        XCTAssertTrue(ssh.looksLikeSSH)
        XCTAssertEqual(ssh.sshCommand(login: "root"), "ssh -- root@10.0.0.5")

        let custom = try XCTUnwrap(EntryAddress.parse("admin@db.internal:2222"))
        XCTAssertEqual(custom.sshCommand(login: "ignored"), "ssh -p 2222 -- admin@db.internal")

        let v6 = try XCTUnwrap(EntryAddress.parse("2001:db8::1"))
        XCTAssertEqual(v6.host, "2001:db8::1")
        XCTAssertNil(v6.port)
        let v6port = try XCTUnwrap(EntryAddress.parse("[2001:db8::1]:8443"))
        XCTAssertEqual(v6port.host, "2001:db8::1")
        XCTAssertEqual(v6port.hostPort, "[2001:db8::1]:8443")
        XCTAssertEqual(v6port.webURL(original: "[2001:db8::1]:8443")?.absoluteString, "https://[2001:db8::1]:8443")

        XCTAssertEqual(EntryAddress.parse("192.168.1.1:8080")?.webURL(original: "192.168.1.1:8080")?.absoluteString,
                       "http://192.168.1.1:8080")
        XCTAssertEqual(EntryAddress.parse("github.com")?.webURL(original: "github.com")?.absoluteString, "https://github.com")
        XCTAssertEqual(EntryAddress.parse("https://a.example.com/login")?.host, "a.example.com")
        XCTAssertEqual(EntryAddress.parse("ssh://git@github.com")?.looksLikeSSH, true)

        XCTAssertNil(EntryAddress.parse("10.0.0.5:99999"))
        XCTAssertNil(EntryAddress.parse("10.0.0.5:abc"))
        XCTAssertNil(EntryAddress.parse("два слова"))
        XCTAssertEqual(EntryAddress.shellQuoted("it's"), "'it'\\''s'")

        var entry = Entry()
        entry.url = "[::1]:22"
        XCTAssertEqual(entry.host, "::1")
        XCTAssertTrue(SiteMatch.matches(pageHost: "::1", entryHost: entry.host!))
    }
}
