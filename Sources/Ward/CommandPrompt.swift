import AppKit
import SwiftUI
import WardCore

@MainActor
final class CommandPrompt {
    private let approvals = ApprovalQueue<Int>()
    private var panel: KeyPanel?

    func cancelAll() { approvals.cancelAll() }

    func select(_ servers: [CommandServerMatch], query: String, caller: String) async -> Int? {
        await present(.selection(servers: servers, query: query, caller: caller))
    }

    func authorize(_ server: CommandServerMatch, caller: String, command: [String], rememberMinutes: Int) async -> Int? {
        await present(.authorization(server: server, caller: caller, command: command, rememberMinutes: rememberMinutes))
    }

    private func present(_ content: CommandPromptContent) async -> Int? {
        await approvals.ask(show: { [self] finish in
            let panel = self.panel ?? makePanel()
            panel.contentView = NSHostingView(rootView: CommandPromptView(content: content, onChoice: finish))
            let size = panel.contentView?.fittingSize ?? NSSize(width: 480, height: 240)
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrame(NSRect(x: frame.midX - size.width / 2,
                    y: frame.maxY - frame.height * 0.2 - size.height,
                    width: size.width, height: size.height), display: true)
            }
            Foreground.show(panel)
        }, close: { [weak self] in self?.panel?.orderOut(nil) })
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        self.panel = panel
        return panel
    }
}

private enum CommandPromptContent {
    case selection(servers: [CommandServerMatch], query: String, caller: String)
    case authorization(server: CommandServerMatch, caller: String, command: [String], rememberMinutes: Int)
}

private struct CommandPromptView: View {
    let content: CommandPromptContent
    let onChoice: (Int?) -> Void
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch content {
            case let .selection(servers, query, caller):
                header("Выберите сервер", subtitle: "Поиск: \(query)", caller: caller, icon: "server.rack")
                if servers.count > 4 {
                    ScrollView { serverChoices(servers) }
                        .frame(height: 360)
                } else {
                    serverChoices(servers)
                }
                footer("В Codex уйдёт только ID этой записи", cancel: "Отмена")
            case let .authorization(server, caller, command, minutes):
                header("Выполнить через sudo?", subtitle: "С правами root", caller: caller, icon: "terminal")
                CommandServerRow(server: server, selectable: false)
                commandPreview(command)
                if minutes > 0 {
                    Text("Разрешение на время действует для любых sudo-команд этого сервера до блокировки Ward.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                HStack(spacing: 8) {
                    Button("Отклонить") { onChoice(nil) }
                        .buttonStyle(SecondaryButtonStyle(height: 32))
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                    if minutes > 0 {
                        Button("На \(minutes) мин.") { onChoice(1) }
                            .buttonStyle(SecondaryButtonStyle(height: 32))
                            .disabled(!armed)
                    }
                    Button("Один раз") { onChoice(0) }
                        .buttonStyle(AccentButtonStyle(height: 32))
                        .disabled(!armed)
                }
                .padding(.top, 16)
            }
        }
        .padding(16)
        .frame(width: 480)
        .focusEffectDisabled()
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
        .environment(\.colorScheme, .dark)
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            armed = true
        }
    }

    private func header(_ title: String, subtitle: String, caller: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text2)
                    .lineLimit(2).privacySensitive()
            }
            Spacer(minLength: 8)
            Text((caller as NSString).lastPathComponent == "ward" ? "Ward MCP" : (caller as NSString).lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.text2)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Theme.control, in: Capsule())
                .help(caller)
                .privacySensitive()
        }
        .padding(.bottom, 14)
    }

    private func serverChoices(_ servers: [CommandServerMatch]) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(servers.enumerated()), id: \.element.entryID) { index, server in
                Button { onChoice(index) } label: { CommandServerRow(server: server, selectable: true) }
                    .buttonStyle(.plain)
                    .disabled(!armed)
                    .pointingHandCursor(armed)
            }
        }
    }

    private func footer(_ text: String, cancel: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text(text).font(.system(size: 10))
            Spacer(minLength: 4)
            Button(cancel) { onChoice(nil) }
                .buttonStyle(SecondaryButtonStyle(height: 28))
                .keyboardShortcut(.cancelAction)
        }
        .foregroundStyle(Theme.text2)
        .padding(.top, 12)
    }

    private func commandPreview(_ arguments: [String]) -> some View {
        let command = arguments.map(SudoRequest.quote).joined(separator: " ")
        return VStack(alignment: .leading, spacing: 6) {
            Text("КОМАНДА").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
            Group {
                if command.count > 240 {
                    ScrollView {
                        Text(command).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                } else {
                    Text(command).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .privacySensitive()
            .padding(10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 12)
    }
}

private struct CommandServerRow: View {
    let server: CommandServerMatch
    let selectable: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(server.title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text).lineLimit(2)
                    Spacer(minLength: 0)
                    ForEach(server.environments, id: \.self) { EnvBadge(env: $0) }
                }
                Text(server.location).font(.system(size: 11)).foregroundStyle(Theme.text2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(server.location)
                Text("\(server.login)@\(server.host)" + (server.port == 22 ? "" : ":\(server.port)"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSoft)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if selectable {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.accent : Theme.text3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering && selectable ? Theme.cardHover : Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hovering && selectable ? Theme.accent.opacity(0.4) : Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .privacySensitive()
    }
}
