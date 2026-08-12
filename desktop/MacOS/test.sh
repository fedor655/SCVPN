#!/bin/bash
# Проверки SCVPN для macOS.
#   ./test.sh            -> модульные проверки платформенного слоя
#   ./test.sh smoke      -> живая проверка (smoke_test.py): парсинг, конфиги, туннель
#   ./test.sh файл.py    -> запустить свой скрипт в окружении проекта
set -u
cd "$(dirname "$0")"
PY=venv/bin/python

if [ ! -x "$PY" ]; then
  echo "[!] Нет venv. Создай: python3 -m venv venv && venv/bin/pip install -r requirements.txt"
  exit 1
fi

# venv обязан лежать под НЕскрытым именем: Qt (QDir/QFactoryLoader) не видит
# плагины платформы под каталогом с флагом UF_HIDDEN, и QApplication падает
# qFatal "Could not find the Qt platform plugin" ещё до создания окна — при
# живом дереве файлов, верных путях и без всякой песочницы (см. отчёт
# Задачи 11). Просто ИМЯ без ведущей точки не гарантирует этого сам по себе:
# флаг — атрибут inode, а не производная от имени, и переживает mv. На этой
# машине он обнаружился рекурсивно на каждом файле venv, доставшемся ещё от
# .venv. Снимаем его тут же, идемпотентно и дёшево, а не одноразовой ручной
# командой — иначе тот же откат ждёт следующего свежесозданного venv, если
# что-то в окружении снова его проставит.
chflags -R nohidden venv 2>/dev/null || true

case "${1:-}" in
  "")      "$PY" test_native.py ;;
  smoke)   "$PY" smoke_test.py ;;
  *)       "$PY" "$@" ;;
esac
