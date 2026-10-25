import XCTest
import Darwin
@testable import WardCore

final class BrowserServerTests: XCTestCase {
    private func connectSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func send(_ object: [String: Any], to fd: Int32) throws {
        let frame = NativeMessaging.frame(try JSONSerialization.data(withJSONObject: object))
        let written = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, frame.count)
    }

    private func response(_ fd: Int32) throws -> [String: Any] {
        func readData(_ count: Int) throws -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let size = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
                guard size > 0 else { throw POSIXError(.ETIMEDOUT) }
                offset += size
            }
            return Data(bytes)
        }
        let length = try XCTUnwrap(NativeMessaging.length(ofHeader: readData(4)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: readData(length)) as? [String: Any])
    }

    func testCapacityKeepsCancellationAvailableAndDisconnectNotifies() throws {
        let path = "/tmp/ward-browser-\(UUID().uuidString.prefix(8))"
        let box = Replies()
        let disconnected = expectation(description: "disconnect")
        let server = BrowserBridgeServer(socketPath: path, admit: { _ in true }, disconnected: { _ in disconnected.fulfill() }) { _, data, reply in
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if object["type"] as? String == "cancel" {
                reply(Data(#"{"id":34,"ok":true}"#.utf8))
            } else { box.append(reply) }
        }
        try server.start()
        defer { server.stop() }
        let fd = try connectSocket(path)
        for id in 1...33 { try send(["id": id, "type": "hello"], to: fd) }
        let busy = try response(fd)
        XCTAssertEqual(busy["id"] as? Int, 33)
        XCTAssertEqual(busy["error"] as? String, "busy")
        XCTAssertEqual(box.count, BrowserBridgeServer.maxPendingRequests)
        try send(["id": 34, "type": "cancel", "requestID": 1], to: fd)
        let cancelled = try response(fd)
        XCTAssertEqual(cancelled["ok"] as? Bool, true)
        box.finish()
        shutdown(fd, SHUT_RDWR)
        close(fd)
        wait(for: [disconnected], timeout: 2)
    }

    func testConnectionCountIsBounded() throws {
        let path = "/tmp/ward-browser-\(UUID().uuidString.prefix(8))"
        let server = BrowserBridgeServer(socketPath: path, admit: { _ in true }) { _, _, reply in
            reply(Data("{}".utf8))
        }
        try server.start()
        var clients: [Int32] = []
        defer { clients.forEach { close($0) }; server.stop() }
        for _ in 0..<BrowserBridgeServer.maxConnections {
            let fd = try connectSocket(path)
            clients.append(fd)
            try send(["type": "hello"], to: fd)
            XCTAssertTrue(try response(fd).isEmpty)
        }
        let rejected = try connectSocket(path)
        defer { close(rejected) }
        var byte: UInt8 = 0
        XCTAssertEqual(read(rejected, &byte, 1), 0)
    }

    func testServerCannotReplaceLiveSocket() throws {
        let path = "/tmp/ward-browser-\(UUID().uuidString.prefix(8))"
        let first = BrowserBridgeServer(socketPath: path, admit: { _ in true }) { _, _, reply in reply(Data("{}".utf8)) }
        try first.start()
        defer { first.stop() }
        let second = BrowserBridgeServer(socketPath: path, admit: { _ in true }) { _, _, reply in reply(Data("{}".utf8)) }
        XCTAssertThrowsError(try second.start()) {
            guard case .alreadyRunning? = $0 as? SSHAgentServer.Failure else { return XCTFail("\($0)") }
        }
        let fd = try connectSocket(path)
        defer { close(fd) }
        try send(["type": "hello"], to: fd)
        XCTAssertTrue(try response(fd).isEmpty)
    }

    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [@Sendable (Data) -> Void] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
        func append(_ reply: @escaping @Sendable (Data) -> Void) { lock.lock(); replies.append(reply); lock.unlock() }
        func finish() {
            lock.lock()
            let pending = replies
            replies = []
            lock.unlock()
            pending.forEach { $0(Data("{}".utf8)) }
        }
    }
}
