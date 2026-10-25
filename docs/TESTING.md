# Testing Ward

Run commands from the repository root. This guide describes available coverage and manual procedures; it is not a record of a test run for the current build.

## Automated checks

```bash
swift test
bun test Tests/BrowserExtensionTests
bun test tools/ward-mcp.test.ts
```

Swift tests cover both `WardCore` and app lifecycle behavior. Browser extension tests run the real extension scripts with controlled Chrome and Ward responses. The CLI MCP tests live in `tools/ward-mcp.test.ts`.

| Coverage | Tests or command |
|---|---|
| TOTP: RFC 6238 and 120 vectors from an independent Python `hmac` implementation | `TOTPReferenceTests` |
| Opening a version 0.1 vault in a newer build | `CompatibilityTests`, using `Fixtures/vault-v1.json` |
| Explicit encrypted-vault migration preserves bytes, drafts, security settings, and counters; never overwrites an existing destination or modifies the source; read failures and concurrent destination creation are safe | `VaultMigrationTests`, using in-memory storage only |
| A failed write changes neither memory nor Keychain storage | `VaultSessionTests.testFailedWriteChangesNothing` |
| Creating a vault cannot overwrite existing or unreadable storage | `testCreateNeverOverwritesExistingVault`, `testUnreadableStorageBlocksSetup` |
| A wrong password or a modified data/key byte produces an error | `testWrongPasswordAndTampering` |
| Master-password changes and backups: permissions of `0600`, pruning, and password-based opening | `testChangePassword`, `testBackupsAreWrittenPrunedAndOpenable` |
| Refusing unsupported newer vault formats | `testNewerFormatsAreRefusedNotMisread` |
| Unicode normalization, including Cyrillic characters, emoji, and long passwords | `CryptoEdgeTests` |
| Real Keychain integration with a separate test service, removed afterward | `KeychainIntegrationTests` |
| CSV quoting, line breaks, Excel semicolons, and malformed input | `CSVTests`, `ImportAndReminderEdgeTests` |
| Reminder month boundaries and scheduling the 31st in February | `ReminderTests`, `ImportAndReminderEdgeTests` |
| Password generator length, character classes, and uniqueness across 1,000 passwords | `GeneratorPropertyTests` |
| Google Authenticator export: public sample, multiple codes, skipped HOTP entries, base64 variants, malformed input | `GoogleAuthMigrationTests` |
| Backup mirroring: new copies only, deduplication, pruning, and no local directory creation for a disconnected disk | `BackupMirrorTests` |
| Backup failures do not undo saved changes, including master-password changes, or leave memory behind Keychain storage | `AuditRegressionTests` |
| Ordering backups created in the same millisecond; pruning preserves manual exports; files start with `0600` permissions | `AuditRegressionTests` |
| NUL does not truncate passwords; slots with four billion iterations or another KDF are rejected | `AuditRegressionTests` |
| Environment renaming, duplicate-free CSV, security settings in the vault, master-password policy, and site matching | `AuditRegressionTests` |
| OpenSSH, PEM, PuTTY, encrypted SSH keys, PEM/DER certificate chains, and PKCS#12 containers; fingerprints compared with freshly generated `ssh-keygen` and `openssl` material | `KeyMaterialTests` |
| IP addresses, ports, bracketed and unbracketed IPv6, `user@host:port`, and `ssh` commands | `KeyMaterialTests.testAddressForms` |
| Nebula v1/v2 names, IPv4/IPv6 networks, groups, expiration, CA status, and fingerprints compared with `nebula-cert print -json` | `NebulaTests` |
| SSH agent: OpenSSH, PEM, PKCS#8, bcrypt passphrases, AES CTR/CBC/GCM; OpenSSH signature verification through `ssh-add -L/-T`, `ssh-keygen -Y sign`, and `-Y check-novalidate`; refusal, disallowed key addition, and existing live sockets | `SSHAgentTests` |
| Linked keys resolve from their source without chains, and links are removed when the source is purged | `KeyMaterialTests.testLinkedKeysResolveAndSurvivePurge` |
| Custom fields, exclusion of hidden fields from search, HTTP and old-password audits, five-character hash-prefix breach requests, and CSV round trips | `FeatureTests` |
| Companies, project trees, cycle and company checks, damaged references, project/shared service accounts, deletion without lost entries, empty-company deletion, and migration of legacy integrations | `ProjectTreeTests` |
| Pre-login steps: legacy strings, connection references, company boundaries, and purging deleted connections | `ConnectionTests` |
| One encrypted draft per entry, restart persistence, removal with permanent entry deletion, exclusion from merges and exports | `DraftTests` |
| Passkeys: RFC 8949 CBOR, rpId rejection for unrelated domains/public suffixes/non-HTTPS, clientDataJSON, signatures, and optional py_webauthn verification | `PasskeyTests` |
| Browser bridge: native messaging frames, request parsing, site-scoped credentials, phishing rejection, revalidation before password release, and passkeys | `BrowserBridgeTests` |
| Approval cancellation, late responses, limits and timeouts; serial background writes, failed writes, and drafts on lock | `LifecycleTests` |
| Locking or deleting during passkey approval, SSH key revocation, concurrent editor changes, and waiting for writes on quit | `AppLifecycleTests` |
| Browser socket request limits, cancellation at capacity, disconnects, and refusal to replace a live socket | `BrowserServerTests` |
| Extension navigation, document replacement, rejection of page-originated password requests, WebAuthn cancellation/timeouts, and iframes | `bun test Tests/BrowserExtensionTests` |
| Real Chrome → extension → helper → Ward → website; form filling and passkeys with py_webauthn as the server | `tools/browser-e2e/run.sh`, using a debug build |
| Public Suffix List matching against official vectors and shared hosting such as `*.s3.amazonaws.com` | `PublicSuffixTests` |
| Concurrent vault access rejects stale writes; master-password changes rotate the vault key | `HardeningTests` |
| Untrusted input: huge PuTTY `Public-Lines`, protobuf with hundreds of thousands of fields, `-oProxyCommand=…` addresses, generator length from UserDefaults, and bcrypt cancellation | `HardeningTests` |
| Failed-unlock counter and agent-enabled state survive restart in the Keychain envelope; old settings without new fields decode | `HardeningTests` |
| Temporary approval is unavailable to direct shell SSH clients and unverified signatures; unsigned parent names show full paths | `SSHAgentTests` |
| Agent clients are identified by audit token and signature; system `ssh-add` is Apple-signed, custom `ssh` shows its full path, and prompts strip control characters | `SSHAgentTests` |

Keep `Tests/WardCoreTests/Fixtures/vault-v1.json` unchanged. When changing the format, increment `Vault.currentFormat`, implement a migration, and add a new fixture alongside the old one.

The existing testing notes record mutation checks: deliberately corrupting `VaultSession.update` or password normalization caused tests to fail. This is historical evidence, not a fresh mutation-test result.

## Optional tools and isolated modes

- Nebula comparisons require `nebula-cert` (`brew install nebula`). Those checks are skipped when it is unavailable.
- Passkey reference verification uses `WARD_PYTHON` to select a Python interpreter with `webauthn`. Those comparisons are skipped when it is unavailable.
- The Chrome end-to-end runner requires a debug build, Bun, Google Chrome, and Python with `webauthn`. It uses `PYTHON`, defaulting to `python3`.
- Key tests generate their keys with system `ssh-keygen` and `openssl`. Never add real private keys to test fixtures.
- UI verification uses `WARD_SNAPSHOT` demo data. Browser end-to-end checks use a temporary Chrome profile and demo Ward.

See [development](DEVELOPMENT.md) for build commands, signing requirements, snapshots, and demo modes.

## Manual checklist

Run these checks on disposable test data before trusting a build with real credentials. Hotkeys, focus, macOS permissions, and clipboard integration require manual verification. UI labels below are described in English; the app currently uses Russian labels.

1. **First launch:** create a master password, add an entry, quit with ⌘Q, reopen, and unlock. The entry is still present.
2. **Wrong password:** an incorrect password shows an error and does not unlock the vault.
3. **Rebuild:** run `./build.sh` and reopen. With a self-signed identity, macOS asks for Keychain access once; choose Always Allow. No further prompt appears until the next rebuild. Access tied to an Apple Development Team ID survives rebuilds.
4. **Quick panel:** press ⌥Space from another app, type immediately into search, navigate with ↑/↓, press Return, and paste into the browser with ⌘V.
5. **Clipboard:** copy a password and wait for the configured clearing interval, for example 30 seconds. Pasting no longer reveals it, and Raycast/Maccy history does not retain it.
6. **TOTP:** display a QR code in a browser and use the screen QR scanner. The code matches Google Authenticator or the website.
7. **Locking:** set automatic locking to one minute and wait. Ward locks. Lock the screen with ⌃⌘Q; Ward locks and closes Settings, and the Settings action becomes unavailable.
8. **Master-password change:** change the password, quit, and reopen. The new password works; the old one does not.
9. **Encrypted backup:** export, then restore that backup with the same password. Zero entries are added because duplicates are skipped.
10. **Apple Passwords CSV import:** import a CSV exported from Apple Passwords. Entries and TOTP codes are present. Delete the plaintext CSV afterward.
11. **Quick autofill:** on a login page, press ⇧Return in the panel. Username and password go to their fields, and the clipboard receives the TOTP code. ⌥Return fills only the password. Check Safari and Chrome password fields.
12. **Google Authenticator:** export codes, take a screenshot, and import from images. Codes match the phone. Importing again reports existing entries.
13. **Backup mirror:** choose a directory on an external disk and trigger a copy. Disconnect the disk: Settings reports it is unavailable, and nothing is created under `/Volumes`. Reconnect it: mirroring catches up automatically.
14. **Autofill and phishing:** save an entry for github.com and open another site in Safari. ⇧Return cancels without filling. On github.com it fills. Open the panel, then switch to another window before filling: the action is canceled.
15. **Clipboard on quit:** copy a password and immediately quit with ⌘Q. Pasting does not reveal it.
16. **Screen sharing:** start a QuickTime screen recording or Zoom sharing session. Ward windows are absent from the recording.
17. **Vault-backed settings:** run `defaults write local.ward autoLockMinutes -int 0`, restart, and unlock. The saved setting is unchanged, and idle locking still works.
18. **Hardened runtime:** run `codesign -dvv Ward.app` and check for `flags=0x10000(runtime)`.
19. **SSH key:** import a disposable `~/.ssh/id_ed25519` test key. Its fingerprint matches `ssh-keygen -lf ~/.ssh/id_ed25519.pub`. Export it and connect using `ssh -i <file> …`. The exported file has `-rw-------` permissions.
20. **Certificate:** select a `.crt` and `.key` together. Subject and expiration match Keychain Access. A `.p12` container can be exported and reopened with its container password.
21. **Address:** `10.0.0.5:22` offers a connection action rather than a browser button. `192.168.1.1:8080` opens over HTTP.
22. **Linked key:** create a key entry and make a server use its key through the reference selector. The server indicates the source entry. Replace the source key: the server shows the new fingerprint. Permanently delete the source: the confirmation lists affected servers.
23. **Breach check:** explicitly confirm the audit check. A disposable entry with password `password` is flagged. Without internet, Ward reports a failure rather than claiming there are no breaches.
24. **Nebula:** import `host.crt`, `ca.crt`, and `host.key` together. Networks, groups, and expiration match `nebula-cert print -path host.crt`; the CA has its own expiration. Export produces separate `host.crt` and `ca.crt` files.
25. **SSH agent:** enable the agent in Settings and place its `IdentityAgent` line at the beginning of a disposable SSH config. `ssh-add -L` lists Ward keys. `ssh <server>` prompts for approval and then connects. Lock Ward and repeat: the unlock window appears. For Git SSH signing, `git commit -S` with `gpg.format=ssh` produces a Git signing prompt. Check temporary approval separately in item 35.
26. **CSV export:** export and import the result into Apple Passwords. Entries are present, the file has `-rw-------` permissions, and the plaintext export is deleted afterward.
27. **Missing address and other browsers:** an entry without an address refuses browser autofill. DuckDuckGo/Orion on an unrelated site refuses it too. An entry using a Google account fills on accounts.google.com, not on the service's own site. An HTTP page is rejected for an HTTPS entry.
28. **Slow page:** on a heavy page in Chrome immediately after launch, use ⇧Return. The username field receives the username, not the password.
29. **Second instance:** with Ward running, execute `./Ward.app/Contents/MacOS/Ward`. It reports that Ward is already running and exits.
30. **Agent client identity:** a Homebrew or custom `ssh` client shows its full path and lacks an Apple-signature label. `/usr/bin/ssh` is displayed simply as `ssh`.
31. **Editor changes:** edit an entry, then press Escape. Ward asks whether to close without saving. With the editor open, ⌘N from the quick panel asks you to save or close the existing entry first.
32. **Cross-origin iframe:** open an allowed site with a third-party iframe containing a password field, focus that field, and use ⇧Return. Filling is canceled. Verify that Safari and Chrome expose the iframe as its own `AXWebArea` with its own address.
33. **Drafts:** edit an entry's password without saving, quit, reopen, and continue the unsaved draft. The new password is in the editor and can be saved. Repeat through locking with ⌃⌘Q. Editing an entry with a draft opens that draft; discarding it restores the saved entry.
34. **Security state outside UserDefaults:** `defaults read local.ward` does not contain `failedUnlocks`, `sshAgentWanted`, `backupsToKeep`, or `mirrorBackupPath`. Backup count and mirror directory survive restart.
35. **Temporary approval:** direct terminal `ssh <server>` does not offer the ten-minute approval button. In a disposable Git repository configured for SSH signing, `git rebase -S HEAD~5` can use temporary approval for the remaining commits of the same command; a later Git command prompts again.
36. **Companies, nested projects, and services:** after migration, previous work projects appear under the default company, which can be renamed. Create another company: it starts empty with its own projects and services. Give a service such as Hetzner one shared account and accounts for two projects: its page has three sections, and project pages show the service. Deleting the service preserves project accounts in their projects and the shared account in shared credentials. Deleting a parent project promotes its children one level.
37. **Hide Data:** toggle ⌘⇧H or the eye button in the sidebar/quick panel. Usernames, addresses, TOTP codes, notes, and field values are hidden; titles and copy buttons still work. Toggle again to reveal them. The setting survives restart.
38. **Connections:** in the editor's pre-login steps, create a connection such as VPN A. The step shows a connection icon. Fill its server, username, and configuration; the connection lists entries that use it. Clicking the step opens the connection. Permanently deleting it lists affected entries and removes their steps. The sheet has no system blue focus ring.
39. **Environments and UI:** assign a project entry to all environments. It appears in Stage and Production, with a red outline only in Production. Add a custom field: it has no blue focus ring and uses the amber field highlight. Buttons, chips, list rows, and the sidebar respond to hover. The sidebar footer contains lock, Hide Data, and Settings actions.
40. **Launch and foreground:** open Ward from Finder or Spotlight. The unlock window appears in front. Close it and work in another app; use Open Ward from the menu bar or ⌘→ from the quick panel. The main window comes forward. Repeat for Settings.
41. **Chrome extension:** enable the browser bridge in Settings, open Chrome extensions, enable developer mode, choose Load unpacked, and select the extension directory shown by Ward. A known login page shows the Ward icon in its password field; selecting an account fills the form. Unrelated domains show no accounts. On a passkey site such as webauthn.io, save a passkey through Ward and sign in with it. When Ward is locked, it asks to unlock and then continues the request.
42. **Automatic lock during a dialog:** open an export save dialog and leave it open beyond the lock interval. Ward still locks.

Keep passwords and TOTP codes in their previous storage until at least items 1–6 have passed.

## Browser and background-save regressions

- An HTTPS credential is not offered on an HTTP page; an explicitly saved HTTP address still works.
- Open the popup credential list, navigate, and select an old result: no filling occurs.
- Lock Ward or delete the passkey/entry during approval: the site receives no successful response.
- Disable an agent key or delete its entry during SSH approval: no signature is returned.
- Abort WebAuthn with `AbortController`, close the page, or let the request time out: Ward dismisses the approval.
- Lock during a slow Keychain write: the UI clears immediately, and completion does not unlock it again.
- Lock immediately after editing, then quit: the draft is available on the next launch.
- Passkeys in iframes and conditional sign-in remain handled by the browser.
