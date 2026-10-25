import XCTest
@testable import WardCore

final class GoogleAuthMigrationTests: XCTestCase {
    /// Широко известный пример экспорта: «Example:alice@google.com», секрет JBSWY3DPEHPK3PXP.
    func testPublicSample() throws {
        let link = "otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZTAC"
        let result = try XCTUnwrap(GoogleAuthMigration.parse(link))
        XCTAssertEqual(result.skipped, 0)
        let code = try XCTUnwrap(result.codes.first)
        XCTAssertEqual(code.secret, Base32.decode("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(code.issuer, "Example")
        XCTAssertEqual(code.account, "alice@google.com")
        XCTAssertEqual(code.digits, 6)
        XCTAssertEqual(code.algorithm, .sha1)
        XCTAssertEqual(code.period, 30)
    }

    /// Три записи: SHA-256/8 цифр, HOTP (пропускается), без алгоритма и с кириллицей. В base64 есть «+» и «/».
    private let multi = "ClAKIDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyEhtCaWxsaW5nOnlvdUBjb21wYW55LmV4YW1wbGUaB0JpbGxpbmcgAigCMAI4AAojCgpob3Rwc2VjcmV0EghPbGQ6aG90cBoDT2xkIAEoATABOAAKNQoUyMnKy8zNzs/Q0dLT1NXW19jZ2tsSC0l2YW4gUGV0cm92GgjQkdCw0L3QuiAAKAAwADgAEAEYASAAKJWa7zo="

    func testMultipleCodesAndSkippedHOTP() throws {
        let result = try XCTUnwrap(GoogleAuthMigration.parse("otpauth-migration://offline?data=" + multi))
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.codes.count, 2)

        let billing = result.codes[0]
        XCTAssertEqual(billing.issuer, "Billing")
        XCTAssertEqual(billing.account, "you@company.example")
        XCTAssertEqual(billing.algorithm, .sha256)
        XCTAssertEqual(billing.digits, 8)
        XCTAssertEqual(TOTP.code(billing, at: Date(timeIntervalSince1970: 59)), "46119246", "вектор RFC 6238 для SHA-256")

        let bank = result.codes[1]
        XCTAssertEqual(bank.issuer, "Банк")
        XCTAssertEqual(bank.account, "Ivan Petrov")
        XCTAssertEqual(bank.algorithm, .sha1)
        XCTAssertEqual(bank.secret, Data(200..<220))
    }

    func testEncodingVariantsFromScanners() throws {
        let percent = multi.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(GoogleAuthMigration.parse("otpauth-migration://offline?data=" + percent)?.codes.count, 2)

        let urlSafe = multi.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(GoogleAuthMigration.parse("otpauth-migration://offline?data=" + urlSafe)?.codes.count, 2)
        XCTAssertEqual(TOTPConfig.parseAll("  otpauth-migration://offline?data=\(multi)\n").count, 2)
    }

    func testGarbageIsRejectedWithoutCrash() {
        XCTAssertNil(GoogleAuthMigration.parse("otpauth-migration://offline?data="))
        XCTAssertNil(GoogleAuthMigration.parse("otpauth-migration://offline?data=%%%"))
        XCTAssertNil(GoogleAuthMigration.parse("otpauth-migration://offline"))
        XCTAssertNil(GoogleAuthMigration.parse("https://example.com?data=" + multi))
        for _ in 0..<500 {
            let bytes = (0..<Int.random(in: 1...120)).map { _ in UInt8.random(in: 0...255) }
            _ = GoogleAuthMigration.parse("otpauth-migration://offline?data=" + Data(bytes).base64EncodedString())
        }
        // Длина поля больше самих данных.
        _ = GoogleAuthMigration.parse("otpauth-migration://offline?data=" + Data([0x0a, 0xff, 0x01, 0x00]).base64EncodedString())
    }

    func testImportSkipsDuplicates() throws {
        let codes = try XCTUnwrap(GoogleAuthMigration.parse("otpauth-migration://offline?data=" + multi)).codes
        var vault = Vault()
        XCTAssertEqual(vault.importCodes(codes, space: .work).added, 2)
        let again = vault.importCodes(codes, space: .work)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.duplicates, 2)
        XCTAssertEqual(vault.entries.map(\.title), ["Billing", "Банк"])
        XCTAssertEqual(vault.entries.first?.login, "you@company.example")
        XCTAssertEqual(vault.entries.first?.loginKind, .email)
        XCTAssertTrue(vault.entries.allSatisfy { $0.space == .work && $0.secret.isEmpty })
    }
}

final class BackupMirrorTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ward-mirror-\(UUID().uuidString)")
    }

    func testMirrorsOnlyNewestAndOnce() throws {
        let a = tempDir(), b = tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let primary = BackupStore(directory: a, keep: { 0 })
        let mirror = BackupStore(directory: b, keep: { 2 })

        XCTAssertFalse(try primary.mirrorLatest(to: mirror), "нечего копировать")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 { try primary.write(Data("v\(i)".utf8), now: base.addingTimeInterval(Double(i))) }
        XCTAssertTrue(try primary.mirrorLatest(to: mirror))
        XCTAssertFalse(try primary.mirrorLatest(to: mirror), "та же копия второй раз не пишется")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(mirror.all().first)), Data("v2".utf8))

        for i in 3..<6 {
            try primary.write(Data("v\(i)".utf8), now: base.addingTimeInterval(Double(i)))
            try primary.mirrorLatest(to: mirror)
        }
        XCTAssertEqual(mirror.all().count, 2, "в зеркале тоже чистятся старые")
        XCTAssertEqual(primary.all().count, 6)
    }

    func testUnmountedVolumeIsNotCreatedOnSystemDisk() {
        let missing = URL(fileURLWithPath: "/Volumes/WardNoSuchDisk-\(UUID().uuidString)/Backups")
        XCTAssertFalse(BackupStore.isReachable(missing))
        let store = BackupStore(directory: missing, keep: { 0 })
        XCTAssertThrowsError(try store.write(Data("x".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        XCTAssertTrue(BackupStore.isReachable(tempDir()))
    }
}
