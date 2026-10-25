import Foundation
import Darwin
import WardCore

// Помощник браузера: Chrome запускает его по native messaging (stdin/stdout) и передаёт происхождение
// расширения первым аргументом. Сам ничего не знает о паролях — пересылает кадры в запущенный Ward.
// Отвечать — только через Ward: он проверяет подпись этого процесса и того, кто его запустил.

let socketPath: String = {
    #if DEBUG
    // Сквозная проверка (tools/browser-e2e) — свой сокет, чтобы не задеть настоящий Ward с включённым мостом.
    if let path = ProcessInfo.processInfo.environment["WARD_BROWSER_SOCKET"] { return path }
    #endif
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ward/browser.sock").path
}()

func writeFrame(_ json: Data, to fd: Int32) {
    let frame = [UInt8](NativeMessaging.frame(json))
    var offset = 0
    while offset < frame.count {
        let n = frame.withUnsafeBytes { write(fd, $0.baseAddress! + offset, frame.count - offset) }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { exit(0) }
        offset += n
    }
}

func readFrame(from fd: Int32) -> Data? {
    func exactly(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            offset += n
        }
        return Data(buffer)
    }
    guard let header = exactly(4), let length = NativeMessaging.length(ofHeader: header) else { return nil }
    return exactly(length)
}

/// Ward не запущен — расширение получает понятный ответ на каждый свой запрос, а не молчание.
func answerUnavailable() -> Never {
    while let request = readFrame(from: STDIN_FILENO) {
        let id = (try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["id"] ?? NSNull()
        let reply: [String: Any] = ["id": id, "ok": false, "error": "wardNotRunning"]
        if let json = try? JSONSerialization.data(withJSONObject: reply) { writeFrame(json, to: STDOUT_FILENO) }
    }
    exit(0)
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { answerUnavailable() }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes + [0]) }
let connection = socket(AF_UNIX, SOCK_STREAM, 0)
var noSigpipe: Int32 = 1
setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connection >= 0, connected == 0 else { answerUnavailable() }

// Chrome → Ward: в отдельном потоке; закрыл Chrome свою сторону — закрываем и сокет.
Thread {
    while let request = readFrame(from: STDIN_FILENO) { writeFrame(request, to: connection) }
    shutdown(connection, SHUT_RDWR)
}.start()

// Ward → Chrome.
while let response = readFrame(from: connection) { writeFrame(response, to: STDOUT_FILENO) }
exit(0)
