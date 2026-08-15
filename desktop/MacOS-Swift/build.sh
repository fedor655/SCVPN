#!/bin/bash
# Сборка SCVPN.app. Бинарники ядра (xray, гео-базы, sing-box) НЕ
# упаковываются: их качает само приложение, а sing-box обязан лежать в
# root-овой папке демона.
set -euo pipefail
cd "$(dirname "$0")"

[ "$(uname -m)" = "arm64" ] || { echo "[!] Сборка рассчитана на Apple Silicon"; exit 1; }

BUILD_DIR="${SCVPN_BUILD_DIR:-$PWD}"
APP="$BUILD_DIR/dist/SCVPN.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/SCVPNApp"    "$APP/Contents/MacOS/SCVPN"
cp "$BIN/SCVPNHelper" "$APP/Contents/MacOS/scvpn-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/com.scvpn.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp ../MacOS/setup/scvpn.icns "$APP/Contents/Resources/scvpn.icns"

# Снимаем расширенные атрибуты: codesign отказывается подписывать бандл, на
# файлах которого висит com.apple.provenance (его ставит macOS при обращении)
# или com.apple.fileprovider.fpfs (iCloud, если проект в синхронизируемой
# папке) — «resource fork, Finder information, or similar detritus not
# allowed». Атрибуты вернутся через десятки секунд, но уже поставленную
# подпись это не ломает — важно очистить их непосредственно перед codesign.
xattr -cr "$APP"

# Без Apple Developer ID подписываем сами собой. Вложенный бинарник демона
# подписывается первым: --deep не гарантирует порядок, а неподписанный
# BundleProgram SMAppService не примет.
codesign --force --sign - "$APP/Contents/MacOS/scvpn-helper"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "Готово: $APP"
