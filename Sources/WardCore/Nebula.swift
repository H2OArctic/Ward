import Foundation
import CryptoKit

/// Сертификаты Nebula (slackhq/nebula). Формат и отпечатки сверены с `nebula-cert` 1.11 и cert/cert_v2.go:
/// v1 — protobuf `RawNebulaCertificate { Details = 1; Signature = 2 }`,
/// v2 — DER `SEQUENCE { [0] details, [1] curve, [2] publicKey, [3] signature }`.
public enum NebulaCertificate {
    public static func v1(_ der: Data) -> CertificateInfo? {
        var outer = ProtoReader(Array(der))
        var detailsBytes: [UInt8]?
        while let field = outer.next() {
            if field.number == 1, case .bytes(let bytes) = field.value { detailsBytes = bytes }
        }
        guard let detailsBytes else { return nil }

        var name = "", groups: [String] = [], ips: [UInt32] = [], subnets: [UInt32] = []
        var notBefore: Int64?, notAfter: Int64?, isCA = false, issuer: [UInt8] = [], curve: UInt64 = 0
        var reader = ProtoReader(detailsBytes)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .bytes(let b)): name = String(decoding: b, as: UTF8.self)
            // repeated uint32 — упакованно (одна строка varint-ов) или по одному.
            case (2, .bytes(let b)): ips += packedVarints(b).map { UInt32(truncatingIfNeeded: $0) }
            case (2, .varint(let v)): ips.append(UInt32(truncatingIfNeeded: v))
            case (3, .bytes(let b)): subnets += packedVarints(b).map { UInt32(truncatingIfNeeded: $0) }
            case (3, .varint(let v)): subnets.append(UInt32(truncatingIfNeeded: v))
            case (4, .bytes(let b)): groups.append(String(decoding: b, as: UTF8.self))
            case (5, .varint(let v)): notBefore = Int64(bitPattern: v)
            case (6, .varint(let v)): notAfter = Int64(bitPattern: v)
            case (8, .varint(let v)): isCA = v != 0
            case (9, .bytes(let b)): issuer = b
            case (100, .varint(let v)): curve = v
            default: break
            }
        }
        guard !name.isEmpty || notAfter != nil else { return nil }
        return make(version: 1, name: name, networks: v1Networks(ips), unsafe: v1Networks(subnets), groups: groups,
                    notBefore: notBefore, notAfter: notAfter, isCA: isCA, issuer: issuer, p256: curve == 1,
                    fingerprint: hex(Array(SHA256.hash(data: der))), der: der)
    }

    public static func v2(_ der: Data) -> CertificateInfo? {
        guard let top = DER.parse(Array(der)).first, top.tag == 0x30 else { return nil }
        let parts = DER.parse(top.content)
        guard let details = parts.first(where: { $0.tag == 0xA0 }) else { return nil }
        let curve = parts.first { $0.tag == 0x81 }.map { DER.integer($0.content) } ?? 0

        var name = "", groups: [String] = [], networks: [String] = [], unsafe: [String] = []
        var notBefore: Int64?, notAfter: Int64?, isCA = false, issuer: [UInt8] = []
        for item in DER.parse(details.content) {
            switch item.tag {
            case 0x80: name = String(decoding: item.content, as: UTF8.self)
            case 0xA1: networks = DER.parse(item.content).compactMap { v2Network($0.content) }
            case 0xA2: unsafe = DER.parse(item.content).compactMap { v2Network($0.content) }
            case 0xA3: groups = DER.parse(item.content).map { String(decoding: $0.content, as: UTF8.self) }
            case 0x84: isCA = item.content.contains { $0 != 0 }
            case 0x85: notBefore = DER.integer(item.content)
            case 0x86: notAfter = DER.integer(item.content)
            case 0x87: issuer = item.content
            default: break
            }
        }
        guard !name.isEmpty || notAfter != nil else { return nil }
        // Как certificateV2.Fingerprint() в nebula: детали целиком (с тегом и длиной), байт кривой, ключ, подпись.
        let publicKey: [UInt8] = parts.first(where: { $0.tag == 0x82 })?.content ?? []
        let signature: [UInt8] = parts.first(where: { $0.tag == 0x83 })?.content ?? []
        var hashed: [UInt8] = details.raw
        hashed.append(UInt8(truncatingIfNeeded: curve))
        hashed += publicKey
        hashed += signature
        return make(version: 2, name: name, networks: networks, unsafe: unsafe, groups: groups,
                    notBefore: notBefore, notAfter: notAfter, isCA: isCA, issuer: issuer, p256: curve == 1,
                    fingerprint: hex(Array(SHA256.hash(data: hashed))), der: der)
    }

    private static func make(version: Int, name: String, networks: [String], unsafe: [String], groups: [String],
                             notBefore: Int64?, notAfter: Int64?, isCA: Bool, issuer: [UInt8], p256: Bool,
                             fingerprint: String, der: Data) -> CertificateInfo {
        var details: [String] = []
        if isCA { details.append("Центр сертификации (CA)") }
        if !networks.isEmpty { details.append("Сети: " + networks.joined(separator: ", ")) }
        if !unsafe.isEmpty { details.append("Небезопасные сети: " + unsafe.joined(separator: ", ")) }
        if !groups.isEmpty { details.append("Группы: " + groups.joined(separator: ", ")) }
        if p256 { details.append("Кривая P-256") }
        return CertificateInfo(kind: .nebula(version: version), subject: name.isEmpty ? "Без имени" : name, issuer: nil,
                               notBefore: notBefore.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                               notAfter: notAfter.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                               sha256: fingerprint, der: der, isCA: isCA,
                               issuerFingerprint: issuer.isEmpty ? nil : hex(issuer), details: details)
    }

    /// Пары «адрес, маска» (uint32, big-endian) → «10.42.0.5/16».
    private static func v1Networks(_ values: [UInt32]) -> [String] {
        stride(from: 0, to: values.count - 1, by: 2).map { i in
            let ip = values[i]
            let octets = [ip >> 24, ip >> 16 & 0xff, ip >> 8 & 0xff, ip & 0xff].map(String.init)
            return octets.joined(separator: ".") + "/\(values[i + 1].nonzeroBitCount)"
        }
    }

    /// Адрес (4 или 16 байт) и длина префикса одним байтом.
    private static func v2Network(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 5 || bytes.count == 17 else { return nil }
        let prefix = Int(bytes[bytes.count - 1])
        let addr = Array(bytes.dropLast())
        if addr.count == 4 { return addr.map(String.init).joined(separator: ".") + "/\(prefix)" }
        var v6 = in6_addr()
        withUnsafeMutableBytes(of: &v6) { $0.copyBytes(from: addr) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer) + "/\(prefix)"
    }

    private static func packedVarints(_ bytes: [UInt8]) -> [UInt64] {
        var result: [UInt64] = [], value: UInt64 = 0, shift: UInt64 = 0
        for byte in bytes {
            guard shift <= 63 else { return result }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                result.append(value)
                value = 0
                shift = 0
            } else {
                shift += 7
            }
        }
        return result
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// Минимальный разбор DER: тег, длина (короткая и длинная форма), содержимое. Только то, что нужно для Nebula v2.
enum DER {
    struct Item {
        let tag: UInt8
        let content: [UInt8]
        /// Элемент целиком: тег, длина и содержимое.
        let raw: [UInt8]
    }

    static func parse(_ bytes: [UInt8]) -> [Item] {
        var items: [Item] = []
        var i = 0
        while i + 2 <= bytes.count {
            let tag = bytes[i]
            var length = Int(bytes[i + 1])
            var header = 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count >= 1, count <= 4, i + 2 + count <= bytes.count else { return items }
                length = bytes[(i + 2)..<(i + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
                header += count
            }
            guard length >= 0, i + header + length <= bytes.count else { return items }
            items.append(Item(tag: tag, content: Array(bytes[(i + header)..<(i + header + length)]),
                              raw: Array(bytes[i..<(i + header + length)])))
            i += header + length
        }
        return items
    }

    /// Целое со знаком в дополнительном коде, big-endian (до 8 байт).
    static func integer(_ bytes: [UInt8]) -> Int64 {
        guard let first = bytes.first, bytes.count <= 8 else { return 0 }
        var value: Int64 = first & 0x80 != 0 ? -1 : 0
        for byte in bytes { value = value << 8 | Int64(byte) }
        return value
    }
}
