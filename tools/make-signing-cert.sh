#!/bin/bash
# Отдельный самоподписанный сертификат «Ward Dev» для подписи Ward (build.sh выбирает его первым).
# Общий сертификат нескольких проектов опасен: права Ward (Универсальный доступ, Запись экрана) macOS выдаёт
# по подписи, и любой проект с тем же ключом мог бы подписать свою программу как local.ward.
# Ключ импортируется без «разрешать codesign всегда»: при каждой подписи macOS спросит доступ к ключу —
# отвечайте «Разрешить», а не «Разрешить всегда», иначе ключом сможет подписывать любой процесс.
# Ключ неизвлекаемый: резервной копии у него нет, потеряется — создайте новый (и заново выдайте права Ward).
set -euo pipefail

NAME="Ward Dev"
KEYCHAIN="${WARD_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
# Вывод в переменную: с pipefail «security | grep -q» падал бы от SIGPIPE, и готовый сертификат не нашёлся бы.
IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
if grep -qF "\"$NAME\"" <<<"$IDENTITIES"; then
    echo "Сертификат «${NAME}» уже есть"
    exit 0
fi

OPENSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$("$OPENSSL" rand -hex 16)"

"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# Шифрование контейнера, которое понимает `security import` (PBKDF2/AES из OpenSSL 3 он читает не везде).
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" -out "$TMP/ward.p12"
# -x — ключ не извлечь из связки; -T "" — ни одной программе (даже самой `security`) без запроса: иначе любой
# процесс мог бы молча выгрузить ключ через `security export` или подписывать им.
security import "$TMP/ward.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -x -T ""

echo "Готово: «${NAME}». Дальше: ./build.sh, затем заново выдайте Ward «Универсальный доступ» и «Запись экрана»"
echo "(подпись сменилась — старые разрешения к новой подписи не относятся)."
