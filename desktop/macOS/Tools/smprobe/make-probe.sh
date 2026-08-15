#!/bin/bash
# Собрать SMProbe.app — зонд для Фазы 0 плана переписывания.
#
#   ./make-probe.sh                                  -> версия A, ExitTimeOut 40
#   ./make-probe.sh --version B --exit-timeout 41    -> версия B
#   ./make-probe.sh --out ~/Downloads                -> положить в другое место
#   ./make-probe.sh --suffix 2                       -> отдельная личность
#
# Про --suffix. BTM запоминает согласие пользователя по идентификатору бандла,
# и однажды разрешённый зонд дальше регистрируется без вопросов — из любой
# папки. Проверка «откуда register() доходит» на таком зонде отвечает не про
# папку, а про память системы. Каждое место проверяется своим суффиксом:
# com.scvpn.smprobe2, com.scvpn.smprobe3 — для BTM это разные службы, каждая с
# чистого листа.
#
# Раскладка и подпись — те же, что у настоящего SCVPN.app: тот же ad-hoc,
# тот же порядок (вложенный демон первым), тот же BundleProgram. Иначе зонд
# отвечал бы на вопрос про какой-то другой бандл.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=A
EXIT_TIMEOUT=40
SUFFIX=""
OUT="$PWD/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --version)       VERSION="$2"; shift 2 ;;
    --exit-timeout)  EXIT_TIMEOUT="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    --suffix)        SUFFIX="$2"; shift 2 ;;
    *) echo "не знаю флаг: $1"; exit 2 ;;
  esac
done

LABEL="com.scvpn.smprobe$SUFFIX"
NAME="SMProbe$SUFFIX"
APP="$OUT/$NAME.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Версия зашивается в код, а не читается из окружения: Задача 0.2 спрашивает,
# чей БИНАРНИК подняла launchd после подмены .app, и ответ обязан приехать из
# самого бинарника.
{
  echo "let probeVersion = \"$VERSION\""
  echo "let probeLabel = \"$LABEL\""
} > "$TMP/probe-version.swift"

TARGET=arm64-apple-macosx13.0

# swiftc пускает операторы на верхнем уровне только в файле с именем main.swift,
# и ровно в одном на модуль. Оба зонда написаны сплошным кодом сверху вниз,
# поэтому каждый собирается в своей папке под этим именем.
mkdir -p "$TMP/app" "$TMP/helper"
cp probe-app.swift    "$TMP/app/main.swift"
cp probe-helper.swift "$TMP/helper/main.swift"
cp "$TMP/probe-version.swift" "$TMP/app/"
cp "$TMP/probe-version.swift" "$TMP/helper/"

swiftc -O -target "$TARGET" "$TMP/app/main.swift"    "$TMP/app/probe-version.swift"    -o "$TMP/SMProbe"
swiftc -O -target "$TARGET" "$TMP/helper/main.swift" "$TMP/helper/probe-version.swift" -o "$TMP/smprobe-helper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp "$TMP/SMProbe"        "$APP/Contents/MacOS/$NAME"
cp "$TMP/smprobe-helper" "$APP/Contents/MacOS/smprobe-helper"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Имя файла обязано совпадать с Label — требование SMAppService.
cat > "$APP/Contents/Library/LaunchDaemons/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>BundleProgram</key><string>Contents/MacOS/smprobe-helper</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ExitTimeOut</key><integer>$EXIT_TIMEOUT</integer>
  <key>StandardErrorPath</key><string>/tmp/smprobe-stderr.log</string>
</dict></plist>
PLIST

# Чистим атрибуты перед КАЖДЫМ обращением codesign, а не один раз. Проект
# лежит в синхронизируемой папке, и macOS вешает com.apple.provenance и
# com.apple.fileprovider.fpfs обратно за секунды — между подписью и проверкой
# успевает.
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/MacOS/smprobe-helper"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
xattr -cr "$APP"
codesign --verify "$APP"

echo "Готово: $APP  (версия $VERSION, ExitTimeOut $EXIT_TIMEOUT, служба $LABEL)"
echo "Управлять так:  $APP/Contents/MacOS/$NAME status|register|unregister"
