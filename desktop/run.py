"""Точка входа SCVPN.

Запуск:  .venv\\Scripts\\python.exe run.py
"""
import sys

# Консоль Windows бывает в cp1251 — переключаем потоки на UTF-8, чтобы русский
# текст и любые символы в логах не роняли программу. В режиме без консоли
# (pythonw) потоки могут быть None — тогда просто пропускаем.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except Exception:
        pass

from scvpn import paths
from scvpn.ui.main_window import run_app


def main() -> int:
    paths.ensure_dirs()
    return run_app()


if __name__ == "__main__":
    raise SystemExit(main())
