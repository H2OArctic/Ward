#!/bin/bash
# Сквозная проверка расширения: Google Chrome (временный профиль, ваш не трогается) + расширение + помощник +
# демо-Ward (debug-сборка, связку ключей не трогает). Нужны: ./build.sh debug, bun, python с py_webauthn.
#   PYTHON=<python с webauthn> tools/browser-e2e/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
# Свой сокет: настоящий Ward с включённым мостом не задевается. Chrome не передаёт помощнику окружение,
# поэтому манифест указывает на обёртку, которая задаёт сокет и заменяет себя помощником (exec — родителем
# помощника остаётся Chrome, и проверка его подписи работает как обычно).
SOCKET="$WORK/browser.sock"
cat >"$WORK/host.sh" <<HOST
#!/bin/sh
WARD_BROWSER_SOCKET="$SOCKET" exec "$ROOT/Ward.app/Contents/Helpers/ward-browser-host" "\$@"
HOST
chmod +x "$WORK/host.sh"
mkdir -p "$WORK/profile/NativeMessagingHosts"
WARD_BROWSER_DEMO=approve WARD_BROWSER_SOCKET="$SOCKET" WARD_BROWSER_HOST_PATH="$WORK/host.sh" \
    WARD_BROWSER_MANIFEST_DIR="$WORK/profile/NativeMessagingHosts" \
    "$ROOT/Ward.app/Contents/MacOS/Ward" >"$WORK/ward.log" 2>&1 &
WARD_PID=$!
trap 'kill $WARD_PID 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 40); do [[ -S "$SOCKET" ]] && break; sleep 0.25; done
cd "$(dirname "$0")"
bun install --silent
PROFILE="$WORK/profile" EXTENSION="$ROOT/BrowserExtension" PYTHON="${PYTHON:-python3}" bun run.ts
