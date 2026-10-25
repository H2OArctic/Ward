import Foundation
import CryptoKit

public enum VaultMigration {
    public enum Failure: LocalizedError, Equatable {
        case missingSource, destinationExists

        public var errorDescription: String? {
            switch self {
            case .missingSource: return "Исходное хранилище не найдено"
            case .destinationExists: return "В новом месте уже есть другое хранилище — перенос отменён"
            }
        }
    }

    @discardableResult
    public static func copy(from source: VaultStorage, to destination: VaultStorage) throws -> Bool {
        guard let data = try source.read() else { throw Failure.missingSource }
        let envelope = try JSONDecoder().decode(VaultEnvelope.self, from: data)
        guard envelope.format >= 0, envelope.format <= VaultEnvelope.currentFormat else {
            throw VaultCryptoError.unsupportedFormat(envelope.format)
        }
        guard envelope.slot.kdf == VaultCrypto.kdfName else {
            throw VaultCryptoError.unsupportedKDF(envelope.slot.kdf)
        }
        guard !envelope.slot.salt.isEmpty,
              envelope.slot.iterations > 0, envelope.slot.iterations <= VaultCrypto.maxIterations,
              let wrapped = try? AES.GCM.SealedBox(combined: envelope.slot.wrappedKey),
              wrapped.ciphertext.count == 32,
              (try? AES.GCM.SealedBox(combined: envelope.payload)) != nil else {
            throw VaultCryptoError.corrupted
        }
        if let existing = try destination.read() {
            guard existing == data else { throw Failure.destinationExists }
            return false
        }
        try destination.create(data)
        return true
    }
}
