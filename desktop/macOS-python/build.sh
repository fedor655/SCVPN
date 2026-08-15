#!/bin/bash
# ====================================================================
#  Сборка SCVPN.app через PyInstaller.
#  Бинарники ядра (xray, гео-базы, sing-box) НЕ упаковываются — их
#  качает само приложение, а sing-box ещё и обязан лежать в root-овой
#  папке демона, куда сборщику писать нечего.
#  Иконка не генерируется: setup/scvpn.icns нарисован один раз и лежит в git.
# ====================================================================
set -euo pipefail
cd "$(dirname "$0")"

# venv и результат сборки лежат в самом проекте. Переопределить:
#   SCVPN_VENV=/путь SCVPN_BUILD_DIR=/путь ./build.sh
VENV="${SCVPN_VENV:-$PWD/venv}"
PY="$VENV/bin/python"
BUILD_DIR="${SCVPN_BUILD_DIR:-$PWD}"

if [ ! -x "$PY" ]; then
  echo "[!] Нет venv. Создай: python3 -m venv \"$VENV\" && \"$VENV/bin/pip\" install -r requirements.txt"
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "[!] Сборка рассчитана на Apple Silicon, здесь $(uname -m)."
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "=== PyInstaller ==="
"$PY" -m PyInstaller --noconfirm --clean \
  --distpath "$BUILD_DIR/dist" --workpath "$BUILD_DIR/build" \
  SCVPN.spec

echo "=== Подпись (ad-hoc) ==="
# Снимаем расширенные атрибуты: codesign отказывается подписывать бандл, на
# файлах которого висит com.apple.provenance (его ставит macOS при обращении)
# или com.apple.fileprovider.fpfs (его ставит iCloud, если проект в
# синхронизируемой папке) — «resource fork, Finder information, or similar
# detritus not allowed». Атрибуты вернутся через десятки секунд, но уже
# поставленную подпись это не ломает — проверено; важно лишь очистить их
# непосредственно перед codesign.
xattr -cr "$BUILD_DIR/dist/SCVPN.app"

# Без Apple Developer ID подписываем сами собой: этого хватает, чтобы система
# запустила приложение, но при первом запуске потребуется ПКМ -> «Открыть».
codesign --force --deep --sign - "$BUILD_DIR/dist/SCVPN.app"
codesign --verify --verbose "$BUILD_DIR/dist/SCVPN.app"

echo
echo "Готово: dist/SCVPN.app"
echo "Перенеси в /Applications и запусти первый раз через ПКМ -> «Открыть»."
