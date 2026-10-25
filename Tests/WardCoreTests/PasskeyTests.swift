import XCTest
import CryptoKit
@testable import WardCore

final class PasskeyTests: XCTestCase {
    func testCBORMatchesRFCExamples() {
        // RFC 8949, приложение A.
        XCTAssertEqual(CBOR.encode(.int(0)), Data([0x00]))
        XCTAssertEqual(CBOR.encode(.int(24)), Data([0x18, 0x18]))
        XCTAssertEqual(CBOR.encode(.int(1000)), Data([0x19, 0x03, 0xe8]))
        XCTAssertEqual(CBOR.encode(.int(1_000_000)), Data([0x1a, 0x00, 0x0f, 0x42, 0x40]))
        XCTAssertEqual(CBOR.encode(.int(-1)), Data([0x20]))
        XCTAssertEqual(CBOR.encode(.int(-7)), Data([0x26]))
        XCTAssertEqual(CBOR.encode(.int(-1000)), Data([0x39, 0x03, 0xe7]))
        XCTAssertEqual(CBOR.encode(.text("IETF")), Data([0x64, 0x49, 0x45, 0x54, 0x46]))
        XCTAssertEqual(CBOR.encode(.bytes(Data([1, 2, 3, 4]))), Data([0x44, 1, 2, 3, 4]))
        XCTAssertEqual(CBOR.encode(.array([.int(1), .int(2), .int(3)])), Data([0x83, 1, 2, 3]))
        XCTAssertEqual(CBOR.encode(.map([(.int(1), .int(2)), (.int(3), .int(4))])), Data([0xa2, 1, 2, 3, 4]))
    }

    func testRPIDRules() {
        XCTAssertNoThrow(try WebAuthn.validate(rpID: "github.com", origin: "https://github.com"))
        XCTAssertNoThrow(try WebAuthn.validate(rpID: "github.com", origin: "https://login.github.com"))
        XCTAssertNoThrow(try WebAuthn.validate(rpID: "localhost", origin: "http://localhost:8080"))
        XCTAssertThrowsError(try WebAuthn.validate(rpID: "github.com", origin: "https://github.com.evil.io"), "чужой домен")
        XCTAssertThrowsError(try WebAuthn.validate(rpID: "evilgithub.com", origin: "https://github.com"))
        XCTAssertThrowsError(try WebAuthn.validate(rpID: "com", origin: "https://github.com"), "общий суффикс")
        XCTAssertThrowsError(try WebAuthn.validate(rpID: "github.io", origin: "https://victim.github.io"), "общий хостинг")
        XCTAssertThrowsError(try WebAuthn.validate(rpID: "example.com", origin: "http://example.com"), "без https")
    }

    func testClientDataJSONIsExact() {
        let data = WebAuthn.clientData(type: "webauthn.get", challenge: Data([0xfb, 0xff]), origin: "https://a.example")
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"type":"webauthn.get","challenge":"-_8","origin":"https://a.example","crossOrigin":false}"#)
    }

    func testAssertionSignatureVerifies() throws {
        let registration = try WebAuthn.register(rpID: "example.com", origin: "https://example.com", userHandle: Data([1]),
                                                 userName: "user", userDisplayName: "User", algorithms: [-7])
        let clientDataHash = Data(SHA256.hash(data: Data("client".utf8)))
        let assertion = try WebAuthn.assert(registration.passkey, origin: "https://example.com", clientDataHash: clientDataHash)
        let publicKey = try P256.Signing.PublicKey(derRepresentation: registration.publicKeyDER)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: assertion.authenticatorData + clientDataHash))
        XCTAssertEqual(assertion.authenticatorData.prefix(32), Data(SHA256.hash(data: Data("example.com".utf8))))
        XCTAssertThrowsError(try WebAuthn.assert(registration.passkey, origin: "https://evil.io", clientDataHash: clientDataHash),
                             "подпись для чужого сайта не выдаётся")
        XCTAssertThrowsError(try WebAuthn.register(rpID: "example.com", origin: "https://example.com", userHandle: Data([1]),
                                                   userName: "u", userDisplayName: "U", algorithms: [-257]),
                             "сайт без ES256")
    }

    func testPasskeysStayInVaultAndDecodeInOldEntries() throws {
        let old = #"{"id":"7F9619FF-8B86-D011-B42D-00CF4FC964FF"}"#
        XCTAssertEqual(try JSONDecoder().decode(Entry.self, from: Data(old.utf8)).passkeys, [])

        let registration = try WebAuthn.register(rpID: "example.com", origin: "https://example.com", userHandle: Data([7]),
                                                 userName: "u", userDisplayName: "U", algorithms: [])
        var entry = Entry(title: "Example")
        entry.passkeys = [registration.passkey]
        var trashed = Entry(title: "Trash")
        trashed.passkeys = [try WebAuthn.register(rpID: "example.com", origin: "https://example.com", userHandle: Data([8]),
                                                  userName: "t", userDisplayName: "T", algorithms: []).passkey]
        trashed.deletedAt = Date()
        let vault = Vault(entries: [entry, trashed])
        XCTAssertEqual(vault.passkeys(forRPID: "EXAMPLE.com").map(\.passkey.userName), ["u"], "из корзины не входим")
        XCTAssertEqual(vault.passkey(id: registration.passkey.id)?.entry.title, "Example")
    }

    /// Сквозная сверка с независимой проверяющей стороной — py_webauthn (Duo): её `verify_registration_response`
    /// и `verify_authentication_response` принимают то, что Ward отдал бы сайту. Без py_webauthn тест пропускается.
    func testInteropWithPyWebAuthn() throws {
        let python = ProcessInfo.processInfo.environment["WARD_PYTHON"] ?? "/usr/bin/env"
        let prefix = python == "/usr/bin/env" ? ["python3"] : []
        guard run(python, prefix + ["-c", "import webauthn"]).status == 0 else {
            throw XCTSkip("нет py_webauthn: pip install webauthn (или WARD_PYTHON=<python с ним>)")
        }
        let origin = "https://login.example.com", rpID = "example.com"
        let createChallenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let registration = try WebAuthn.register(rpID: rpID, origin: origin, userHandle: Data("user-1".utf8),
                                                 userName: "alice", userDisplayName: "Alice", algorithms: [-7, -257])
        let createClient = WebAuthn.clientData(type: "webauthn.create", challenge: createChallenge, origin: origin)

        let getChallenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let getClient = WebAuthn.clientData(type: "webauthn.get", challenge: getChallenge, origin: origin)
        let assertion = try WebAuthn.assert(registration.passkey, origin: origin,
                                            clientDataHash: Data(SHA256.hash(data: getClient)))
        let b = WebAuthn.base64url
        let id = b(registration.passkey.id)
        let script = """
        import json, sys, base64
        from webauthn import verify_registration_response, verify_authentication_response
        def unb(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
        reg = verify_registration_response(
            credential={"id": "\(id)", "rawId": "\(id)", "type": "public-key",
                        "response": {"clientDataJSON": "\(b(createClient))", "attestationObject": "\(b(registration.attestationObject))"}},
            expected_challenge=unb("\(b(createChallenge))"), expected_origin="\(origin)", expected_rp_id="\(rpID)",
            require_user_verification=True)
        assert reg.fmt == "none", reg.fmt
        assert reg.credential_backed_up
        auth = verify_authentication_response(
            credential={"id": "\(id)", "rawId": "\(id)", "type": "public-key",
                        "response": {"clientDataJSON": "\(b(getClient))", "authenticatorData": "\(b(assertion.authenticatorData))",
                                     "signature": "\(b(assertion.signature))", "userHandle": "\(b(Data("user-1".utf8)))"}},
            expected_challenge=unb("\(b(getChallenge))"), expected_rp_id="\(rpID)", expected_origin="\(origin)",
            credential_public_key=reg.credential_public_key, credential_current_sign_count=0,
            require_user_verification=True)
        print("ok", auth.new_sign_count)
        """
        let result = run(python, prefix + ["-c", script])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("ok"), result.out + result.err)
    }

    private func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", "\(error)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
