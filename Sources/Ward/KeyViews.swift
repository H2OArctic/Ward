import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WardCore

/// Строка карточки записи: подпись слева, содержимое справа.
struct DetailRow<Content: View>: View {
    let label: String
    var minHeight: CGFloat = 56
    var alignTop = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .frame(width: 110, alignment: .leading)
                .padding(.top, alignTop ? 8 : 0)
            content()
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, alignTop ? 14 : 0)
        .frame(minHeight: minHeight)
    }
}

/// Крупная плитка-кнопка источника: «Найти QR на экране», «Из файла…».
struct SourceTile: View {
    let title: String
    let icon: String
    var highlighted = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(highlighted ? Theme.accent : Theme.textSoft)
                }
                Text(title).font(.system(size: 13)).foregroundStyle(highlighted ? Theme.text : Theme.textSoft)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(highlighted ? Theme.accent.opacity(0.1) : Theme.field, in: RoundedRectangle(cornerRadius: 10))
            .hoverBackground(cornerRadius: 10)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(highlighted ? Theme.accent : Theme.border, lineWidth: highlighted ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// Файлы ключей: выбор (со скрытыми, чтобы был виден ~/.ssh) и сохранение сразу с правами 0600.
@MainActor
enum KeyFiles {
    static let sshDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    private static let maxSize = 1 << 20

    static func pick(in directory: URL? = nil) -> [(url: URL, data: Data)] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if let directory, FileManager.default.fileExists(atPath: directory.path) { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return [] }
        let files = panel.urls.compactMap { url in read(url).map { (url: url, data: $0) } }
        let skipped = panel.urls.filter { url in !files.contains { $0.url == url } }.map(\.lastPathComponent)
        if !skipped.isEmpty {
            Toast.shared.show("Не ключ и не сертификат (больше 1 МБ или не обычный файл): " + skipped.joined(separator: ", "),
                              over: NSApp.keyWindow)
        }
        return files
    }

    /// Только обычный файл разумного размера: FIFO или ссылка на /dev/zero повесили бы окно.
    private static func read(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maxSize else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Соседний `<файл>.pub` — чтобы вместе с приватным ключом подтянуть и комментарий публичного.
    static func companionPublicKey(of file: URL) -> String? {
        read(file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".pub"))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `secret` — приватный ключ или контейнер .p12: о попадании в iCloud предупреждаем.
    static func save(_ data: Data, suggestedName: String, in directory: URL? = nil, secret: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.showsHiddenFiles = true
        if let directory, FileManager.default.fileExists(atPath: directory.path) { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BackupStore.writePrivate(data, to: url)
            let warning = secret ? PlaintextFile.cloudWarning(for: url) : nil
            Toast.shared.show(warning ?? "Сохранено: \(url.lastPathComponent)", over: NSApp.keyWindow)
        } catch {
            Toast.shared.show("Не удалось сохранить: \(error.localizedDescription)", over: NSApp.keyWindow)
        }
    }

    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_")).isEmpty ? "key" : cleaned
    }

    static func sshFileName(_ key: SSHKeyParser.PublicKey?) -> String {
        switch key?.type {
        case "ssh-ed25519": return "id_ed25519"
        case "ssh-rsa": return "id_rsa"
        case let t? where t.contains("ecdsa"): return "id_ecdsa"
        default: return "id_key"
        }
    }
}

// MARK: - Просмотр

struct SSHKeyCard: View {
    let entry: Entry
    let ssh: SSHKey
    /// Запись, из которой взят ключ; `nil` — ключ свой.
    var source: Entry?
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var prefs: Prefs
    @State private var revealPrivate = false
    @State private var revealPhrase = false

    var body: some View {
        let privateInfo = SSHKeyParser.privateKey(ssh.privateKey)
        let publicKey = ssh.effectivePublicKey
        VStack(spacing: 0) {
            LinkRows(entry: entry, source: source, kind: .ssh)
            DetailRow(label: "SSH-ключ") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(publicKey, privateInfo)).font(.system(size: 15)).foregroundStyle(Theme.text)
                    if let publicKey {
                        Text(publicKey.fingerprint).privacySensitive()
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
            }
            if prefs.sshAgentEnabled, !ssh.privateKey.isEmpty {
                Hairline()
                DetailRow(label: "SSH-агент", minHeight: 44) {
                    let problem = ssh.agentProblem
                    Text(!ssh.useInAgent ? "не отдаётся — выключено в записи"
                         : problem.map { "не сможет: \($0)" } ?? "отдаётся ssh и git")
                        .font(.system(size: 13))
                        .foregroundStyle(ssh.useInAgent && problem == nil ? Theme.success : Theme.text2)
                    Spacer()
                }
            }
            if let problem = publicKey?.weakness ?? (ssh.publicMismatch ? "Публичный ключ не от этого приватного" : nil) {
                Hairline()
                DetailRow(label: "Внимание", minHeight: 44) {
                    Text(problem).font(.system(size: 13)).foregroundStyle(Theme.dangerText)
                    Spacer()
                }
            }
            if let publicKey {
                Hairline()
                DetailRow(label: "Публичный") {
                    Text(ssh.publicKey.isEmpty ? publicKey.line : ssh.publicKey)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    IconButton(systemName: "doc.on.doc", label: "Скопировать публичный ключ") {
                        copy(ssh.publicKey.isEmpty ? publicKey.line : ssh.publicKey, sensitive: false, "Публичный ключ скопирован")
                    }
                    IconButton(systemName: "square.and.arrow.down", label: "Сохранить .pub…") {
                        let text = (ssh.publicKey.isEmpty ? publicKey.line : ssh.publicKey) + "\n"
                        KeyFiles.save(Data(text.utf8), suggestedName: KeyFiles.sshFileName(publicKey) + ".pub",
                                      in: KeyFiles.sshDirectory)
                    }
                }
            }
            if !ssh.privateKey.isEmpty {
                Hairline()
                DetailRow(label: "Приватный", alignTop: revealPrivate) {
                    // Без выделения: ⌘C из текста обошёл бы скрытие от менеджеров буфера и автоочистку.
                    Text(revealPrivate ? ssh.privateKey : String(repeating: "•", count: 14))
                        .font(.system(size: revealPrivate ? 11 : 16, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    IconButton(systemName: revealPrivate ? "eye.slash" : "eye", label: revealPrivate ? "Скрыть" : "Показать") {
                        revealPrivate.toggle()
                    }
                    IconButton(systemName: "doc.on.doc", label: "Скопировать приватный ключ") {
                        copy(ssh.privateKey, sensitive: true, "Приватный ключ скопирован")
                    }
                    IconButton(systemName: "square.and.arrow.down", label: "Сохранить в файл…") {
                        KeyFiles.save(Data(ssh.privateKey.utf8), suggestedName: KeyFiles.sshFileName(publicKey),
                                      in: KeyFiles.sshDirectory, secret: true)
                    }
                }
            }
            if !ssh.passphrase.isEmpty {
                Hairline()
                SecretRow(label: "Фраза-пароль", value: ssh.passphrase, reveal: $revealPhrase) {
                    copy(ssh.passphrase, sensitive: true, "Фраза-пароль скопирована")
                }
            }
        }
        .cardStyle()
        .onChange(of: entry.id) {
            revealPrivate = false
            revealPhrase = false
        }
    }

    private func title(_ key: SSHKeyParser.PublicKey?, _ info: SSHKeyParser.PrivateKeyInfo?) -> String {
        var parts = [key?.label ?? "Ключ"]
        if let info {
            parts.append(info.encrypted ? "защищён фразой" : "без фразы-пароля")
        } else if ssh.privateKey.isEmpty {
            parts.append("только публичный")
        }
        if let comment = key?.comment, !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " · ")
    }

    private func copy(_ text: String, sensitive: Bool, _ message: String) {
        Clipboard.copy(text, sensitive: sensitive)
        Task { await store.markUsed(entry.id) }
        Toast.shared.show(message, over: NSApp.keyWindow)
    }
}

struct CertificateCard: View {
    let entry: Entry
    let bundle: CertificateBundle
    var source: Entry?
    @EnvironmentObject private var store: VaultStore
    @State private var revealPhrase = false

    var body: some View {
        let certs = CertificateParser.certificates(in: bundle.certificate)
        let first = CertificateParser.primary(in: bundle.certificate)
        let others = certs.filter { $0 != first }
        let name = KeyFiles.slug(first?.subject ?? entry.title)
        // Nebula ждёт сертификат хоста и CA отдельными файлами; X.509 обычно кладут цепочкой (fullchain).
        let isNebula = first.map { $0.kind != .x509 } ?? false
        VStack(spacing: 0) {
            LinkRows(entry: entry, source: source, kind: .certificate)
            DetailRow(label: "Сертификат", alignTop: true) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(first?.subject ?? (bundle.pkcs12 != nil ? "Контейнер PKCS#12" : "Сертификата нет"))
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text)
                    if let first {
                        validity(first)
                        Text(([first.kindLabel] + (first.issuer.map { ["выдал: \($0)"] } ?? [])).joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text2)
                        ForEach(first.details, id: \.self) { line in
                            Text(line).font(.system(size: 12)).foregroundStyle(Theme.text2).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 5)
                Spacer()
                if !bundle.certificate.isEmpty {
                    IconButton(systemName: "doc.on.doc", label: "Скопировать сертификат (PEM)") {
                        copy(bundle.certificate, sensitive: false, "Сертификат скопирован")
                    }
                    IconButton(systemName: "square.and.arrow.down", label: isNebula ? "Сохранить сертификат хоста…" : "Сохранить .crt…") {
                        KeyFiles.save(Data((isNebula ? first?.pem ?? bundle.certificate : bundle.certificate).utf8),
                                      suggestedName: isNebula ? "host.crt" : name + ".crt")
                    }
                }
            }
            ForEach(Array(others.enumerated()), id: \.offset) { _, cert in
                Hairline()
                DetailRow(label: cert.isCA ? "CA" : "В цепочке", minHeight: 48) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cert.subject).privacySensitive().font(.system(size: 14)).foregroundStyle(Theme.text)
                        validity(cert)
                    }
                    Spacer()
                    IconButton(systemName: "square.and.arrow.down", label: "Сохранить отдельным файлом…") {
                        KeyFiles.save(Data(cert.pem.utf8), suggestedName: cert.isCA ? "ca.crt" : KeyFiles.slug(cert.subject) + ".crt")
                    }
                }
            }
            if let first, !first.sha256.isEmpty {
                Hairline()
                DetailRow(label: first.kind == .x509 ? "SHA-256" : "Отпечаток", minHeight: 48) {
                    Text(first.sha256)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                }
            }
            if !bundle.privateKey.isEmpty {
                Hairline()
                DetailRow(label: "Приватный ключ") {
                    Text((isNebula ? "Nebula" : "PEM") + (bundle.privateKeyEncrypted ? " · зашифрован паролем" : ""))
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    IconButton(systemName: "doc.on.doc", label: "Скопировать приватный ключ") {
                        copy(bundle.privateKey, sensitive: true, "Приватный ключ скопирован")
                    }
                    IconButton(systemName: "square.and.arrow.down", label: "Сохранить .key…") {
                        KeyFiles.save(Data(bundle.privateKey.utf8), suggestedName: isNebula ? "host.key" : name + ".key", secret: true)
                    }
                }
            }
            if let pkcs12 = bundle.pkcs12 {
                Hairline()
                DetailRow(label: "PKCS#12") {
                    Text(Format.fileSize(pkcs12.count) + " · .p12")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    IconButton(systemName: "square.and.arrow.down", label: "Сохранить .p12…") {
                        KeyFiles.save(pkcs12, suggestedName: name + ".p12", secret: true)
                    }
                }
            }
            if !bundle.passphrase.isEmpty {
                Hairline()
                SecretRow(label: "Пароль ключа", value: bundle.passphrase, reveal: $revealPhrase) {
                    copy(bundle.passphrase, sensitive: true, "Пароль ключа скопирован")
                }
            }
        }
        .cardStyle()
        .onChange(of: entry.id) { revealPhrase = false }
    }

    @ViewBuilder
    private func validity(_ info: CertificateInfo) -> some View {
        if let notAfter = info.notAfter {
            if info.isExpired() {
                Text("Истёк \(Format.day(notAfter))").font(.system(size: 12)).foregroundStyle(Theme.danger)
            } else if info.expiresSoon() {
                Text("Истекает \(Format.day(notAfter))").font(.system(size: 12)).foregroundStyle(Theme.accent)
            } else {
                Text("Действует до \(Format.day(notAfter))").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
    }

    private func copy(_ text: String, sensitive: Bool, _ message: String) {
        Clipboard.copy(text, sensitive: sensitive)
        Task { await store.markUsed(entry.id) }
        Toast.shared.show(message, over: NSApp.keyWindow)
    }
}

/// Верх карточки ключа: откуда он взят (для связанной записи) или кто ещё его использует (для исходной).
private struct LinkRows: View {
    enum Kind { case ssh, certificate }

    let entry: Entry
    let source: Entry?
    let kind: Kind
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        if let source {
            DetailRow(label: "Из записи", minHeight: 44) {
                Button { nav.inspecting = nil; nav.open(source) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.system(size: 12))
                        Text(source.title).font(.system(size: 15))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                if source.isDeleted {
                    Text("в корзине").font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                Spacer()
            }
            Hairline()
        } else {
            let users = store.entriesLinking(to: entry.id)
                .filter { kind == .ssh ? $0.sshKeyEntryID == entry.id : $0.certificateEntryID == entry.id }
            if !users.isEmpty {
                DetailRow(label: "Используют", minHeight: 44) {
                    Text(users.map(\.title).joined(separator: ", "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(2)
                    Spacer()
                }
                Hairline()
            }
        }
    }
}

/// Связь есть, а ключа у записи-источника уже нет (его убрали в её редакторе).
struct BrokenLinkCard: View {
    let what: String

    var body: some View {
        DetailRow(label: what, minHeight: 48) {
            Text("Связанная запись больше не хранит его — выберите другой в редакторе")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dangerText)
            Spacer()
        }
        .cardStyle()
    }
}

/// «Взять из другой записи»: меню записей, которые хранят ключ сами (цепочек связей не бывает).
struct LinkMenu: View {
    let title: String
    let candidates: [Entry]
    let detail: (Entry) -> String
    let onPick: (UUID) -> Void

    var body: some View {
        Menu {
            ForEach(candidates) { entry in
                Button(entry.title + (detail(entry).isEmpty ? "" : " — " + detail(entry))) { onPick(entry.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(title)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            .hoverBackground(cornerRadius: 8)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Скрытое значение с «показать» и «скопировать» — фраза-пароль ключа, пароль контейнера.
struct SecretRow: View {
    let label: String
    let value: String
    @Binding var reveal: Bool
    let onCopy: () -> Void

    var body: some View {
        DetailRow(label: label) {
            Text(reveal ? value : String(repeating: "•", count: 14))
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            IconButton(systemName: reveal ? "eye.slash" : "eye", label: reveal ? "Скрыть" : "Показать") { reveal.toggle() }
            IconButton(systemName: "doc.on.doc", label: "Скопировать", action: onCopy)
        }
    }
}

// MARK: - Редактор

struct SSHKeyEditor: View {
    @Binding var ssh: SSHKey?
    @Binding var linkedID: UUID?
    let entryID: UUID
    @EnvironmentObject private var store: VaultStore
    @State private var message: String?
    @State private var isError = false

    private var candidates: [Entry] {
        store.active.filter { $0.id != entryID && $0.ssh != nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var dependants: [Entry] { store.entriesLinking(to: entryID).filter { $0.sshKeyEntryID == entryID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SSH-ключ").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            if let id = linkedID {
                let source = store.entry(id)
                let publicKey = source?.ssh?.effectivePublicKey
                KeySummary(icon: "link",
                           title: source.map { "Ключ из «\($0.title)»" } ?? "Связанная запись удалена",
                           subtitle: [publicKey?.label, publicKey?.fingerprint].compactMap { $0 }.joined(separator: " · "),
                           ok: source?.ssh != nil && source?.isDeleted == false && publicKey?.weakness == nil) { linkedID = nil }
                Text("Ключ хранится в той записи: замените его там — поменяется везде.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            } else if let key = ssh {
                let publicKey = key.effectivePublicKey
                let info = SSHKeyParser.privateKey(key.privateKey)
                KeySummary(icon: "key.horizontal",
                           title: publicKey?.label ?? info?.format ?? "Ключ",
                           subtitle: [info.map { $0.encrypted ? "приватный, защищён фразой" : "приватный, без фразы" }
                                        ?? "только публичный", publicKey?.fingerprint].compactMap { $0 }.joined(separator: " · "),
                           ok: publicKey?.weakness == nil && !key.publicMismatch) { ssh = nil; message = nil }
                if key.privateKey.isEmpty {
                    HStack(spacing: 8) {
                        SourceTile(title: "Приватный из файла…", icon: "doc.badge.plus", action: pickFiles)
                        SourceTile(title: "Приватный из буфера", icon: "doc.on.clipboard", action: paste)
                    }
                }
                FieldLabel(text: "Публичный ключ")
                TextField("ssh-ed25519 AAAA… comment", text: Binding(get: { ssh?.publicKey ?? "" }, set: { ssh?.publicKey = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .wardField()
                FieldLabel(text: info?.encrypted == true ? "Фраза-пароль ключа" : "Фраза-пароль ключа · если есть")
                SecureField("", text: Binding(get: { ssh?.passphrase ?? "" }, set: { ssh?.passphrase = $0 }))
                    .autocorrectionDisabled()
                    .wardField()
                if !key.privateKey.isEmpty {
                    Toggle(isOn: Binding(get: { ssh?.useInAgent ?? true }, set: { ssh?.useInAgent = $0 })) {
                        Text("Отдавать через SSH-агент Ward").font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                    .toggleStyle(.checkbox)
                    agentCheck(key)
                }
                if let weakness = publicKey?.weakness {
                    Text(weakness).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                if key.publicMismatch {
                    Text("Публичный ключ не от этого приватного").font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
            } else {
                HStack(spacing: 8) {
                    SourceTile(title: "Из файла…", icon: "doc.badge.plus", action: pickFiles)
                    SourceTile(title: "Вставить из буфера", icon: "doc.on.clipboard", action: paste)
                }
                if !candidates.isEmpty {
                    LinkMenu(title: "Взять из другой записи", candidates: candidates,
                             detail: { $0.ssh?.effectivePublicKey?.label ?? "" }) { id in
                        // Связь — на один шаг: запись, у которой берут ключ, сама ссылаться на другую не может.
                        guard dependants.isEmpty else {
                            show("Эта запись — источник ключа для: " + dependants.map(\.title).joined(separator: ", ")
                                 + ". Сначала перенастройте их.", error: true)
                            return
                        }
                        linkedID = id
                        ssh = nil
                        message = nil
                    }
                }
            }
            if !dependants.isEmpty {
                Text((ssh == nil ? "Без ключа останутся: " : "Этот ключ используют: ") + dependants.map(\.title).joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(ssh == nil ? Theme.danger : Theme.text2)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(isError ? Theme.danger : Theme.text2)
            }
        }
    }

    @State private var agentVerdict: (ok: Bool, text: String)?

    /// Настоящая проверка: расшифровать ключ фразой-паролем, как это сделает агент (в фоне — bcrypt небыстрый).
    @ViewBuilder
    private func agentCheck(_ key: SSHKey) -> some View {
        Group {
            if let problem = key.agentProblem {
                Text("Агент не сможет использовать ключ: \(problem)").foregroundStyle(Theme.danger)
            } else if let verdict = agentVerdict {
                Text(verdict.text).foregroundStyle(verdict.ok ? Theme.success : Theme.danger)
            } else {
                Text("Проверяю ключ…").foregroundStyle(Theme.text3)
            }
        }
        .font(.system(size: 12))
        .task(id: key.privateKey + "\u{0}" + key.passphrase) {
            agentVerdict = nil
            guard key.agentProblem == nil else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let privateKey = key.privateKey, passphrase = key.passphrase
            let check = Task.detached(priority: .userInitiated) { () -> (Bool, String) in
                do {
                    _ = try SSHPrivateKeyLoader.load(privateKey, passphrase: passphrase)
                    return (true, "Ключ в порядке — агент сможет им подписывать")
                } catch {
                    return (false, "Агент не сможет использовать ключ: \(error.localizedDescription)")
                }
            }
            // Фразу-пароль поправили или лист закрыли — bcrypt в фоне останавливается, а не молотит минутами.
            let result = await withTaskCancellationHandler { await check.value } onCancel: { check.cancel() }
            if !Task.isCancelled { agentVerdict = result }
        }
    }

    private func pickFiles() {
        var key = ssh ?? SSHKey()
        var tookPrivate = false, recognized = false
        for file in KeyFiles.pick(in: KeyFiles.sshDirectory) {
            guard let text = String(data: file.data, encoding: .utf8), let kind = key.absorb(text) else { continue }
            recognized = true
            if kind == .privateKey {
                tookPrivate = true
                if let pub = KeyFiles.companionPublicKey(of: file.url) { _ = key.absorb(pub) }
            }
        }
        guard recognized else {
            show("В выбранных файлах нет SSH-ключа", error: true)
            return
        }
        ssh = key
        show(tookPrivate ? nil : "Добавлен только публичный ключ", error: false)
    }

    private func paste() {
        var key = ssh ?? SSHKey()
        guard let text = NSPasteboard.general.string(forType: .string), let kind = key.absorb(text) else {
            show("В буфере нет SSH-ключа", error: true)
            return
        }
        ssh = key
        if kind == .privateKey {
            Clipboard.clear()
            show("Приватный ключ взят из буфера, буфер очищен", error: false)
        } else {
            show(nil, error: false)
        }
    }

    private func show(_ text: String?, error: Bool) {
        message = text
        isError = error
    }
}

struct CertificateEditor: View {
    @Binding var certificate: CertificateBundle?
    @Binding var linkedID: UUID?
    let entryID: UUID
    @EnvironmentObject private var store: VaultStore
    @State private var message: String?
    @State private var isError = false

    private var candidates: [Entry] {
        store.active.filter { $0.id != entryID && $0.certificate != nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var dependants: [Entry] { store.entriesLinking(to: entryID).filter { $0.certificateEntryID == entryID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сертификат").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            if let id = linkedID {
                let source = store.entry(id)
                let first = source?.certificate.flatMap { CertificateParser.primary(in: $0.certificate) }
                KeySummary(icon: "link",
                           title: source.map { "Сертификат из «\($0.title)»" } ?? "Связанная запись удалена",
                           subtitle: [first?.subject, first?.notAfter.map { "до " + Format.day($0) }].compactMap { $0 }
                               .joined(separator: " · "),
                           ok: source?.certificate != nil && source?.isDeleted == false && !(first?.isExpired() ?? false)) {
                    linkedID = nil
                }
                Text("Сертификат хранится в той записи: обновите его там — поменяется везде.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            } else if let bundle = certificate {
                let first = CertificateParser.primary(in: bundle.certificate)
                KeySummary(icon: "checkmark.seal",
                           title: first?.subject ?? (bundle.pkcs12 != nil ? "Контейнер PKCS#12" : "Только приватный ключ"),
                           subtitle: summary(bundle, first),
                           ok: !(first?.isExpired() ?? false)) { certificate = nil; message = nil }
                HStack(spacing: 8) {
                    SourceTile(title: "Добавить файл…", icon: "doc.badge.plus", action: pickFiles)
                    SourceTile(title: "Из буфера", icon: "doc.on.clipboard", action: paste)
                }
                if !bundle.privateKey.isEmpty || bundle.pkcs12 != nil {
                    FieldLabel(text: bundle.pkcs12 != nil ? "Пароль контейнера .p12" : "Пароль приватного ключа · если есть")
                    SecureField("", text: Binding(get: { certificate?.passphrase ?? "" }, set: { certificate?.passphrase = $0 }))
                        .autocorrectionDisabled()
                        .wardField()
                }
            } else {
                HStack(spacing: 8) {
                    SourceTile(title: "Из файлов…", icon: "doc.badge.plus", action: pickFiles)
                    SourceTile(title: "Вставить из буфера", icon: "doc.on.clipboard", action: paste)
                }
                Text(".crt, .pem, .cer, .key, .p12, Nebula (host.crt, ca.crt, host.key) — можно выбрать всё сразу")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                if !candidates.isEmpty {
                    LinkMenu(title: "Взять из другой записи", candidates: candidates, detail: {
                        $0.certificate.flatMap { CertificateParser.primary(in: $0.certificate).map { "\($0.subject) · \($0.kindLabel)" } } ?? ""
                    }) { id in
                        guard dependants.isEmpty else {
                            show("Эта запись — источник сертификата для: " + dependants.map(\.title).joined(separator: ", ")
                                 + ". Сначала перенастройте их.", error: true)
                            return
                        }
                        linkedID = id
                        certificate = nil
                        message = nil
                    }
                }
            }
            if !dependants.isEmpty {
                Text((certificate == nil ? "Без сертификата останутся: " : "Этот сертификат используют: ")
                     + dependants.map(\.title).joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(certificate == nil ? Theme.danger : Theme.text2)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(isError ? Theme.danger : Theme.text2)
            }
        }
    }

    private func summary(_ bundle: CertificateBundle, _ first: CertificateInfo?) -> String {
        var parts: [String] = first.map { [$0.kindLabel] } ?? []
        if let notAfter = first?.notAfter {
            parts.append((first!.isExpired() ? "истёк " : "до ") + Format.day(notAfter))
        }
        if !bundle.privateKey.isEmpty { parts.append(bundle.privateKeyEncrypted ? "ключ зашифрован" : "с ключом") }
        if bundle.pkcs12 != nil { parts.append(".p12") }
        if bundle.privateKey.isEmpty && bundle.pkcs12 == nil { parts.append("без приватного ключа") }
        return parts.joined(separator: " · ")
    }

    private func pickFiles() {
        var bundle = certificate ?? CertificateBundle()
        let files = KeyFiles.pick()
        guard !files.isEmpty else { return }
        var unknown: [String] = []
        for file in files where !bundle.absorb(file: file.data, name: file.url.lastPathComponent) {
            unknown.append(file.url.lastPathComponent)
        }
        guard unknown.count < files.count else {
            show("Не похоже на сертификат или ключ: " + unknown.joined(separator: ", "), error: true)
            return
        }
        certificate = bundle
        show(unknown.isEmpty ? nil : "Пропущено: " + unknown.joined(separator: ", "), error: !unknown.isEmpty)
    }

    private func paste() {
        var bundle = certificate ?? CertificateBundle()
        guard let text = NSPasteboard.general.string(forType: .string), bundle.absorb(text: text) else {
            show("В буфере нет сертификата или ключа в PEM", error: true)
            return
        }
        certificate = bundle
        if PEM.privateKey(in: text) != nil {
            Clipboard.clear()
            show("Приватный ключ взят из буфера, буфер очищен", error: false)
        } else {
            show(nil, error: false)
        }
    }

    private func show(_ text: String?, error: Bool) {
        message = text
        isError = error
    }
}

/// Итог в редакторе: «2FA подключена», SSH-ключ, сертификат. Справа — необязательное дополнение (код 2FA).
struct KeySummary<Accessory: View>: View {
    let icon: String
    let title: String
    var detail: String?
    let subtitle: String
    let ok: Bool
    let onRemove: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill((ok ? Theme.success : Theme.danger).opacity(0.14))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(ok ? Theme.success : Theme.danger))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textChip).lineLimit(1).truncationMode(.tail)
                }
                Text(subtitle).privacySensitive().font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
            IconButton(systemName: "xmark.circle", label: "Убрать", action: onRemove)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((ok ? Theme.success : Theme.danger).opacity(0.3)))
    }
}

extension KeySummary where Accessory == EmptyView {
    init(icon: String, title: String, detail: String? = nil, subtitle: String, ok: Bool, onRemove: @escaping () -> Void) {
        self.init(icon: icon, title: title, detail: detail, subtitle: subtitle, ok: ok, onRemove: onRemove) { EmptyView() }
    }
}
