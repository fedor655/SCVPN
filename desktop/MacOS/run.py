"""Точка входа SCVPN для macOS.

Запуск:      venv/bin/python run.py
Демон:       venv/bin/python run.py --helper   (запускает launchd от root)
"""
import sys
from pathlib import Path

# Общий код лежит на уровень выше, в desktop/shared. Каталог самого скрипта
# (desktop/MacOS) Python добавляет в sys.path сам — оттуда берётся native.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def main() -> int:
    # Тот же исполняемый файл работает и приложением, и привилегированным
    # демоном: так в бандле не нужен второй интерпретатор Python.
    if "--helper" in sys.argv[1:]:
        from helper.daemon import main as helper_main

        return helper_main()

    from native import paths
    from shared.ui.main_window import run_app

    paths.ensure_dirs()
    return run_app()


if __name__ == "__main__":
    raise SystemExit(main())
