import Foundation
import Security

/// Где лежит зашифрованное хранилище. В приложении — связка ключей, в тестах — память.
public protocol VaultStorage {
    func read() throws -> Data?
    /// Только создание: существующее хранилище так не перезаписать.
    func create(_ data: Data) throws
    func update(_ data: Data) throws
}

public struct KeychainStorage: VaultStorage {
    public let service: String
    public let account: String

    public struct Failure: LocalizedError, Equatable {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Ошибка связки ключей \(status)"
        }
    }

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    public func create(_ data: Data) throws {
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "Ward — хранилище паролей"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func update(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// Зашифрованные копии после каждого изменения; каждая открывается мастер-паролем на момент записи.
public struct BackupStore {
    public static let fileExtension = "wardbackup"
    static let prefix = "ward-"

    public let directory: URL
    private let keep: () -> Int

    /// `keep` — сколько последних копий хранить, 0 — все. Замыкание, чтобы подхватывать смену настройки.
    public init(directory: URL, keep: @escaping () -> Int) {
        self.directory = directory
        self.keep = keep
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }()

    public func write(_ data: Data, now: Date = Date()) throws {
        let base = "\(Self.prefix)\(Self.stamp.string(from: now))"
        var name = "\(base).\(Self.fileExtension)"
        var n = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base)-\(n).\(Self.fileExtension)"
            n += 1
        }
        try store(data, named: name)
    }

    private func store(_ data: Data, named name: String) throws {
        guard Self.isReachable(directory) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.writePrivate(data, to: directory.appendingPathComponent(name))
        prune()
    }

    /// Файл сразу создаётся с правами 0600 и появляется под своим именем целиком (через rename).
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Error?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
        if failure == nil, rename(temp.path, url.path) != 0 {
            failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let failure {
            unlink(temp.path)
            throw failure
        }
    }

    /// Копирует последнюю копию в `target`, если её там ещё нет. `true` — скопировал.
    @discardableResult
    public func mirrorLatest(to target: BackupStore) throws -> Bool {
        guard let latest = all().first else { return false }
        if target.all().contains(where: { $0.lastPathComponent == latest.lastPathComponent }) { return false }
        try target.store(Data(contentsOf: latest), named: latest.lastPathComponent)
        return true
    }

    /// Папка на внешнем диске доступна, только если диск смонтирован. Иначе `createDirectory`
    /// тихо создал бы `/Volumes/<Диск>` на системном SSD, и «копия на внешний диск» лежала бы рядом с оригиналом.
    public static func isReachable(_ directory: URL) -> Bool {
        let components = directory.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return true }
        let root = URL(fileURLWithPath: "/Volumes/" + components[2], isDirectory: true)
        guard let volume = try? root.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return volume.standardizedFileURL.path == root.standardizedFileURL.path
    }

    /// Только копии, которые пишет сам Ward (ручной экспорт в той же папке не трогается). Новые первыми.
    public func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in Self.order(of: url).map { (url, $0) } }
            .sorted { $0.1.stamp != $1.1.stamp ? $0.1.stamp > $1.1.stamp : $0.1.index > $1.1.index }
            .map(\.0)
    }

    /// «ward-<время>.wardbackup» — первая копия в эту миллисекунду, «ward-<время>-N.wardbackup» — N-я следующая.
    static func order(of url: URL) -> (stamp: String, index: Int)? {
        guard url.pathExtension == fileExtension else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        let stampLength = "yyyy-MM-dd_HH-mm-ss-SSS".count
        guard rest.count >= stampLength else { return nil }
        let stamp = String(rest.prefix(stampLength))
        guard stamp.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let suffix = rest.dropFirst(stampLength)
        if suffix.isEmpty { return (stamp, 0) }
        guard suffix.first == "-", let index = Int(suffix.dropFirst()), index > 0 else { return nil }
        return (stamp, index)
    }

    public func latestDate() -> Date? {
        guard let url = all().first else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func prune() {
        let limit = keep()
        guard limit > 0 else { return }
        for url in all().dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
