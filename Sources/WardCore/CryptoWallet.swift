import Foundation

public struct CryptoWallet: Codable, Hashable, Sendable {
    public var network: String
    public var address: String
    public var seedPhrase: String
    public var privateKey: String
    public var passphrase: String

    public init(network: String = "", address: String = "", seedPhrase: String = "",
                privateKey: String = "", passphrase: String = "") {
        self.network = network
        self.address = address
        self.seedPhrase = seedPhrase
        self.privateKey = privateKey
        self.passphrase = passphrase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decodeIfPresent(String.self, forKey: .network) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        seedPhrase = try c.decodeIfPresent(String.self, forKey: .seedPhrase) ?? ""
        privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey) ?? ""
        passphrase = try c.decodeIfPresent(String.self, forKey: .passphrase) ?? ""
    }
}
