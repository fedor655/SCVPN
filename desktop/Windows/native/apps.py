"""Список запущенных приложений для правил раздельного туннелирования.

sing-box сопоставляет соединение с процессом-владельцем по имени
исполняемого файла, поэтому здесь нужны именно имена .exe, а не заголовки окон.
"""
from __future__ import annotations

MANUAL_HINT = "Имя исполняемого файла (например, Telegram.exe):"

# Системные процессы, которые в списке только мешают.
_HIDDEN = {
    "system", "system idle process", "registry", "memory compression", "svchost.exe",
    "csrss.exe", "wininit.exe", "winlogon.exe", "services.exe", "lsass.exe",
    "smss.exe", "fontdrvhost.exe", "dwm.exe", "ctfmon.exe", "sihost.exe",
    "taskhostw.exe", "runtimebroker.exe", "searchhost.exe", "conhost.exe",
    "dllhost.exe", "spoolsv.exe", "audiodg.exe", "wudfhost.exe",
}


def running_apps() -> list[str]:
    """Имена запущенных .exe, без системной мелочи и дубликатов."""
    names: set[str] = set()
    try:
        import subprocess

        out = subprocess.run(
            ["tasklist", "/fo", "csv", "/nh"],
            capture_output=True, text=True, encoding="cp866", errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
        for line in out.splitlines():
            if not line.startswith('"'):
                continue
            name = line.split('","')[0].strip('"')
            if name and name.lower() not in _HIDDEN:
                names.add(name)
    except Exception:  # noqa: BLE001
        pass
    return sorted(names, key=str.lower)


def normalize(name: str) -> str:
    """Привести введённое руками имя к виду, который поймёт правило sing-box."""
    name = name.strip()
    if name and not name.lower().endswith(".exe"):
        name += ".exe"
    return name
