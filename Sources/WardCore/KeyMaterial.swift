import Foundation
import CryptoKit
import Security

/// SSH-ключ записи. Любая часть может быть пустой: например, только публичный — чтобы помнить, какой ключ стоит на сервере.
public struct SSHKey: Codable, Hashable, Sendable {
    public var privateKey: String
    public var publicKey: String
    /// Фраза-пароль, которой зашифрован приватный ключ.
    public var passphrase: String
    /// Отдавать ли ключ через SSH-агент Ward (при включённом агенте).
    public var useInAgent: Bool

    public init(privateKey: String = "", publicKey: String = "", passphrase: String = "", useInAgent: Bool = true) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.passphrase = passphrase
        self.useInAgent = useInAgent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey) ?? ""
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        passphrase = try c.decodeIfPresent(String.self, forKey: .passphrase) ?? ""
        useInAgent = try c.decodeIfPresent(Bool.self, forKey: .useInAgent) ?? true
    }

    public var isEmpty: Bool { privateKey.isEmpty && publicKey.isEmpty }

    /// Почему агент не сможет подписать этим ключом. `nil` — сможет (кроме неверной фразы-пароля: её узнать
    /// можно только расшифровкой, а она медленная — это проверяет редактор).
    public var agentProblem: String? { agentReadiness.problem }

    /// Публичный ключ, который агент покажет `ssh`, или причина, почему ключ агенту не годится.
    /// Совпадает с тем, что потом сможет `SSHPrivateKeyLoader`: иначе ssh выбрал бы ключ, а подпись не вышла бы.
    public var agentReadiness: (blob: Data?, problem: String?) {
        guard !privateKey.isEmpty else { return (nil, "нет приватного ключа") }
        guard let info = SSHKeyParser.privateKey(privateKey) else { return (nil, "формат ключа не распознан") }
        switch info.format {
        case "OpenSSH":
            guard let key = info.publicKey else { return (nil, "ключ повреждён") }
            guard SSHSigningKey.supportedTypes.contains(key.type) else {
                return (nil, "тип \(key.label) агент не поддерживает")
            }
            if info.encrypted {
                if let cipher = info.cipher, (try? CipherSpec(cipher)) == nil {
                    return (nil, "шифр \(cipher) — пересохраните: ssh-keygen -p -Z aes256-ctr -f <файл>")
                }
                if passphrase.isEmpty { return (nil, "нужна фраза-пароль ключа") }
            }
            if publicMismatch { return (nil, "публичный ключ записи не от этого приватного") }
            return (key.blob, nil)
        case "PEM":
            // Незашифрованный PEM грузится быстро — так же, как это сделает агент.
            do {
                let loaded = try SSHPrivateKeyLoader.load(privateKey, passphrase: "")
                if let stated = SSHKeyParser.publicKey(publicKey), stated.blob != loaded.publicBlob {
                    return (nil, "публичный ключ записи не от этого приватного")
                }
                return (loaded.publicBlob, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        default:
            return (nil, "ключ PuTTY — сохраните в формате OpenSSH (PuTTYgen → Export OpenSSH key)")
        }
    }
}

/// Сертификат (или цепочка) с приватным ключом — либо контейнер PKCS#12 (.p12/.pfx) как есть.
public struct CertificateBundle: Codable, Hashable, Sendable {
    /// PEM, один или несколько блоков CERTIFICATE.
    public var certificate: String
    public var privateKey: String
    /// Пароль приватного ключа или контейнера .p12.
    public var passphrase: String
    public var pkcs12: Data?

    public init(certificate: String = "", privateKey: String = "", passphrase: String = "", pkcs12: Data? = nil) {
        self.certificate = certificate
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.pkcs12 = pkcs12
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        certificate = try c.decodeIfPresent(String.self, forKey: .certificate) ?? ""
        privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey) ?? ""
        passphrase = try c.decodeIfPresent(String.self, forKey: .passphrase) ?? ""
        pkcs12 = try c.decodeIfPresent(Data.self, forKey: .pkcs12)
    }

    public var isEmpty: Bool { certificate.isEmpty && privateKey.isEmpty && pkcs12 == nil }
}

// MARK: - PEM

public enum PEM {
    public struct Block: Equatable, Sendable {
        public var label: String
        public var headers: [String: String]
        public var der: Data
        /// Исходный текст блока от BEGIN до END включительно.
        public var text: String

        public var isCertificate: Bool { label == "CERTIFICATE" || label == "TRUSTED CERTIFICATE" || label.hasPrefix("NEBULA CERTIFICATE") }
    }

    public static func blocks(in text: String) -> [Block] {
        var result: [Block] = []
        var label: String?
        var lines: [String] = []
        for rawLine in Self.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if label == nil {
                if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                    label = String(line.dropFirst(11).dropLast(5))
                    lines = [line]
                }
                continue
            }
            lines.append(line)
            guard line == "-----END \(label!)-----" else { continue }
            let body = lines.dropFirst().dropLast()
            var headers: [String: String] = [:]
            var base64 = ""
            for bodyLine in body {
                if base64.isEmpty, let colon = bodyLine.firstIndex(of: ":") {
                    headers[String(bodyLine[..<colon])] = bodyLine[bodyLine.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    base64 += bodyLine
                }
            }
            if let der = Data(base64Encoded: base64) {
                result.append(Block(label: label!, headers: headers, der: der, text: lines.joined(separator: "\n") + "\n"))
            }
            label = nil
        }
        return result
    }

    /// По строкам с любыми переводами строки: у `components(separatedBy: .newlines)` CRLF дал бы лишние пустые строки,
    /// и сохранённый из Ward файл Windows-сертификата OpenSSL уже не прочитал бы.
    static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    public static func encode(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }

    /// Приватный ключ в PEM (PKCS#1, SEC1, PKCS#8) и зашифрован ли он.
    public static func privateKey(in text: String) -> (block: Block, encrypted: Bool)? {
        for block in blocks(in: text) where block.label.hasSuffix("PRIVATE KEY") && block.label != "OPENSSH PRIVATE KEY" {
            // «ENCRYPTED PRIVATE KEY» (PKCS#8), «NEBULA ED25519 ENCRYPTED PRIVATE KEY», PKCS#1 с Proc-Type.
            let encrypted = block.label.contains("ENCRYPTED") || block.headers["Proc-Type"]?.contains("ENCRYPTED") == true
            return (block, encrypted)
        }
        return nil
    }
}

// MARK: - SSH

public enum SSHKeyParser {
    public struct PublicKey: Equatable, Sendable {
        public var type: String
        public var blob: Data
        public var comment: String

        /// Как `ssh-keygen -lf`: «SHA256:…» без паддинга.
        public var fingerprint: String {
            let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
        }

        public var line: String {
            ([type, blob.base64EncodedString()] + (comment.isEmpty ? [] : [comment])).joined(separator: " ")
        }

        /// «Ed25519», «RSA 4096», «ECDSA P-256».
        public var label: String {
            switch type {
            case "ssh-ed25519": return "Ed25519"
            case "sk-ssh-ed25519@openssh.com": return "Ed25519-SK"
            case "ssh-rsa": return rsaBits.map { "RSA \($0)" } ?? "RSA"
            case "ssh-dss": return "DSA"
            case let t where t.hasPrefix("ecdsa-sha2-nistp"): return "ECDSA P-" + String(t.dropFirst("ecdsa-sha2-nistp".count))
            case let t where t.hasPrefix("sk-ecdsa-sha2-nistp"): return "ECDSA-SK"
            default: return type
            }
        }

        /// Длина модуля RSA в битах.
        public var rsaBits: Int? {
            guard type == "ssh-rsa" else { return nil }
            var reader = SSHReader(blob)
            guard reader.string() != nil, reader.string() != nil, var modulus = reader.string() else { return nil }
            while modulus.first == 0 { modulus.removeFirst() }
            guard let top = modulus.first else { return nil }
            return (modulus.count - 1) * 8 + (8 - top.leadingZeroBitCount)
        }

        /// Слабый или устаревший ключ — повод заменить.
        public var weakness: String? {
            if type == "ssh-dss" { return "DSA устарел и отключён в современных OpenSSH" }
            if let bits = rsaBits, bits < 2048 { return "RSA \(bits) бит — слишком короткий, нужно от 2048" }
            return nil
        }
    }

    public struct PrivateKeyInfo: Equatable, Sendable {
        /// «OpenSSH», «PEM», «PuTTY».
        public var format: String
        public var encrypted: Bool
        /// Публичная часть, если её можно достать без фразы-пароля (OpenSSH, PuTTY).
        public var publicKey: PublicKey?
        /// Шифр приватной части OpenSSH («none», «aes256-ctr»…).
        public var cipher: String?
    }

    /// Строка вида «ssh-ed25519 AAAA… comment». Тип внутри blob обязан совпадать с заявленным.
    public static func publicKey(_ text: String) -> PublicKey? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2, let blob = Data(base64Encoded: parts[1]) else { return nil }
        var reader = SSHReader(blob)
        guard let inner = reader.string(), String(decoding: inner, as: UTF8.self) == parts[0] else { return nil }
        return PublicKey(type: parts[0], blob: blob, comment: parts.count > 2 ? parts[2] : "")
    }

    public static func privateKey(_ text: String) -> PrivateKeyInfo? {
        if let block = PEM.blocks(in: text).first(where: { $0.label == "OPENSSH PRIVATE KEY" }) {
            return openSSH(block.der)
        }
        if let ppk = putty(text) { return ppk }
        // Ключ Nebula — тоже «PRIVATE KEY» в PEM, но к SSH отношения не имеет.
        if let (block, encrypted) = PEM.privateKey(in: text), !block.label.hasPrefix("NEBULA") {
            return PrivateKeyInfo(format: "PEM", encrypted: encrypted, publicKey: nil)
        }
        return nil
    }

    /// Формат openssh-key-v1: шифр, KDF, число ключей и публичные ключи лежат открыто перед зашифрованной частью.
    private static func openSSH(_ data: Data) -> PrivateKeyInfo? {
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic) else { return nil }
        var reader = SSHReader(data.dropFirst(magic.count))
        guard let cipher = reader.string(), reader.string() != nil, reader.string() != nil,
              let count = reader.uint32(), count >= 1, let blob = reader.string() else { return nil }
        var publicKey: PublicKey?
        var blobReader = SSHReader(blob)
        if let type = blobReader.string() {
            publicKey = PublicKey(type: String(decoding: type, as: UTF8.self), blob: blob, comment: "")
        }
        let cipherName = String(decoding: cipher, as: UTF8.self)
        return PrivateKeyInfo(format: "OpenSSH", encrypted: cipherName != "none", publicKey: publicKey, cipher: cipherName)
    }

    /// PuTTY .ppk v2/v3: «Encryption: none» и «Public-Lines: N» со следующими N строками base64.
    private static func putty(_ text: String) -> PrivateKeyInfo? {
        let lines = PEM.lines(text).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, first.hasPrefix("PuTTY-User-Key-File-") else { return nil }
        var encrypted = true
        var publicKey: PublicKey?
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("Encryption:") {
                encrypted = line.dropFirst("Encryption:".count).trimmingCharacters(in: .whitespaces) != "none"
            } else if line.hasPrefix("Public-Lines:"),
                      let n = Int(line.dropFirst("Public-Lines:".count).trimmingCharacters(in: .whitespaces)),
                      n > 0, n < lines.count - i {
                if let blob = Data(base64Encoded: lines[(i + 1)...(i + n)].joined()) {
                    var reader = SSHReader(blob)
                    if let type = reader.string() {
                        publicKey = PublicKey(type: String(decoding: type, as: UTF8.self), blob: blob, comment: "")
                    }
                }
                i += n
            }
            i += 1
        }
        return PrivateKeyInfo(format: "PuTTY", encrypted: encrypted, publicKey: publicKey)
    }
}

/// Строки и числа в формате SSH (RFC 4251): uint32 длины и затем байты.
struct SSHReader {
    private let data: Data
    private var index: Data.Index

    init<D: DataProtocol>(_ data: D) {
        self.data = Data(data)
        index = self.data.startIndex
    }

    mutating func byte() -> UInt8? {
        guard index < data.endIndex else { return nil }
        defer { index += 1 }
        return data[index]
    }

    mutating func uint32() -> UInt32? {
        guard data.endIndex - index >= 4 else { return nil }
        let value = data[index..<index + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        index += 4
        return value
    }

    /// Всё, что ещё не прочитано.
    var rest: Data { data[index...] }

    mutating func string() -> Data? {
        guard let length = uint32(), UInt64(length) <= UInt64(data.endIndex - index) else { return nil }
        let value = data[index..<index + Int(length)]
        index += Int(length)
        return Data(value)
    }
}

// MARK: - X.509

public enum CertificateKind: Equatable, Sendable {
    case x509
    /// Сертификат оверлейной сети Nebula: не X.509, свой формат (v1 — protobuf, v2 — ASN.1).
    case nebula(version: Int)
}

public struct CertificateInfo: Equatable, Sendable {
    public var kind: CertificateKind = .x509
    public var subject: String
    public var issuer: String?
    public var notBefore: Date?
    public var notAfter: Date?
    /// X.509 — SHA-256 от DER «AB:CD:…» (как `openssl x509 -fingerprint -sha256`); Nebula — как `nebula-cert print`.
    public var sha256: String
    public var der: Data
    public var isCA = false
    /// Для Nebula: отпечаток CA, которым подписан сертификат.
    public var issuerFingerprint: String?
    /// Сети, группы и прочее, что стоит показать рядом с именем.
    public var details: [String] = []

    public func isExpired(at date: Date = Date()) -> Bool { notAfter.map { $0 < date } ?? false }

    /// «X.509», «Nebula v2».
    public var kindLabel: String {
        switch kind {
        case .x509: return "X.509"
        case .nebula(let version): return "Nebula v\(version)"
        }
    }

    /// Этот сертификат отдельным PEM-файлом (например, ca.crt для Nebula).
    public var pem: String {
        switch kind {
        case .x509: return PEM.encode(der, label: "CERTIFICATE")
        case .nebula(let version): return PEM.encode(der, label: version == 1 ? "NEBULA CERTIFICATE" : "NEBULA CERTIFICATE V2")
        }
    }

    /// Истекает в ближайшие `days` дней (но ещё действует).
    public func expiresSoon(at date: Date = Date(), days: Int = 30) -> Bool {
        guard let notAfter, notAfter >= date else { return false }
        return notAfter.timeIntervalSince(date) < TimeInterval(days) * 86400
    }
}

public enum CertificateParser {
    /// Все сертификаты из PEM-текста; первый — обычно сам сертификат, дальше цепочка.
    public static func certificates(in text: String) -> [CertificateInfo] {
        var certs = PEM.blocks(in: text).compactMap(info(block:))
        // Nebula хранит у сертификата только отпечаток CA — если CA лежит рядом, показываем его имя.
        for i in certs.indices where certs[i].kind != .x509 {
            guard let fingerprint = certs[i].issuerFingerprint else { continue }
            certs[i].issuer = certs.first { !$0.sha256.isEmpty && $0.sha256 == fingerprint }?.subject
                ?? "CA " + fingerprint.prefix(12) + "…"
        }
        return certs
    }

    /// Главный сертификат набора: первый не-CA (сам хост), иначе первый.
    public static func primary(in text: String) -> CertificateInfo? {
        let certs = certificates(in: text)
        return certs.first { !$0.isCA } ?? certs.first
    }

    public static func info(block: PEM.Block) -> CertificateInfo? {
        switch block.label {
        case "CERTIFICATE", "TRUSTED CERTIFICATE": return info(der: block.der)
        case "NEBULA CERTIFICATE": return NebulaCertificate.v1(block.der)
        case "NEBULA CERTIFICATE V2": return NebulaCertificate.v2(block.der)
        default: return nil
        }
    }

    public static func info(der: Data) -> CertificateInfo? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Без имени"
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1IssuerName] as CFArray
        let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] ?? [:]
        func date(_ oid: CFString) -> Date? {
            guard let number = values[oid as String]?[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        var issuer: String?
        if let parts = values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] {
            func field(_ oid: String) -> String? {
                parts.first { ($0[kSecPropertyKeyLabel as String] as? String) == oid }?[kSecPropertyKeyValue as String] as? String
            }
            issuer = field("2.5.4.3") ?? field("2.5.4.10")
        }
        let sha256 = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        return CertificateInfo(subject: subject, issuer: issuer, notBefore: date(kSecOIDX509V1ValidityNotBefore),
                               notAfter: date(kSecOIDX509V1ValidityNotAfter), sha256: sha256, der: der)
    }

    /// Файл сертификата: PEM как есть, DER (.cer) — переводится в PEM. `nil` — это не сертификат.
    public static func pem(fromFile data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            let certs = PEM.blocks(in: text).filter { $0.isCertificate && info(block: $0) != nil }
            if !certs.isEmpty { return certs.map(\.text).joined() }
        }
        guard info(der: data) != nil else { return nil }
        return PEM.encode(data, label: "CERTIFICATE")
    }
}

// MARK: - Проблемы ключей

public enum KeyIssues {
    /// Что с ключом и сертификатом стоит исправить: слабый SSH-ключ, сертификат истёк или скоро истечёт.
    public static func issue(ssh: SSHKey?, certificate: CertificateBundle?, at date: Date = Date()) -> String? {
        if let weakness = ssh?.effectivePublicKey?.weakness { return weakness }
        guard let certificate else { return nil }
        // Вся цепочка: истёкший CA Nebula или промежуточный сертификат ломает подключение не хуже своего.
        let certs = CertificateParser.certificates(in: certificate.certificate)
        let primary = CertificateParser.primary(in: certificate.certificate)
        for cert in ([primary].compactMap { $0 } + certs.filter { $0 != primary }) {
            let name = cert == primary ? "Сертификат" : "Сертификат «\(cert.subject)»"
            if cert.isExpired(at: date) { return name + " истёк" }
            if cert.expiresSoon(at: date) { return name + " скоро истечёт" }
        }
        return nil
    }
}

extension Entry {
    /// Только собственные ключ и сертификат записи; со связанными — `Vault.keyIssue(for:)`.
    public func keyIssue(at date: Date = Date()) -> String? {
        KeyIssues.issue(ssh: ssh, certificate: certificate, at: date)
    }
}

// MARK: - Приём из файла или буфера

extension SSHKey {
    /// Что нашлось в тексте: приватный ключ (публичный тогда достаётся из него, если можно) или публичный.
    public enum Absorbed: Equatable { case privateKey, publicKey }

    public mutating func absorb(_ text: String) -> Absorbed? {
        if SSHKeyParser.privateKey(text) != nil {
            // Переводы строк — как в Unix, и обязательно в конце: иначе OpenSSH ключ не прочитает.
            let trimmed = PEM.lines(text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            privateKey = trimmed + "\n"
            if SSHKeyParser.publicKey(publicKey) == nil, let derived = SSHKeyParser.privateKey(trimmed)?.publicKey {
                publicKey = derived.line
            }
            return .privateKey
        }
        if let key = SSHKeyParser.publicKey(text) {
            publicKey = key.line
            return .publicKey
        }
        return nil
    }

    /// Публичный ключ записи не от этого приватного (сравнимо только для OpenSSH и PuTTY).
    public var publicMismatch: Bool {
        guard let fromPrivate = SSHKeyParser.privateKey(privateKey)?.publicKey,
              let stated = SSHKeyParser.publicKey(publicKey) else { return false }
        return fromPrivate.blob != stated.blob
    }

    /// Публичный ключ — указанный или извлечённый из приватного.
    public var effectivePublicKey: SSHKeyParser.PublicKey? {
        SSHKeyParser.publicKey(publicKey) ?? SSHKeyParser.privateKey(privateKey)?.publicKey
    }
}

extension CertificateBundle {
    /// Файл .p12/.pfx, PEM (сертификаты и/или ключ) или DER-сертификат. `false` — ничего не распознано.
    public mutating func absorb(file data: Data, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "p12" || ext == "pfx" {
            pkcs12 = data
            return true
        }
        if let text = String(data: data, encoding: .utf8), absorb(text: text) { return true }
        if let pem = CertificateParser.pem(fromFile: data) {
            certificate = pem
            return true
        }
        return false
    }

    public mutating func absorb(text: String) -> Bool {
        var found = false
        let certs = PEM.blocks(in: text).filter { $0.isCertificate && CertificateParser.info(block: $0) != nil }
        if !certs.isEmpty {
            certificate = certs.map(\.text).joined()
            found = true
        }
        if let key = PEM.privateKey(in: text) {
            privateKey = key.block.text
            found = true
        }
        return found
    }

    public var privateKeyEncrypted: Bool { PEM.privateKey(in: privateKey)?.encrypted ?? false }
}

// MARK: - Связанные ключи

extension Vault {
    /// Свой ключ записи или ключ из связанной. Связь — на один шаг: источник обязан хранить ключ сам, цепочек нет.
    public func sshKey(for entry: Entry) -> (key: SSHKey, source: Entry?)? {
        if let own = entry.ssh { return (own, nil) }
        guard let id = entry.sshKeyEntryID, let source = entries.first(where: { $0.id == id }), let key = source.ssh else {
            return nil
        }
        return (key, source)
    }

    public func certificate(for entry: Entry) -> (bundle: CertificateBundle, source: Entry?)? {
        if let own = entry.certificate { return (own, nil) }
        guard let id = entry.certificateEntryID, let source = entries.first(where: { $0.id == id }),
              let bundle = source.certificate else { return nil }
        return (bundle, source)
    }

    /// Проблемы ключа и сертификата записи, в том числе взятых из связанной записи.
    public func keyIssue(for entry: Entry, at date: Date = Date()) -> String? {
        KeyIssues.issue(ssh: sshKey(for: entry)?.key, certificate: certificate(for: entry)?.bundle, at: date)
    }

    /// Живые записи, которые берут ключ или сертификат у записи `id`.
    public func entriesLinking(to id: UUID) -> [Entry] {
        entries.filter { !$0.isDeleted && ($0.sshKeyEntryID == id || $0.certificateEntryID == id) }
    }

    /// Удаление навсегда. Связи на удалённые записи снимаются, чтобы не висели ссылки в никуда.
    public mutating func purge(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        // Черновик удалённой навсегда записи хранил бы её пароль дальше.
        drafts.removeAll { ids.contains($0.id) }
        for i in entries.indices {
            entries[i].preSteps.removeAll { if case .entry(let id) = $0 { return ids.contains(id) } else { return false } }
            if let id = entries[i].sshKeyEntryID, ids.contains(id) { entries[i].sshKeyEntryID = nil }
            if let id = entries[i].certificateEntryID, ids.contains(id) { entries[i].certificateEntryID = nil }
        }
    }
}
