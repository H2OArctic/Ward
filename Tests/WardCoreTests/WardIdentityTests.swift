import Foundation
import XCTest
@testable import WardCore

final class WardIdentityTests: XCTestCase {
    func testCompiledIdentityMatchesBuildConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let expected = try String(contentsOf: root.appendingPathComponent("build/application-id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(WardIdentity.applicationID, expected)
        XCTAssertEqual(WardIdentity.browserHostID, expected + ".browser-host")
        XCTAssertEqual(WardIdentity.commandHelperID, expected + ".cli")
    }
}
