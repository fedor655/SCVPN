"""Все пути приложения в одном месте — чтобы было видно, где что лежит.

Во время разработки храним всё рядом с проектом (папки bin/ и data/),
а не в скрытых системных каталогах. Так проще проверить, что внутри.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path


def project_root() -> Path:
    """Корень проекта (папка, где лежит run.py).

    Работает и при запуске из исходников, и в собранном .exe (PyInstaller).
    """
    if getattr(sys, "frozen", False):  # собранный exe
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


ROOT = project_root()

FROZEN = bool(getattr(sys, "frozen", False))

# Папка с ядром и гео-базами (xray.exe, geoip.dat, geosite.dat, sing-box, wintun).
# В обоих режимах — рядом с приложением (в собранном виде установщик кладёт сюда
# бинарники; они только читаются).
BIN_DIR = ROOT / "bin"


def _data_dir() -> Path:
    """Папка для пользовательских данных (профили, настройки, логи).

    В режиме разработки — рядом с проектом (data/), чтобы всё было под рукой.
    В собранном приложении — в %LOCALAPPDATA%\\SCVPN, т.к. рядом с exe в
    Program Files писать нельзя.
    """
    if FROZEN:
        base = os.environ.get("LOCALAPPDATA") or str(Path.home())
        return Path(base) / "SCVPN"
    return ROOT / "data"


# Папка с пользовательскими данными: профили, настройки, логи.
DATA_DIR = _data_dir()
LOG_DIR = DATA_DIR / "logs"

# Конкретные файлы.
PROFILES_FILE = DATA_DIR / "profiles.json"      # серверы + подписки
SETTINGS_FILE = DATA_DIR / "settings.json"      # настройки приложения
XRAY_CONFIG_FILE = DATA_DIR / "xray_running.json"  # активный конфиг ядра (для отладки)
# Активный .conf AmneziaWG. Лежит там же, где конфиг Xray, и защищён так же —
# то есть правами на саму папку: в собранном приложении это %LOCALAPPDATA%\SCVPN
# внутри профиля пользователя, в разработке — data/ рядом с исходниками. Отдельной
# защиты приватному ключу не выдумываем: рядом уже лежит xray_running.json с
# uuid и паролем сервера, и он ничем не менее ценен.
AWG_CONFIG_FILE = DATA_DIR / "awg_running.conf"


def xray_exe() -> Path:
    return BIN_DIR / ("xray.exe" if os.name == "nt" else "xray")


def awg_exe() -> Path:
    """scvpn-awg — AmneziaWG в виде локального SOCKS5 (сборка из папки awg/)."""
    return BIN_DIR / ("scvpn-awg.exe" if os.name == "nt" else "scvpn-awg")


def singbox_exe() -> Path:
    """sing-box используется только для TUN-режима (поднимает TUN-адаптер)."""
    return BIN_DIR / ("sing-box.exe" if os.name == "nt" else "sing-box")


def wintun_dll() -> Path:
    """Драйвер виртуального адаптера для TUN на Windows."""
    return BIN_DIR / "wintun.dll"


def geoip_dat() -> Path:
    return BIN_DIR / "geoip.dat"


def geosite_dat() -> Path:
    return BIN_DIR / "geosite.dat"


def resource_path(rel: str) -> Path:
    """Путь к упакованному ресурсу (иконка и т.п.).

    В собранном приложении PyInstaller распаковывает данные в _MEIPASS.
    """
    if FROZEN:
        base = Path(getattr(sys, "_MEIPASS", ROOT))
        return base / rel
    return ROOT / rel


def icon_file() -> Path:
    return resource_path("scvpn.ico") if FROZEN else (ROOT / "setup" / "scvpn.ico")


def ensure_dirs() -> None:
    """Создать рабочие папки, если их ещё нет."""
    for d in (BIN_DIR, DATA_DIR, LOG_DIR):
        d.mkdir(parents=True, exist_ok=True)
