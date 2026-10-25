import Foundation

/// Поле «Адрес» записи: сайт, IP, IP:порт, IPv6 (в том числе без скобок), `user@host:port`, `ssh://…`.
public struct EntryAddress: Equatable, Sendable {
    public var scheme: String?
    public var user: String?
    /// Без квадратных скобок, даже для IPv6.
    public var host: String
    public var port: Int?

    /// Порты, на которых обычно веб-интерфейс: «10.0.0.5:8080» открывается в браузере, «10.0.0.5:22» — нет.
    static let webPorts: Set<Int> = [80, 443, 3000, 5000, 5601, 8000, 8008, 8080, 8081, 8088, 8443, 8888, 9000, 9090, 9443]

    public static func parse(_ raw: String) -> EntryAddress? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        // Голый IPv6 («2001:db8::1») URLComponents не разбирает: двоеточия принимаются за порт.
        if isIPv6(text) { return EntryAddress(scheme: nil, user: nil, host: text, port: nil) }
        let hasScheme = text.contains("://")
        guard let comps = URLComponents(string: hasScheme ? text : "//" + text),
              var host = comps.host, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let port = comps.port, !(1...65535).contains(port) { return nil }
        let user = comps.user.flatMap { $0.isEmpty ? nil : $0 }
        // «-oProxyCommand=…» — не хост и не логин, а опция ssh, которая выполнила бы команду.
        guard !host.hasPrefix("-"), user?.hasPrefix("-") != true else { return nil }
        return EntryAddress(scheme: hasScheme ? comps.scheme?.lowercased() : nil, user: user, host: host, port: comps.port)
    }

    public var isIP: Bool { Self.isIPv4(host) || Self.isIPv6(host) }

    /// «host», «host:port», «[v6]:port» — как его набирают в терминале и конфигах.
    public var hostPort: String {
        let shown = Self.isIPv6(host) && port != nil ? "[\(host)]" : host
        return port.map { "\(shown):\($0)" } ?? shown
    }

    public var isWeb: Bool {
        if let scheme { return scheme == "http" || scheme == "https" }
        guard let port else { return true }
        return Self.webPorts.contains(port)
    }

    /// Для «Открыть в браузере». Без схемы: 443/8443 и без порта — https, остальные веб-порты — http.
    public func webURL(original raw: String) -> URL? {
        guard isWeb else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if scheme != nil { return URL(string: text) }
        let secure = port == nil || port == 443 || port == 8443
        // Голый IPv6 в ссылке нужен в скобках: «https://2001:db8::1» не разбирается.
        let authority = Self.isIPv6(host) ? "[\(host)]" + (port.map { ":\($0)" } ?? "") : text
        return URL(string: (secure ? "https://" : "http://") + authority)
    }

    public var looksLikeSSH: Bool { scheme == "ssh" || port == 22 }

    /// `ssh -p 2222 -- admin@10.0.0.5`. Логин и хост в кавычках, если в них есть что-то кроме безопасных символов;
    /// `--` не даёт логину из записи («-oProxyCommand=…») стать опцией ssh.
    public func sshCommand(login: String) -> String {
        var parts = ["ssh"]
        if let port, port != 22 { parts += ["-p", String(port)] }
        let user = user ?? login.trimmingCharacters(in: .whitespaces)
        parts += ["--", Self.shellQuoted(user.isEmpty ? host : "\(user)@\(host)")]
        return parts.joined(separator: " ")
    }

    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    static func isIPv6(_ text: String) -> Bool {
        var addr = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }
}
