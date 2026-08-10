"""Разовое скачивание ядра Xray-core с официального GitHub.

Берём последний релиз из репозитория XTLS/Xray-core, скачиваем архив для
Windows x64 и распаковываем в bin/ ровно три файла: xray.exe, geoip.dat,
geosite.dat. Это единственный «внешний» источник, и он официальный и открытый.
"""
from __future__ import annotations

import io
import zipfile
from typing import Callable, Optional

import requests

from . import paths

RELEASES_API = "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
ASSET_NAME = "Xray-windows-64.zip"
WANTED = {"xray.exe", "geoip.dat", "geosite.dat"}


def latest_asset_url() -> tuple[str, str]:
    """Вернуть (тег_версии, url_архива) последнего релиза Xray-core."""
    r = requests.get(RELEASES_API, timeout=30, headers={"Accept": "application/vnd.github+json"})
    r.raise_for_status()
    data = r.json()
    tag = data.get("tag_name", "?")
    for asset in data.get("assets", []):
        if asset.get("name") == ASSET_NAME:
            return tag, asset["browser_download_url"]
    raise RuntimeError(f"В релизе {tag} не найден ассет {ASSET_NAME}")


def download_core(progress: Optional[Callable[[str], None]] = None) -> str:
    """Скачать и распаковать ядро. Вернуть строку с версией."""
    log = progress or (lambda s: None)
    paths.ensure_dirs()

    log("Узнаю последнюю версию Xray-core…")
    tag, url = latest_asset_url()
    log(f"Версия {tag}. Скачиваю {ASSET_NAME}…")

    r = requests.get(url, timeout=120, stream=True)
    r.raise_for_status()
    buf = io.BytesIO()
    total = int(r.headers.get("Content-Length", 0))
    got = 0
    for chunk in r.iter_content(chunk_size=64 * 1024):
        buf.write(chunk)
        got += len(chunk)
        if total:
            log(f"Скачано {got // 1024} / {total // 1024} КБ")
    buf.seek(0)

    log("Распаковываю…")
    with zipfile.ZipFile(buf) as z:
        for member in z.namelist():
            base = member.rsplit("/", 1)[-1]
            if base in WANTED:
                with z.open(member) as src:
                    (paths.BIN_DIR / base).write_bytes(src.read())
                log(f"  -> bin/{base}")

    missing = [w for w in WANTED if not (paths.BIN_DIR / w).exists()]
    if missing:
        raise RuntimeError(f"После распаковки не хватает файлов: {missing}")

    log(f"Готово. Ядро Xray-core {tag} установлено в bin/")
    return tag


def core_present() -> bool:
    return paths.xray_exe().exists() and paths.geoip_dat().exists() and paths.geosite_dat().exists()


# ----------------------------------------------------------------------
# sing-box (для TUN-режима) + wintun (драйвер TUN-адаптера на Windows)
# ----------------------------------------------------------------------
SINGBOX_RELEASES_API = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
WINTUN_URL = "https://www.wintun.net/builds/wintun-0.14.1.zip"


def _singbox_asset_url() -> tuple[str, str]:
    """Вернуть (тег, url) zip-архива sing-box для Windows x64 (стабильный релиз)."""
    r = requests.get(SINGBOX_RELEASES_API, timeout=30, headers={"Accept": "application/vnd.github+json"})
    r.raise_for_status()
    data = r.json()
    tag = data.get("tag_name", "?")
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        if name.endswith("windows-amd64.zip") and "legacy" not in name:
            return tag, asset["browser_download_url"]
    raise RuntimeError(f"В релизе sing-box {tag} не найден архив windows-amd64.zip")


def download_singbox(progress: Optional[Callable[[str], None]] = None) -> str:
    """Скачать sing-box.exe и wintun.dll в bin/. Вернуть версию sing-box."""
    log = progress or (lambda s: None)
    paths.ensure_dirs()

    log("Узнаю последнюю версию sing-box…")
    tag, url = _singbox_asset_url()
    log(f"Версия sing-box {tag}. Скачиваю…")
    r = requests.get(url, timeout=180, stream=True)
    r.raise_for_status()
    buf = io.BytesIO()
    for chunk in r.iter_content(chunk_size=64 * 1024):
        buf.write(chunk)
    buf.seek(0)

    log("Распаковываю sing-box.exe…")
    found = False
    with zipfile.ZipFile(buf) as z:
        for member in z.namelist():
            base = member.rsplit("/", 1)[-1]
            if base == "sing-box.exe":
                with z.open(member) as src:
                    paths.singbox_exe().write_bytes(src.read())
                found = True
            elif base == "wintun.dll":  # вдруг лежит в архиве
                with z.open(member) as src:
                    paths.wintun_dll().write_bytes(src.read())
    if not found:
        raise RuntimeError("sing-box.exe не найден в архиве")

    if not paths.wintun_dll().exists():
        _download_wintun(log)

    log(f"Готово. sing-box {tag} установлен.")
    return tag


def _download_wintun(log: Callable[[str], None]) -> None:
    """Скачать официальный wintun.dll (нужен для TUN-адаптера на Windows)."""
    log("Скачиваю wintun.dll (wintun.net)…")
    r = requests.get(WINTUN_URL, timeout=120)
    r.raise_for_status()
    with zipfile.ZipFile(io.BytesIO(r.content)) as z:
        for member in z.namelist():
            # нужен bin/amd64/wintun.dll
            if member.endswith("amd64/wintun.dll"):
                with z.open(member) as src:
                    paths.wintun_dll().write_bytes(src.read())
                log("  -> bin/wintun.dll")
                return
    raise RuntimeError("wintun.dll не найден в архиве wintun.net")


def tun_present() -> bool:
    return paths.singbox_exe().exists() and paths.wintun_dll().exists()


# Имена контракта native: на Windows компоненты TUN — это sing-box плюс wintun.
download_tun = download_singbox
