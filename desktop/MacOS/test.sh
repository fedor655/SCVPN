#!/bin/bash
# Проверки SCVPN для macOS.
#   ./test.sh            -> модульные проверки платформенного слоя
#   ./test.sh smoke      -> живая проверка (smoke_test.py): парсинг, конфиги, туннель
#   ./test.sh файл.py    -> запустить свой скрипт в окружении проекта
set -u
cd "$(dirname "$0")"
PY=.venv/bin/python

if [ ! -x "$PY" ]; then
  echo "[!] Нет .venv. Создай: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  exit 1
fi

case "${1:-}" in
  "")      "$PY" test_native.py ;;
  smoke)   "$PY" smoke_test.py ;;
  *)       "$PY" "$@" ;;
esac
