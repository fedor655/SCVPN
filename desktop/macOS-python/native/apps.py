"""Список запущенных приложений для правил раздельного туннелирования.

sing-box сопоставляет соединение с процессом-владельцем по имени
исполняемого файла — для macOS это файл внутри бандла, то есть Telegram.app
даёт имя «Telegram», а не «Telegram.app».

Берём процессы из /Applications, /System/Applications и ~/Applications: в
системе их под тысячу, и показывать пользователю системные демоны
бессмысленно. Расширения (.appex — виджеты, шаринг и прочее) тоже
отбрасываем: это не то, что человек хочет выбрать в списке приложений.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

MANUAL_HINT = "Имя приложения (например, Telegram):"

# Префиксы путей, из которых показываем приложения.
_APP_PREFIXES = (
    "/Applications/",
    "/System/Applications/",
    str(Path.home() / "Applications") + "/",
)


def running_apps() -> list[str]:
    """Имена запущенных приложений из /Applications, /System/Applications и ~/Applications, без дубликатов."""
    try:
        out = subprocess.run(
            ["ps", "-axo", "comm="], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    names: set[str] = set()
    for line in out.splitlines():
        path = line.strip()
        # Проверяем что путь начинается с одного из разрешённых префиксов.
        if not any(path.startswith(prefix) for prefix in _APP_PREFIXES):
            continue
        # Пропускаем расширения: .appex, .app plugin и т.д.
        if ".appex/" in path:
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
