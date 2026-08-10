"""Все пути приложения в одном месте — чтобы было видно, где что лежит.

Во время разработки храним всё рядом с проектом (папки bin/ и data/),
а не в скрытых системных каталогах. Так проще проверить, что внутри.

Отличие от Windows: в собранном виде bin/ тоже уезжает в пользовательскую
папку, а не остаётся рядом с приложением — внутрь .app писать нельзя, а ядро
приложение скачивает само.
"""
from __future__ import annotations

import sys
from pathlib import Path


def project_root() -> Path:
    """Корень проекта (папка, где лежит run.py).

    Работает и при запуске из исходников, и в собранном .app: там sys.executable
    указывает на SCVPN.app/Contents/MacOS/SCVPN.
    """
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


ROOT = project_root()

FROZEN = bool(getattr(sys, "frozen", False))

# Пользовательская папка macOS для данных приложения.
_APP_SUPPORT = Path.home() / "Library" / "Application Support" / "SCVPN"

# Папка с ядром и гео-базами (xray, geoip.dat, geosite.dat).
# В собранном виде — в Application Support: внутрь .app писать нельзя, а ядро
# приложение скачивает само. В разработке — рядом с проектом.
BIN_DIR = _APP_SUPPORT / "bin" if FROZEN else ROOT / "bin"

# Папка для пользовательских данных (профили, настройки, логи).
DATA_DIR = _APP_SUPPORT if FROZEN else ROOT / "data"
LOG_DIR = DATA_DIR / "logs"

# Конкретные файлы.
PROFILES_FILE = DATA_DIR / "profiles.json"          # серверы + подписки
SETTINGS_FILE = DATA_DIR / "settings.json"          # настройки приложения
XRAY_CONFIG_FILE = DATA_DIR / "xray_running.json"   # активный конфиг ядра (для отладки)

# ----------------------------------------------------------------------
# Хозяйство привилегированного демона
# ----------------------------------------------------------------------
# sing-box запускает root, поэтому он обязан лежать там, куда пользователь не
# может писать: иначе любой процесс подменил бы бинарник и получил root.
# Эту папку заводит и наполняет сам демон (root:wheel, 0755).
HELPER_DIR = Path("/Library/Application Support/SCVPN")
HELPER_BIN_DIR = HELPER_DIR / "bin"
HELPER_SOCKET = Path("/var/run/scvpn-helper.sock")
HELPER_PLIST = Path("/Library/LaunchDaemons/com.scvpn.helper.plist")
HELPER_LABEL = "com.scvpn.helper"


def xray_exe() -> Path:
    return BIN_DIR / "xray"


def singbox_exe() -> Path:
    """sing-box используется только для TUN-режима и живёт в root-овой папке."""
    return HELPER_BIN_DIR / "sing-box"


def geoip_dat() -> Path:
    return BIN_DIR / "geoip.dat"


def geosite_dat() -> Path:
    return BIN_DIR / "geosite.dat"


def resource_path(rel: str) -> Path:
    """Путь к упакованному ресурсу (иконка и т.п.)."""
    if FROZEN:
        base = Path(getattr(sys, "_MEIPASS", ROOT))
        return base / rel
    return ROOT / rel


def icon_file() -> Path:
    return resource_path("scvpn.icns") if FROZEN else (ROOT / "setup" / "scvpn.icns")


def ensure_dirs() -> None:
    """Создать рабочие папки, если их ещё нет."""
    for d in (BIN_DIR, DATA_DIR, LOG_DIR):
        d.mkdir(parents=True, exist_ok=True)
