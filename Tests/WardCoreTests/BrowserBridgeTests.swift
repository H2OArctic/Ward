import XCTest
import CryptoKit
@testable import WardCore

final class BrowserBridgeTests: XCTestCase {
    func testFramingIsLittleEndianAndBounded() {
        let framed = NativeMessaging.frame(Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(Array(framed.prefix(4)), [7, 0, 0, 0])
        XCTAssertEqual(NativeMessaging.length(ofHeader: framed.prefix(4)), 7)
        XCTAssertNil(NativeMessaging.length(ofHeader: Data([0xff, 0xff, 0xff, 0x7f])), "больше 1 МБ — не принимаем")
        XCTAssertNil(NativeMessaging.length(ofHeader: Data([1, 0])))
    }

    func testParsingRequests() throws {
        XCTAssertEqual(try BrowserRequest.parse(["type": "hello"]), .hello)
        XCTAssertEqual(try BrowserRequest.parse(["type": "logins", "url": "https://github.com/login"]),
                       .logins(url: "https://github.com/login"))
        XCTAssertThrowsError(try BrowserRequest.parse(["type": "fill", "entryID": "не-uuid", "url": "https://a.b"]))
        XCTAssertThrowsError(try BrowserRequest.parse(["type": "passkey.get", "origin": "https://a.example", "rpID": "a.example",
                                                       "challenge": "%%%"]), "испорченный base64url")
        XCTAssertThrowsError(try BrowserRequest.parse(["type": "delete-everything"]))
    }

    private func vault() -> (Vault, github: Entry, other: Entry) {
        var github = Entry(title: "GitHub")
        github.url = "github.com"
        github.login = "alice"
        github.secret = "s3cret"
        github.totp = TOTPConfig(secret: Data("12345678901234567890".utf8))
        var other = Entry(title: "Банк")
        other.url = "bank.example"
        other.secret = "bank-pass"
        var trashed = Entry(title: "Старый GitHub")
        trashed.url = "github.com"
        trashed.secret = "old"
        trashed.deletedAt = Date()
        return (Vault(entries: [github, other, trashed]), github, other)
    }

    func testLoginsOnlyForMatchingSite() {
        let (vault, github, _) = vault()
        XCTAssertEqual(BrowserBridge.logins(for: "https://github.com/login", in: vault).map(\.entryID), [github.id])
        XCTAssertTrue(BrowserBridge.logins(for: "https://gist.github.com/", in: vault).isEmpty)
        XCTAssertTrue(BrowserBridge.logins(for: "https://github.com.evil.io/login", in: vault).isEmpty, "фишинг")
        XCTAssertTrue(BrowserBridge.logins(for: "file:///etc/passwd", in: vault).isEmpty)
        XCTAssertTrue(BrowserBridge.logins(for: "chrome://settings", in: vault).isEmpty)
    }

    func testFillRechecksSite() throws {
        let (vault, github, other) = vault()
        let fill = try BrowserBridge.fill(entryID: github.id, url: "https://github.com/login", in: vault,
                                          now: Date(timeIntervalSince1970: 59))
        XCTAssertEqual(fill, BrowserBridge.Fill(login: "alice", password: "s3cret", code: "287082"), "RFC 6238, T=59")
        XCTAssertThrowsError(try BrowserBridge.fill(entryID: other.id, url: "https://github.com/login", in: vault)) {
            XCTAssertEqual($0 as? BrowserBridge.Failure, .siteMismatch, "пароль банка на GitHub не отдаётся")
        }
        XCTAssertThrowsError(try BrowserBridge.fill(entryID: UUID(), url: "https://github.com", in: vault))
    }

    func testLoginsAndFillAreScopedToExactHost() throws {
        var stage = Entry(title: "Stage")
        stage.url = "https://stage.example.com/login"
        stage.login = "stage-user"
        stage.secret = "stage-password"
        var production = Entry(title: "Production")
        production.url = "https://prod.example.com"
        production.secret = "production-password"
        var root = Entry(title: "Root")
        root.url = "https://example.com"
        root.secret = "root-password"
        let vault = Vault(entries: [stage, production, root])

        for host in ["stage.example.com", "STAGE.EXAMPLE.COM."] {
            XCTAssertEqual(BrowserBridge.logins(for: "https://\(host)/account", in: vault).map(\.entryID), [stage.id])
            XCTAssertEqual(try BrowserBridge.fill(entryID: stage.id, url: "https://\(host)/account", in: vault).password, stage.secret)
        }
        for host in ["prod.example.com", "example.com", "nested.stage.example.com", "www.stage.example.com"] {
            XCTAssertFalse(BrowserBridge.logins(for: "https://\(host)", in: vault).contains { $0.entryID == stage.id })
            XCTAssertThrowsError(try BrowserBridge.fill(entryID: stage.id, url: "https://\(host)", in: vault)) {
                XCTAssertEqual($0 as? BrowserBridge.Failure, .siteMismatch)
            }
        }
    }

    func testPasskeyThroughBridge() throws {
        var vault = Vault()
        let creation = BrowserRequest.PasskeyCreation(
            origin: "https://example.com", rpID: "example.com", rpName: "Example", userHandle: Data("u1".utf8),
            userName: "alice", userDisplayName: "Alice", challenge: Data([1, 2, 3]), algorithms: [-7], excludeCredentials: [])
        let created = try BrowserBridge.createPasskey(creation, in: vault)
        XCTAssertEqual(created.response.publicKeyAlgorithm, -7)
        var entry = Entry(title: "Example")
        entry.passkeys = [created.passkey]
        vault.entries.append(entry)

        var again = creation
        again.excludeCredentials = [created.passkey.id]
        XCTAssertThrowsError(try BrowserBridge.createPasskey(again, in: vault)) {
            XCTAssertEqual($0 as? BrowserBridge.Failure, .alreadyRegistered)
        }

        let request = BrowserRequest.PasskeyRequest(origin: "https://example.com", rpID: "example.com",
                                                    challenge: Data([9, 9]), allowCredentials: [])
        XCTAssertEqual(try BrowserBridge.candidates(request, in: vault).count, 1)
        var foreign = request
        foreign.allowCredentials = [Data([0xde, 0xad])]
        XCTAssertTrue(try BrowserBridge.candidates(foreign, in: vault).isEmpty, "сайт просит другой ключ")
        var phishing = request
        phishing.origin = "https://example.com.evil.io"
        XCTAssertThrowsError(try BrowserBridge.candidates(phishing, in: vault), "чужой сайт не видит passkey")

        let asserted = try BrowserBridge.assertion(created.passkey, request: request)
        let publicKey = try P256.Signing.PublicKey(derRepresentation: XCTUnwrap(WebAuthn.fromBase64url(created.response.publicKey)))
        let clientData = try XCTUnwrap(WebAuthn.fromBase64url(asserted.clientDataJSON))
        let authData = try XCTUnwrap(WebAuthn.fromBase64url(asserted.authenticatorData))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: XCTUnwrap(WebAuthn.fromBase64url(asserted.signature)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: authData + Data(SHA256.hash(data: clientData))))
        XCTAssertTrue(String(decoding: clientData, as: UTF8.self).contains(#""challenge":"CQk""#))
    }
}
