import Foundation

public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Терпим к пробелам, дефисам, паддингу и нижнему регистру — так ключи показывают сайты.
    public static func decode(_ string: String) -> Data? {
        var buffer: UInt64 = 0
        var bits = 0
        var out = Data()
        for ch in string.uppercased() where !(ch.isWhitespace || ch == "-" || ch == "=") {
            guard let value = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
        }
        return out.isEmpty ? nil : out
    }

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
        }
        return out
    }
}
