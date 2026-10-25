# Ward

A local password and two-factor authentication manager for macOS, built with SwiftUI and AppKit.

Ward lives in the menu bar. Press **⌥Space** to search your vault from any app, or open the main window to organize personal and work credentials.

## Features

- Passwords, TOTP codes, passkeys, SSH keys, and certificates, including Nebula certificates.
- Personal and work spaces, companies, nested projects, shared services, and multiple environments per entry.
- Quick search, password generation, security audits, reminders, and encrypted editor drafts.
- Site-aware autofill, a Chrome extension, and an SSH agent with approval prompts.
- Encrypted backups, optional backup mirroring, CSV import and export, and Google Authenticator migration.
- Automatic locking, clipboard clearing, and a shortcut to hide sensitive fields: **⌘⇧H**.

## Requirements

- macOS 14 or later.
- A Swift 6 toolchain; the package uses Swift 5 language mode.
- Bun for JavaScript tests and browser test dependencies.
- Google Chrome and an Apple Development signing identity with a Team ID for the browser bridge.

## Build

Run these commands from the project root:

```bash
./build.sh
open Ward.app
```

The build script creates `Ward.app` and signs it with hardened runtime enabled. It prefers an Apple Development identity, then a local development certificate. See [development and signing](docs/DEVELOPMENT.md) for setup and rebuild behavior.

For a debug build:

```bash
./build.sh debug
```

If upgrading an existing installation that used a different application identifier, follow the [vault migration steps](docs/DEVELOPMENT.md#upgrading-from-a-different-application-identifier) before launching the new build.

## Data and security

The encrypted vault is stored in the macOS login Keychain. Ward uses AES-256-GCM and derives the wrapping key from the master password with PBKDF2-SHA256. Encrypted backups are written to `~/Library/Application Support/Ward/Backups`.

The password breach check contacts Have I Been Pwned only after an explicit action and confirmation, using a hash prefix rather than sending the password. The Chrome extension communicates with Ward locally through a native messaging helper.

CSV exports contain readable credentials. Keep exports, keys, certificates, local configuration, and vault backups outside version control; the repository's `.gitignore` excludes their common file formats and locations.

## Tests

```bash
swift test
bun test Tests/BrowserExtensionTests
bun test tools/ward-mcp.test.ts
```

Use the [testing guide](docs/TESTING.md) for coverage, optional dependencies, browser integration tests, and the manual checklist. UI verification uses debug demo modes so it does not touch the real vault.

## Documentation

- [Documentation index](docs/README.md)
- [Development, signing, and demo modes](docs/DEVELOPMENT.md)
- [Architecture and vault model](docs/ARCHITECTURE.md)
- [Testing and manual verification](docs/TESTING.md)
- [Chrome extension permissions](docs/CHROMEWEBSTORE.md)
- [Agent instructions](AGENTS.md)
