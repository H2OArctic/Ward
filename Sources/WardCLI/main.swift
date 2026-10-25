import Foundation
import Darwin
import WardCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "migrate-vault" {
    guard arguments.count == 3, arguments[1] == "--from-service",
          !arguments[2].isEmpty, arguments[2] != WardIdentity.applicationID else {
        fail("Использование: ward migrate-vault --from-service <прежний идентификатор связки>")
    }
    do {
        let copied = try migrateVault(from: arguments[2])
        print(copied ? "Зашифрованное хранилище скопировано. Исходная запись сохранена." : "Такая копия хранилища уже существует.")
        exit(0)
    } catch { fail(error.localizedDescription) }
}
if arguments == ["mcp"] {
    WardMCPServer().run()
    exit(0)
}
_ = setpgid(0, 0)
let selected = arguments.first == "sudo-selected"
let request: SudoRequest?
let requestData: Data
if arguments.count == 2, arguments[0] == "find-server" {
    let search = CommandServerSearch(query: arguments[1])
    guard search.isValid else { fail("Укажите название или адрес сервера длиной от 2 до 256 символов.") }
    request = nil
    requestData = try JSONEncoder().encode(search)
} else if arguments.count >= 4, ["sudo", "sudo-selected"].contains(arguments[0]),
          let entryID = UUID(uuidString: arguments[1]), arguments[2] == "--" {
    var sudo = SudoRequest(entryID: entryID, arguments: Array(arguments.dropFirst(3)))
    sudo.selectionRequired = selected
    guard sudo.isValid else { fail("Некорректная команда.") }
    request = sudo
    requestData = try JSONEncoder().encode(sudo)
} else {
    fail("Использование: ward sudo <ID записи> -- <команда> [аргументы]\nward find-server <название или адрес>\nward mcp\nSSH — по ключу, пароль sudo — из Ward. Интерактивный stdin не поддерживается.")
}
guard let team = BrowserPeerCheck.ownTeam() else { fail("Нужна сборка Ward с подписью Apple Development.") }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("Не удалось открыть сокет Ward.") }
var address = sockaddr_un()
let path = Array(CommandWire.socketPath.utf8)
guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("Слишком длинный путь к сокету.") }
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path + [0]) }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else {
    let code = errno
    if code == EPERM || code == EACCES {
        fail("Доступ к локальному сокету Ward запрещён: \(String(cString: strerror(code))). В Codex запустите эту команду с разрешением на выполнение вне песочницы.")
    }
    fail("Ward недоступен: \(String(cString: strerror(code))). Запустите его, разблокируйте и включите «Терминал и sudo».")
}
var uid: uid_t = 0, gid: gid_t = 0
var token = audit_token_t()
var length = socklen_t(MemoryLayout<audit_token_t>.size)
guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
      getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
      CommandPeerCheck.matches(token, identifier: WardIdentity.applicationID, team: team) else { fail("Подпись Ward не подтверждена.") }
var timeout = timeval(tv_sec: 60, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
do {
    try CommandWire.write(requestData, to: fd)
    let response = try JSONDecoder().decode(CommandResponse.self, from: CommandWire.read(from: fd))
    close(fd)
    if request == nil {
        guard let id = response.selectedEntryID else { fail(response.error ?? "Выбор отменён.") }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["entryID": id.uuidString]))
        FileHandle.standardOutput.write(Data([10]))
        exit(0)
    }
    guard let request else { fail("Некорректная команда.") }
    guard let credentials = response.credentials else { fail(response.error ?? "Ward отклонил запрос.") }
    let process = Process()
    let marker = "__WARD_SUDO_" + UUID().uuidString + "__"
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = credentials.sshArguments(for: request, prompt: marker)
    let input = Pipe()
    let errors = Pipe()
    let output = Pipe()
    let capturedOutput = CommandOutput()
    let capturedErrors = CommandOutput()
    let outputDone = DispatchGroup()
    process.standardInput = input
    process.standardOutput = selected ? output : FileHandle.standardOutput
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["SSH_AUTH_SOCK"] = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ward/agent.sock").path
    process.environment = environment
    try process.run()
    if credentials.password.isEmpty { try? input.fileHandleForWriting.close() }
    if selected {
        outputDone.enter()
        DispatchQueue.global().async {
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                capturedOutput.append(data)
            }
            outputDone.leave()
        }
    }
    var filter = SudoPromptFilter(marker: marker)
    var supplied = false
    while true {
        let data = errors.fileHandleForReading.availableData
        let result = filter.consume(data, end: data.isEmpty)
        if selected { capturedErrors.append(result.output) }
        else { FileHandle.standardError.write(result.output) }
        if result.prompts > 0, !supplied, !credentials.password.isEmpty {
            supplied = true
            try? input.fileHandleForWriting.write(contentsOf: Data((credentials.password + "\n").utf8))
            try? input.fileHandleForWriting.close()
        }
        if data.isEmpty { break }
    }
    if !supplied { try? input.fileHandleForWriting.close() }
    process.waitUntilExit()
    let status = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    if selected {
        outputDone.wait()
        let result: [String: Any] = ["exitCode": status,
            "stdout": capturedOutput.text(redacting: credentials.password),
            "stderr": capturedErrors.text(redacting: credentials.password),
            "truncated": capturedOutput.truncated || capturedErrors.truncated]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(status)
} catch { fail("Не удалось выполнить запрос Ward/SSH.") }
