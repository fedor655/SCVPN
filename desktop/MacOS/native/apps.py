"""Список запущенных приложений для правил раздельного туннелирования.

sing-box сопоставляет соединение с процессом-владельцем по имени
исполняемого файла — для macOS это файл внутри бандла, то есть Telegram.app
даёт имя «Telegram», а не «Telegram.app».

Берём только процессы из /Applications: в системе их под тысячу, и показывать
пользователю системные демоны бессмысленно. Расширения (.appex — виджеты,
шаринг и прочее) тоже отбрасываем: это не то, что человек хочет выбрать в
списке приложений.
"""
from __future__ import annotations

import subprocess

MANUAL_HINT = "Имя приложения (например, Telegram):"


def running_apps() -> list[str]:
    """Имена запущенных приложений из /Applications, без дубликатов."""
    try:
        out = subprocess.run(
            ["ps", "-axo", "comm="], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    names: set[str] = set()
    for line in out.splitlines():
        path = line.strip()
        if not path.startswith("/Applications/") or ".appex/" in path:
            continue
        name = path.rsplit("/", 1)[-1]
        if name:
            names.add(name)
    return sorted(names, key=str.lower)


def normalize(name: str) -> str:
    """Привести введённое руками имя к виду, который поймёт правило sing-box."""
    name = name.strip().rstrip("/")
    name = name.rsplit("/", 1)[-1]
    if name.endswith(".app"):
        name = name[: -len(".app")]
    return name
