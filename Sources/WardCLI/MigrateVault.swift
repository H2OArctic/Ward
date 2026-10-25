import Foundation
import Darwin
import WardCore

func migrateVault(from service: String) throws -> Bool {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ward", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let fd = open(directory.appendingPathComponent("ward.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        throw VaultSessionError.unavailable("Закройте Ward перед переносом хранилища")
    }
    return try VaultMigration.copy(
        from: KeychainStorage(service: service, account: "vault"),
        to: KeychainStorage(service: WardIdentity.applicationID, account: "vault"))
}
