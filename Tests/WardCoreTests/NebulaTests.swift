import XCTest
@testable import WardCore

/// Сертификаты создаются настоящим `nebula-cert`, а разбор сверяется с его же `print -json`.
/// Нет nebula-cert (brew install nebula) — тесты пропускаются.
final class NebulaTests: XCTestCase {
    private var dir: URL!
    private var tool: String!

    override func setUpWithError() throws {
        guard let found = ["/opt/homebrew/bin/nebula-cert", "/usr/local/bin/nebula-cert"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("nebula-cert не установлен")
        }
        tool = found
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ward-nebula-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    @discardableResult
    private func run(_ args: [String]) throws -> Data {
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
        XCTAssertEqual(process.terminationStatus, 0, "nebula-cert \(args.joined(separator: " "))")
        return data
    }

    private struct Printed: Decodable {
        struct Details: Decodable {
            let name: String
            let groups: [String]?
            let networks: [String]?
            let isCa: Bool
            let issuer: String
            let notAfter: String
        }
        let details: Details
        let fingerprint: String
    }

    private func printed(_ file: String) throws -> Printed {
        let data = try run(["print", "-json", "-path", file])
        return try JSONDecoder().decode([Printed].self, from: data)[0]
    }

    private func text(_ file: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    private func makeSet(version: Int, hostDuration: String? = nil) throws {
        try run(["ca", "-name", "Ward CA", "-duration", "8760h", "-version", String(version),
                 "-out-crt", "ca.crt", "-out-key", "ca.key"])
        var sign = ["sign", "-ca-crt", "ca.crt", "-ca-key", "ca.key", "-name", "prod-server",
                    // IPv6 есть только в v2.
                    "-networks", version == 1 ? "10.42.0.5/16" : "10.42.0.5/16,fd00::5/64",
                    "-groups", "servers,ssh", "-version", String(version),
                    "-out-crt", "host.crt", "-out-key", "host.key"]
        if let hostDuration { sign += ["-duration", hostDuration] }
        try run(sign)
    }

    private func check(version: Int) throws {
        try makeSet(version: version)
        let expected = try printed("host.crt")
        let host = try XCTUnwrap(CertificateParser.certificates(in: try text("host.crt")).first)
        XCTAssertEqual(host.kind, .nebula(version: version))
        XCTAssertEqual(host.subject, expected.details.name)
        XCTAssertFalse(host.isCA)
        XCTAssertEqual(host.issuerFingerprint, expected.details.issuer)
        XCTAssertTrue(host.details.contains("Группы: " + (expected.details.groups ?? []).joined(separator: ", ")))
        XCTAssertTrue(host.details.contains("Сети: " + (expected.details.networks ?? []).joined(separator: ", ")),
                      "\(host.details) vs \(expected.details.networks ?? [])")
        let notAfter = try XCTUnwrap(ISO8601DateFormatter().date(from: expected.details.notAfter))
        XCTAssertEqual(try XCTUnwrap(host.notAfter).timeIntervalSince1970, notAfter.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(host.sha256, expected.fingerprint, "отпечаток как у nebula-cert")

        let ca = try XCTUnwrap(CertificateParser.certificates(in: try text("ca.crt")).first)
        XCTAssertTrue(ca.isCA)
        XCTAssertEqual(ca.subject, "Ward CA")

        // Сертификат вместе с CA: основной — хост, издатель для v1 узнаётся по отпечатку.
        let bundle = try text("ca.crt") + text("host.crt")
        XCTAssertEqual(CertificateParser.primary(in: bundle)?.subject, "prod-server")
        let issuer = CertificateParser.certificates(in: bundle).first { !$0.isCA }?.issuer
        XCTAssertEqual(issuer, "Ward CA", "CA рядом — издатель узнаётся по отпечатку")
        XCTAssertEqual(CertificateParser.certificates(in: try text("host.crt")).first?.issuer,
                       "CA " + expected.details.issuer.prefix(12) + "…", "CA нет — показываем начало его отпечатка")
    }

    func testV1MatchesNebulaCert() throws { try check(version: 1) }
    func testV2MatchesNebulaCert() throws { try check(version: 2) }

    func testKeysAndBundleAbsorb() throws {
        try makeSet(version: 2)
        var bundle = CertificateBundle()
        XCTAssertTrue(bundle.absorb(file: Data(try text("host.crt").utf8), name: "host.crt"))
        XCTAssertTrue(bundle.absorb(file: Data(try text("host.key").utf8), name: "host.key"))
        XCTAssertEqual(CertificateParser.primary(in: bundle.certificate)?.subject, "prod-server")
        XCTAssertTrue(bundle.privateKey.contains("NEBULA X25519 PRIVATE KEY"))
        XCTAssertFalse(bundle.privateKeyEncrypted)

        var ssh = SSHKey()
        XCTAssertNil(ssh.absorb(try text("host.key")), "ключ Nebula — не SSH-ключ")
    }

    func testExpiringNebulaCertificateIsReported() throws {
        try makeSet(version: 2, hostDuration: "240h")
        var entry = Entry(title: "Nebula")
        entry.certificate = CertificateBundle(certificate: try text("ca.crt") + text("host.crt"))
        XCTAssertEqual(entry.keyIssue(), "Сертификат скоро истечёт")
        XCTAssertEqual(entry.keyIssue(at: Date().addingTimeInterval(11 * 86400)), "Сертификат истёк")
        XCTAssertEqual(entry.keyIssue(at: Date().addingTimeInterval(400 * 86400)), "Сертификат истёк",
                       "и хост, и CA к тому времени истекли — сообщаем про основной")
    }
}
