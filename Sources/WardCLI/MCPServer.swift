import Foundation
import Darwin
import WardCore

final class WardMCPServer: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var jobs: [String: MCPJob] = [:]
    private var initialized = false

    func run() {
        while let line = readLine() {
            guard line.utf8.count <= 1_048_576,
                  let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON-RPC request"]])
                continue
            }
            let params = message["params"] as? [String: Any] ?? [:]
            if method == "notifications/cancelled", let id = params["requestId"] {
                lock.lock()
                let job = jobs[String(describing: id)]
                lock.unlock()
                job?.cancel()
                continue
            }
            guard let id = message["id"] else { continue }
            switch method {
            case "initialize":
                initialized = true
                let requested = params["protocolVersion"] as? String ?? ""
                let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                result(id, ["protocolVersion": versions.contains(requested) ? requested : "2025-06-18",
                    "capabilities": ["tools": [:]], "serverInfo": ["name": "Ward", "version": "1.0.0"],
                    "instructions": "Для согласованных SSH/sudo-задач используй Ward: вызови find_server с названием или адресом, пользователь выберет запись в окне Ward, затем передай полученный entryID и массив аргументов в sudo. Codex получает только выбранный ID и результат команды. Пароли и остальные записи остаются в Ward. Не запрашивай пароль или файл с ним. При нескольких окружениях уточни целевой сервер. Разрешение Ward не расширяет согласованный пользователем объём команд."])
            case "ping": result(id, [:])
            case "tools/list" where initialized: result(id, ["tools": Self.tools])
            case "tools/call" where initialized: call(id, params: params)
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method unavailable"]])
            }
        }
        lock.lock()
        let pending = Array(jobs.values)
        lock.unlock()
        pending.forEach { $0.cancel() }
    }

    private func call(_ id: Any, params: [String: Any]) {
        let input = params["arguments"] as? [String: Any] ?? [:]
        let arguments: [String]
        switch params["name"] as? String {
        case "find_server":
            guard let query = input["query"] as? String, CommandServerSearch(query: query).isValid else {
                toolResult(id, error: "Укажите query: название или адрес сервера, от 2 до 256 символов.")
                return
            }
            arguments = ["find-server", query]
        case "sudo":
            guard let rawID = input["entryID"] as? String, let entryID = UUID(uuidString: rawID),
                  let command = input["arguments"] as? [String], SudoRequest(entryID: entryID, arguments: command).isValid else {
                toolResult(id, error: "Нужны entryID из find_server и непустой массив arguments.")
                return
            }
            arguments = ["sudo-selected", entryID.uuidString, "--"] + command
        default:
            toolResult(id, error: "Неизвестный инструмент.")
            return
        }
        let key = String(describing: id)
        let job = MCPJob()
        lock.lock()
        guard jobs.count < 8, jobs[key] == nil else {
            lock.unlock()
            toolResult(id, error: "Слишком много запросов.")
            return
        }
        jobs[key] = job
        lock.unlock()
        DispatchQueue.global().async { [self] in
            let response = job.run(arguments)
            result(id, response)
            lock.lock()
            jobs.removeValue(forKey: key)
            lock.unlock()
        }
    }

    private func result(_ id: Any, _ value: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": value]) }

    private func toolResult(_ id: Any, error: String) {
        result(id, ["content": [["type": "text", "text": error]], "isError": true])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        outputLock.lock()
        FileHandle.standardOutput.write(data)
        outputLock.unlock()
    }

    private static let tools: [[String: Any]] = [
        ["name": "find_server", "description": "Показать пользователю совпадения в окне Ward и получить только ID выбранного сервера. Используй название или адрес из задачи; пароль и список записей не возвращаются.",
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string", "minLength": 2, "maxLength": 256]], "required": ["query"], "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]],
        ["name": "sudo", "description": "Выполнить согласованную команду sudo на сервере, выбранном пользователем через find_server. SSH по ключу, пароль передаёт Ward. Передавай arguments как argv, без shell-склейки. Интерактивный stdin не поддерживается. Выбор сервера и команда подтверждаются в Ward.",
         "inputSchema": ["type": "object", "properties": ["entryID": ["type": "string", "format": "uuid"], "arguments": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 256]], "required": ["entryID", "arguments"], "additionalProperties": false],
         "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true]]
    ]
}

private final class MCPJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning {
            let pid = process.processIdentifier
            if kill(-pid, SIGTERM) != 0 { process.terminate() }
        }
    }

    func run(_ arguments: [String]) -> [String: Any] {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = arguments
        let output = Pipe(), errors = Pipe()
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = errors
        lock.lock()
        guard !cancelled else { lock.unlock(); return failure("Запрос отменён.") }
        do {
            try child.run()
            process = child
            lock.unlock()
        } catch {
            lock.unlock()
            return failure("Не удалось запустить подписанный помощник Ward.")
        }
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
        let stdout = CommandOutput(limit: 524_288), stderr = CommandOutput()
        let readers = DispatchGroup()
        for (pipe, capture) in [(output, stdout), (errors, stderr)] {
            readers.enter()
            DispatchQueue.global().async {
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    capture.append(data)
                }
                readers.leave()
            }
        }
        child.waitUntilExit()
        readers.wait()
        timeout.cancel()
        lock.lock()
        process = nil
        let stopped = cancelled
        lock.unlock()
        if stopped { return failure("Запрос отменён или превышено время ожидания. Состояние уже начатой удалённой команды нужно проверить отдельно.") }
        let text = stdout.text(redacting: "")
        if !stdout.truncated, let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return ["content": [["type": "text", "text": text]], "structuredContent": object, "isError": child.terminationStatus != 0]
        }
        return failure(stderr.text(redacting: "").isEmpty ? "Ward не вернул результат." : stderr.text(redacting: ""))
    }

    private func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }
}
