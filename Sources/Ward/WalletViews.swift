import SwiftUI
import WardCore

struct WalletEditor: View {
    @Binding var wallet: CryptoWallet?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Криптокошелёк").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if wallet != nil {
                    IconButton(systemName: "minus.circle", label: "Убрать кошелёк") { wallet = nil }
                } else {
                    Button("Добавить") { wallet = CryptoWallet() }
                        .buttonStyle(SecondaryButtonStyle(height: 30))
                }
            }
            if wallet != nil {
                FieldLabel(text: "Сеть / блокчейн")
                TextField("Bitcoin, Ethereum, Solana…", text: field(\.network))
                    .autocorrectionDisabled().privacySensitive().wardField()
                FieldLabel(text: "Адрес кошелька")
                TextField("Публичный адрес", text: field(\.address))
                    .autocorrectionDisabled().privacySensitive().wardField()
                FieldLabel(text: "Seed-фраза")
                SecureField("Слова восстановления", text: field(\.seedPhrase))
                    .autocorrectionDisabled().privacySensitive().wardField()
                FieldLabel(text: "Приватный ключ")
                SecureField("Приватный ключ кошелька", text: field(\.privateKey))
                    .autocorrectionDisabled().privacySensitive().wardField()
                FieldLabel(text: "Дополнительная парольная фраза · если есть")
                SecureField("", text: field(\.passphrase))
                    .autocorrectionDisabled().privacySensitive().wardField()
            }
        }
    }

    private func field(_ path: WritableKeyPath<CryptoWallet, String>) -> Binding<String> {
        Binding(get: { wallet?[keyPath: path] ?? "" }, set: { wallet?[keyPath: path] = $0 })
    }
}

struct WalletCard: View {
    let wallet: CryptoWallet
    @State private var revealed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            DetailRow(label: "Криптокошелёк") {
                Text(wallet.network.isEmpty ? "Сеть не указана" : wallet.network)
                    .privacySensitive().font(.system(size: 15)).foregroundStyle(Theme.text)
                Spacer()
            }
            if !wallet.address.isEmpty {
                Hairline()
                DetailRow(label: "Адрес") {
                    Text(wallet.address).privacySensitive().font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.text).textSelection(.enabled)
                    Spacer()
                    IconButton(systemName: "doc.on.doc", label: "Скопировать адрес кошелька") {
                        copy(wallet.address, sensitive: false)
                    }
                }
            }
            secretRow("Seed-фраза", value: wallet.seedPhrase)
            secretRow("Приватный ключ", value: wallet.privateKey)
            secretRow("Парольная фраза", value: wallet.passphrase)
        }
        .cardStyle()
        .onChange(of: wallet) { revealed = [] }
    }

    @ViewBuilder
    private func secretRow(_ label: String, value: String) -> some View {
        if !value.isEmpty {
            Hairline()
            DetailRow(label: label, alignTop: true) {
                Text(revealed.contains(label) ? value : String(repeating: "•", count: 14))
                    .privacySensitive().font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text)
                Spacer()
                IconButton(systemName: revealed.contains(label) ? "eye.slash" : "eye", label: "Показать / скрыть \(label)") {
                    if revealed.contains(label) { revealed.remove(label) } else { revealed.insert(label) }
                }
                IconButton(systemName: "doc.on.doc", label: "Скопировать \(label)") { copy(value, sensitive: true) }
            }
        }
    }

    private func copy(_ value: String, sensitive: Bool) {
        Clipboard.copy(value, sensitive: sensitive)
        Toast.shared.show("Скопировано")
    }
}
