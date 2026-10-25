#!/bin/bash
# Собирает Ward.app из SwiftPM-сборки и подписывает его.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Ward"
CONFIG="${1:-release}"      # release | debug (debug нужен только для WARD_SNAPSHOT)
BUNDLE_ID="local.ward"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"
APP="$ROOT/$APP_NAME.app"

echo "==> Собираю бандл $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
if [ -f "$ROOT/AppIcon.icns" ]; then
    cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Помощник браузера (Chrome запускает его по native messaging) и само расширение.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/WardBrowserHost" "$APP/Contents/Helpers/ward-browser-host"
cp "$BIN_DIR/WardCLI" "$APP/Contents/Helpers/ward"
cp -R "$ROOT/BrowserExtension" "$APP/Contents/Resources/BrowserExtension"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Ward</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Локальный менеджер паролей и 2FA</string>
</dict>
</plist>
PLIST

# Стабильная подпись обязательна: доступ к записи в связке ключей и право «Запись экрана»
# macOS привязывает к подписи. С ad-hoc после каждой пересборки будут вопросы о доступе.
# Лучше всего — Apple Development (Xcode → Settings → Accounts → Manage Certificates): с Team ID доступ к связке
# ключей и права macOS привязаны к команде, а не к отпечатку сборки, и не слетают после каждой пересборки.
if [[ -z "${CODESIGN_ID:-}" ]]; then
    # Вывод в переменную: с pipefail «security | grep -q» падал бы от SIGPIPE, и подпись тихо становилась ad-hoc.
    VALID="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    # По отпечатку, а не по имени: сертификатов Apple Development может быть несколько (продление).
    CODESIGN_ID="$(awk '/"Apple Development: / { print $2; exit }' <<<"${VALID:-}")"
fi
if [[ -z "${CODESIGN_ID:-}" ]]; then
    IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
    if grep -qF '"Ward Dev"' <<<"$IDENTITIES"; then
        CODESIGN_ID="Ward Dev"
    fi
fi
SIGN_ID="${CODESIGN_ID:--}"
SIGN_NAME="$(awk -v id="$SIGN_ID" '$2 == id { sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit }' <<<"${VALID:-}")"
[[ -n "$SIGN_NAME" ]] && echo "    $SIGN_NAME"
echo "==> Подпись ($SIGN_ID)"
# Hardened runtime: без него macOS принимает DYLD_INSERT_LIBRARIES, и чужой код внутри Ward получил бы
# его права (Универсальный доступ, Запись экрана, доступ к связке ключей).
# Вложенный код — первым и со своим идентификатором: по нему Ward узнаёт своего помощника на том конце сокета.
codesign --force --options runtime --identifier "${BUNDLE_ID}.browser-host" --sign "$SIGN_ID" \
    "$APP/Contents/Helpers/ward-browser-host"
codesign --force --options runtime --identifier "${BUNDLE_ID}.cli" --sign "$SIGN_ID" \
    "$APP/Contents/Helpers/ward"
codesign --force --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"
[[ "$SIGN_ID" == "-" ]] && echo "    (ad-hoc — связка ключей будет спрашивать доступ после каждой пересборки)"

echo "==> Готово: $APP"
echo "    Запуск: open \"$APP\"   (или: \"$APP/Contents/MacOS/$APP_NAME\" для логов в терминале)"
