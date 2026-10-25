# Development

Run commands from the repository root, including commands linked from this directory.

## Build and launch

Ward requires macOS 14 or later and a Swift 6 toolchain. The package uses Swift 5 language mode.

```bash
./build.sh
open Ward.app
```

Quit an already running Ward before replacing its app bundle. `pkill -x Ward` stops the running process. Use demo modes for automated verification rather than opening the real vault.

`./build.sh debug` produces the debug build used for snapshots and integration demos. The script bundles the app, CLI, native messaging helper, browser extension, and icon, then signs the nested executables and app with hardened runtime.

## Code signing

`build.sh` selects an identity in this order:

1. Apple Development.
2. A self-signed `Ward Dev` identity.
3. Ad-hoc signing if no identity is available.

To obtain an Apple Development identity, use Xcode → Settings → Accounts → Manage Certificates. To create the dedicated self-signed identity:

```bash
tools/make-signing-cert.sh
```

The certificate script creates a non-extractable private key in the Keychain. Prefer the dedicated identity over one shared with another app.

You can optionally set `CODESIGN_ID` to select a signing identity explicitly. `WARD_SIGNING_KEYCHAIN` optionally selects the Keychain used by the certificate script; its default is `$HOME/Library/Keychains/login.keychain-db`.

With an Apple Development Team ID, vault access is associated with `teamid:` and survives rebuilds. With a self-signed identity, Accessibility and Screen Recording grants survive rebuilds, but Keychain access is associated with the build's `cdhash:`. The first launch after rebuilding can therefore block on a macOS prompt until you choose Always Allow. Ad-hoc signing also causes repeated permission prompts.

The Chrome bridge requires a Team ID. Self-signed and ad-hoc builds do not enable the normal browser bridge.

## Upgrading from a different application identifier

Ward uses the neutral application identifier `local.ward`. The browser helper and CLI are signed as `local.ward.browser-host` and `local.ward.cli`. The native messaging host and Keychain service use `local.ward` as well.

Changing the application identifier does not delete an older vault, but the new build looks under a different Keychain service. Migrate before creating a new vault or launching the new app:

1. In the old build, save any drafts and export an encrypted `.wardbackup` to a safe location outside `Ward/Backups`. Keep the old app and this copy until you have verified the migration. If the browser bridge was enabled, disable it in the old build to remove its old native messaging registration.
2. Quit Ward. Build the new app, but do not launch it yet.
3. Find the previous service name in Keychain Access for Ward's vault item (account `vault`). Enter it interactively, then run the new CLI from the app bundle:

   ```bash
   read -r LEGACY_SERVICE
   ./Ward.app/Contents/Helpers/ward migrate-vault --from-service "$LEGACY_SERVICE"
   unset LEGACY_SERVICE
   ```

   The first command waits for you to enter the previous service name. This keeps that name out of the repository and shell command history. macOS may ask for Keychain access.

4. Open the new app and unlock with the existing master password. Verify entries, passkeys, keys, drafts, security settings, and backup settings. Regrant macOS permissions if requested. UI preferences such as the hotkey and Hide Data mode may reset because the UserDefaults domain changed.
5. Enable the browser bridge again if needed, reload the unpacked Chrome extension, and restart Chrome so its background script uses the new host name.

The migration command holds Ward's process lock and refuses to run while Ward holds that lock. It copies the encrypted envelope byte for byte without decrypting it, preserving vault contents, drafts, security settings, and pre-unlock counters. It leaves the source item intact, refuses to overwrite a different destination, and treats an identical destination as an already completed migration. The command prints status only, never vault bytes or passwords. It does not migrate UI preferences or delete old native messaging files.

Do not launch old and new builds together: they share the `Ward` application-support directory, sockets, and automatic backup directory. New writes can prune older automatic backups, so keep the separate manual export and original Keychain item until verification is complete.

The normal backup import is a merge of entries and their organization; it does not restore drafts or security settings. Use the explicit migration command for a complete encrypted-vault transfer. This operation is manual and is never run by tests or the build script.

## UI snapshots

Snapshots require a debug build. This mode uses demo data, does not access the real vault, saves PNG images of the main screens, and exits. Screen Recording permission is not required.

```bash
./build.sh debug
WARD_SNAPSHOT=/tmp/ward-snapshots ./Ward.app/Contents/MacOS/Ward
```

## Icon generation

```bash
swift tools/make-icon.swift
```

The generator writes `AppIcon.icns`. Preview images are written under `build/`, including `build/AppIcon-1024.png`.

## Browser integration tests

Use a debug build, Google Chrome, Bun, and a Python interpreter with `webauthn` available:

```bash
./build.sh debug
tools/browser-e2e/run.sh
```

The runner installs its dependencies with Bun, starts demo Ward, and uses a temporary Chrome profile and a separate socket. It removes its temporary files on exit. Set `PYTHON` if the default `python3` does not provide `webauthn`.

## SSH agent demos

Debug builds support `WARD_AGENT_DEMO=<key-path>` and `WARD_AGENT_SOCKET=<socket-path>` for terminal checks with demo keys. Use a freshly generated test key and a separate socket, never a production key.

See [testing](TESTING.md) for automated suites, optional dependencies, and manual checks.
