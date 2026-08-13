"""Разовое скачивание ядра Xray-core с официального GitHub.

Берём последний релиз из репозитория XTLS/Xray-core, скачиваем архив для
macOS arm64 и распаковываем в bin/ ровно три файла: xray, geoip.dat,
geosite.dat. Это единственный «внешний» источник, и он официальный и открытый.

Подписывать скачанное не нужно: линковщик Go сам проставляет ad-hoc подпись
для darwin/arm64, иначе бинарник не запустился бы вовсе. Достаточно дать
право на исполнение.

sing-box здесь нет намеренно: его запускает root, поэтому качает и кладёт его
к себе привилегированный демон, а не мы (см. helper/daemon.py).
"""
from __future__ import annotations

import io
import stat
import zipfile
from typing import Callable, Optional

import requests

from . import paths

RELEASES_API = "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
ASSET_NAME = "Xray-macos-arm64-v8a.zip"
WANTED = {"xray", "geoip.dat", "geosite.dat"}


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

    # Из zip права не переносятся — бит исполнения ставим сами.
    exe = paths.xray_exe()
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    log(f"Готово. Ядро Xray-core {tag} установлено в bin/")
    return tag


def core_present() -> bool:
    return paths.xray_exe().exists() and paths.geoip_dat().exists() and paths.geosite_dat().exists()


# ----------------------------------------------------------------------
# Компоненты TUN — целиком на стороне демона
# ----------------------------------------------------------------------
def tun_present() -> bool:
    """Лежит ли sing-box на месте. Про демона здесь не спрашиваем намеренно.

    Раньше тут было `helper_installed() and singbox_exe().exists()`, и это
    делало понятия вложенными: «компоненты есть» включало в себя «демон
    установлен», хотя ставит демона совсем другая ветка — privileged() /
    acquire_privilege(). На чистой машине из такой вложенности получался
    неснимаемый круг: префлайт в main_window требовал компоненты раньше прав,
    компонентов не было, потому что их кладёт демон, а демона ставила только
    ветка прав — за уже непроходимым гейтом.

    Теперь два понятия не пересекаются: privileged() — «демон установлен»,
    tun_present() — «бинарник на диске». Проверка `.exists()` работает и без
    root: папка демона read-only для пользователя, но читаемая (0755).
    """
    return paths.singbox_exe().exists()


def download_tun(progress: Optional[Callable[[str], None]] = None) -> str:
    """Попросить демона скачать sing-box себе. Вернуть версию.

    Сами не качаем намеренно: sing-box запускает root, и лежать он обязан там,
    куда пользователь писать не может.
    """
    from . import tun

    return tun.install_singbox(progress)
