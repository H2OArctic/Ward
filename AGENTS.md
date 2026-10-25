# Agent instructions

Ward is a local password and 2FA manager for macOS. This file is the single source of repository instructions for coding agents.

## Working references

- Read [development](docs/DEVELOPMENT.md) before building, signing, generating icons, or running demo modes.
- Read [architecture](docs/ARCHITECTURE.md) before changing vault storage, entry relationships, SSH, autofill, or the browser bridge.
- Read [testing](docs/TESTING.md) when selecting automated checks or verifying UI behavior.
- Read [extension permissions](docs/CHROMEWEBSTORE.md) before changing Chrome permissions or page-script boundaries.

## Build and verification

- Build with `./build.sh`; use `./build.sh debug` for snapshots and integration demos. Run Swift tests with `swift test`.
- Use Bun for JavaScript dependencies and tests: `bun install`, `bun test Tests/BrowserExtensionTests`, and `bun test tools/ward-mcp.test.ts`.
- The toolchain is Swift 6 in Swift 5 language mode (`swiftLanguageModes: [.v5]`), targeting macOS 14 or later.
- Use `WARD_SNAPSHOT` for UI verification; it uses demo data and does not access the real vault. Use a debug demo build and a temporary Chrome profile for browser integration checks.
- A self-signed build can block on a Keychain prompt after rebuilding. Normal browser bridge operation requires an Apple Development Team ID.
- Keep app, Keychain, native messaging, and helper signing identifiers consistent with `WardIdentity`. Build and extension constants must match it. When changing identifiers, follow the explicit migration workflow in the development guide; tests and builds must never migrate a real vault.

## Storage and compatibility

- Add new `Entry` fields with `decodeIfPresent` in `init(from:)` so existing vaults remain readable.
- Preserve `Tests/WardCoreTests/Fixtures/vault-v1.json`. For a format change, increment `Vault.currentFormat`, add a migration, and add a new fixture alongside the old one.
- Keep vault lifecycle logic in `VaultSession`; `VaultStore` publishes state and performs key derivation off the main thread.
- Preserve project cycle checks, company boundaries, dangling-reference handling, and legacy field decoding described in the architecture guide.
- `purge` must remove links to deleted connections and key sources. Linked keys do not support chains.
- Keep drafts encrypted and outside search, audit, exports, and backup merges.
- Keep security settings in `Vault.security`; pre-unlock security state belongs in `VaultEnvelope`, not UserDefaults.
- A backup failure must not roll back a successful vault write. Preserve external-change detection and vault-key rotation on master-password changes.
- Generate test keys at runtime with `ssh-keygen` or `openssl`. Keep private keys, credentials, exports, and real vault data out of the repository.
- The HIBP network check requires an explicit action and confirmation.

## UI and source conventions

- Write documentation in English. Keep UI strings and necessary code comments in Russian.
- Keep comments minimal; explain only non-obvious reasons. Leave existing comments alone unless the adjacent code changes.
- Use `Theme` and `Format` for colors and formatting rather than hardcoded values in views.
- Add `.focusEffectDisabled()` to every new sheet. Use `wardField`, `hoverBackground`, and `hoverLink` consistently with surrounding views.
- Mark new login, address, code, and value fields with `.privacySensitive()` so Hide Data mode covers them.
- Treat `Sources/WardCore/PublicSuffixList.swift` as generated data; update it with `swift tools/update-psl.swift`.
