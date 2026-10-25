import Foundation
import CryptoKit
import CommonCrypto

public enum VaultCryptoError: Error, Equatable {
    case wrongPassword
    case corrupted
    case keyDerivationFailed
    case unsupportedFormat(Int)
    case unsupportedKDF(String)
}

/// Ключ хранилища, «завёрнутый» ключом из мастер-пароля. Смена пароля меняет только слот.
public struct KeySlot: Codable, Equatable, Sendable {
    public var kdf: String
    public var salt: Data
    public var iterations: UInt32
    public var wrappedKey: Data
}

public struct VaultEnvelope: Codable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var slot: KeySlot
    public var payload: Data
    /// Нужное до разблокировки, поэтому не зашифровано. Лежит в той же записи связки ключей, что и хранилище:
    /// переписать его постороннему процессу не легче, чем само хранилище (в UserDefaults — мог бы любой).
    /// Неудачные попытки ввода мастер-пароля подряд — задержка перебора переживает перезапуск.
    public var failedUnlocks: Int?
    /// Включён ли SSH-агент — чтобы запустить его и до разблокировки (сама настройка — внутри хранилища).
    public var sshAgent: Bool?
    /// Включён ли мост с браузером — чтобы слушать расширение и до разблокировки (и попросить открыть Ward).
    public var browser: Bool?
}

public enum VaultCrypto {
    public static let defaultIterations: UInt32 = 600_000
    public static let kdfName = "pbkdf2-sha256"
    /// Слот приходит и из чужого файла копии: без потолка подложенные 4 млрд итераций повесили бы восстановление.
    public static let maxIterations: UInt32 = 20_000_000

    public static func newVaultKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard iterations > 0, iterations <= maxIterations, !salt.isEmpty else {
            throw VaultCryptoError.keyDerivationFailed
        }
        var derived = [UInt8](repeating: 0, count: 32)
        // «й» и «ё» бывают одной точкой кода и парой «и» + знак; без нормализации тот же пароль не подойдёт.
        // Длина — по байтам, а не strlen: иначе символ NUL обрезал бы пароль.
        let bytes = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        let status = (bytes + [0]).withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { (saltBuffer: UnsafeRawBufferPointer) -> Int32 in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress, bytes.count,
                                     saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw VaultCryptoError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    public static func makeSlot(for key: SymmetricKey, password: String,
                                iterations: UInt32 = defaultIterations) throws -> KeySlot {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let kek = try deriveKey(password: password, salt: salt, iterations: iterations)
        let raw = key.withUnsafeBytes { Data($0) }
        return KeySlot(kdf: kdfName, salt: salt, iterations: iterations,
                       wrappedKey: try seal(raw, key: kek))
    }

    public static func openSlot(_ slot: KeySlot, password: String) throws -> SymmetricKey {
        guard slot.kdf == kdfName else { throw VaultCryptoError.unsupportedKDF(slot.kdf) }
        guard let box = try? AES.GCM.SealedBox(combined: slot.wrappedKey) else { throw VaultCryptoError.corrupted }
        let kek = try deriveKey(password: password, salt: slot.salt, iterations: slot.iterations)
        do {
            return SymmetricKey(data: try AES.GCM.open(box, using: kek))
        } catch {
            throw VaultCryptoError.wrongPassword
        }
    }

    public static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw VaultCryptoError.corrupted
        }
        return combined
    }

    public static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        } catch {
            throw VaultCryptoError.corrupted
        }
    }

    public static func encode(_ vault: Vault, key: SymmetricKey, slot: KeySlot) throws -> VaultEnvelope {
        let json = try JSONEncoder().encode(vault)
        return VaultEnvelope(format: VaultEnvelope.currentFormat, slot: slot, payload: try seal(json, key: key))
    }

    public static func decode(_ envelope: VaultEnvelope, key: SymmetricKey) throws -> Vault {
        guard envelope.format <= VaultEnvelope.currentFormat else {
            throw VaultCryptoError.unsupportedFormat(envelope.format)
        }
        let json = try open(envelope.payload, key: key)
        let vault: Vault
        do {
            vault = try JSONDecoder().decode(Vault.self, from: json)
        } catch {
            throw VaultCryptoError.corrupted
        }
        guard vault.format <= Vault.currentFormat else { throw VaultCryptoError.unsupportedFormat(vault.format) }
        return vault
    }
}
