"""Точка входа SCVPN для Windows.

Запуск:  .venv\\Scripts\\python.exe run.py
"""
import sys

# Каталог самого скрипта Python добавляет в sys.path сам — оттуда берутся и
# native, и shared. Прежде shared лежал уровнем выше и делился с Qt-версией
# для macOS; её больше нет, и общего кода между платформами тоже: на macOS
# приложение нативное, на Swift.

# Консоль Windows бывает в cp1251 — переключаем потоки на UTF-8, чтобы русский
# текст и любые символы в логах не роняли программу. В режиме без консоли
# (pythonw) потоки могут быть None — тогда просто пропускаем.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except Exception:
        pass

from native import paths  # noqa: E402
from ui.main_window import run_app  # noqa: E402


def main() -> int:
    paths.ensure_dirs()
    return run_app()


if __name__ == "__main__":
    raise SystemExit(main())
