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

# venv живёт ВНЕ дерева репозитория — см. test.sh/run.py. Причина: ~/Documents
# синхронизируется iCloud Drive, и синк проставляет macOS-флаг UF_HIDDEN на
# файлы ВНУТРИ синхронизируемого дерева, из-за чего Qt не находит собственные
# плагины платформы и падает ещё до создания окна.
#
# Та же болезнь касается и результата сборки: PyInstaller раскладывает бандл
# на сотни файлов (Contents/MacOS/*, десятки *.dylib и т.п.), и если собирать
# прямо в desktop/MacOS/dist — внутри репозитория, — синхронизация рано или
# поздно (по замерам для venv — за 75-90 секунд, не разом, а частями) начнёт
# помечать часть из них флагом, и бандл сломается тем же способом, что и venv
# до переезда. Поэтому PyInstaller собирает во временный каталог ВНЕ
# репозитория, а desktop/MacOS/dist и desktop/MacOS/build — лишь симлинки на
# него: путь dist/SCVPN.app остаётся тем, что ожидают остальные шаги, а сами
# байты бандла никогда не попадают под iCloud.
#
# Переопределить: SCVPN_VENV=/путь SCVPN_BUILD_DIR=/путь ./build.sh
VENV="${SCVPN_VENV:-$HOME/.venvs/scvpn}"
PY="$VENV/bin/python"
BUILD_DIR="${SCVPN_BUILD_DIR:-$HOME/.scvpn-build}"

if [ ! -x "$PY" ]; then
  echo "[!] Нет venv. Создай: python3 -m venv \"$VENV\" && \"$VENV/bin/pip\" install -r requirements.txt"
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "[!] Сборка рассчитана на Apple Silicon, здесь $(uname -m)."
  exit 1
fi

# Тот же дешёвый пояс, что и в test.sh: если venv всё же оказался под флагом
# (перенесли копированием с уже помеченного дерева и т.п.), снимаем его перед
# сборкой — иначе PyInstaller потом не найдёт нужные ему файлы venv.
for _ in 1 2 3; do
  remaining=$(find "$VENV" -flags +hidden 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" = "0" ] && break
  chflags -R nohidden "$VENV" 2>/dev/null || true
done

mkdir -p "$BUILD_DIR"

echo "=== PyInstaller ==="
"$PY" -m PyInstaller --noconfirm --clean \
  --distpath "$BUILD_DIR/dist" --workpath "$BUILD_DIR/build" \
  SCVPN.spec

echo "=== Подпись (ad-hoc) ==="
# Без Apple Developer ID подписываем сами собой: этого хватает, чтобы система
# запустила приложение, но при первом запуске потребуется ПКМ -> «Открыть».
codesign --force --deep --sign - "$BUILD_DIR/dist/SCVPN.app"
codesign --verify --verbose "$BUILD_DIR/dist/SCVPN.app"

echo "=== Симлинки dist/ и build/ на каталог сборки ==="
# dist/ и build/ внутри репозитория в .gitignore — симлинк туда ничего не
# коммитит, а лишь даёт привычный путь dist/SCVPN.app без риска UF_HIDDEN.
rm -rf dist build
ln -s "$BUILD_DIR/dist" dist
ln -s "$BUILD_DIR/build" build

echo
echo "Готово: dist/SCVPN.app (симлинк на $BUILD_DIR/dist/SCVPN.app)"
echo "Перенеси в /Applications и запусти первый раз через ПКМ -> «Открыть»."
