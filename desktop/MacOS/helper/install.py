"""Постановка и снятие привилегированного демона SCVPN.

Единственное место во всём приложении, где спрашивается пароль администратора,
и спрашивается он один раз за установку. Дальше приложение говорит с демоном
по сокету и никаких повышений прав не просит.

Скрипт установки собирается здесь и целиком отдаётся osascript одной строкой:
так пользователь видит один системный диалог, а не череду.
"""
from __future__ import annotations

import json
import plistlib
import shlex
import subprocess
import sys

from native import paths

# Сколько ждать демона перед SIGKILL при `launchctl bootout`/остановке машины.
# Худший случай снятия внутри daemon.py: стоп предыдущего sing-box
# (STOP_GRACE_SEC=7 + KILL_GRACE_SEC=3) под тем же замком, что и повторная
# подметка сироты в kill_stale_singbox (до 2*SWEEP_GRACE_SEC=6, если это
# происходит внутри активного start()) — итого до 16 секунд просто на то,
# чтобы stop() получил замок, плюс ещё до STOP_GRACE_SEC+KILL_GRACE_SEC=10 на
# остановку уже нового sing-box, который start() успел поднять. Итого до 26
# секунд по факту констант daemon.py — больше дефолтного ExitTimeOut в 20
# секунд, после которого launchd бьёт SIGKILL и оставляет sing-box сиротой
# без надзора. Ставим запас поверх худшего случая.
_EXIT_TIMEOUT_SEC = 40


def program_arguments() -> list[str]:
    """Чем launchd будет запускать демона.

    В собранном .app это сам исполняемый файл бандла с флагом --helper —
    отдельный интерпретатор Python в системе поэтому не нужен. При запуске из
    исходников это python из venv и тот же run.py.
    """
    if paths.FROZEN:
        return [sys.executable, "--helper"]
    return [sys.executable, str(paths.ROOT / "run.py"), "--helper"]


def plist_text() -> str:
    """Содержимое com.scvpn.helper.plist для текущей сборки."""
    data = {
        "Label": paths.HELPER_LABEL,
        "ProgramArguments": program_arguments(),
        "RunAtLoad": True,
        # Демон должен пережить собственное падение: пока он мёртв, sing-box
        # остался бы без надзора.
        "KeepAlive": True,
        # См. расчёт у _EXIT_TIMEOUT_SEC: дефолтных 20 секунд launchd не
        # хватает на худший случай снятия внутри daemon.py.
        "ExitTimeOut": _EXIT_TIMEOUT_SEC,
        "StandardErrorPath": "/var/log/scvpn-helper.log",
        "StandardOutPath": "/var/log/scvpn-helper.log",
    }
    return plistlib.dumps(data).decode()


def installed() -> bool:
    return paths.HELPER_PLIST.exists()


def _osascript(script: str, prompt: str) -> None:
    """Выполнить shell-скрипт от администратора одним системным диалогом."""
    r = subprocess.run(
        ["osascript", "-e",
         f'do shell script {json.dumps(script)} with prompt {json.dumps(prompt)} '
         f'with administrator privileges'],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        err = (r.stderr or "").strip()
        if "User canceled" in err or "-128" in err:
            raise RuntimeError("Установка отменена.")
        raise RuntimeError(err or "не удалось выполнить установку")


def install() -> None:
    """Поставить демона. Спросит пароль администратора — один раз."""
    tmp = paths.DATA_DIR / "com.scvpn.helper.plist"
    paths.ensure_dirs()
    tmp.write_text(plist_text(), encoding="utf-8")

    script = "; ".join([
        f"mkdir -p {shlex.quote(str(paths.HELPER_DIR))}",
        f"chown root:wheel {shlex.quote(str(paths.HELPER_DIR))}",
        f"chmod 755 {shlex.quote(str(paths.HELPER_DIR))}",
        f"cp {shlex.quote(str(tmp))} {shlex.quote(str(paths.HELPER_PLIST))}",
        f"chown root:wheel {shlex.quote(str(paths.HELPER_PLIST))}",
        f"chmod 644 {shlex.quote(str(paths.HELPER_PLIST))}",
        # bootout молча падает, если демона ещё нет — отсюда || true.
        f"launchctl bootout system/{paths.HELPER_LABEL} 2>/dev/null || true",
        f"launchctl bootstrap system {shlex.quote(str(paths.HELPER_PLIST))}",
    ])
    _osascript(script, "SCVPN устанавливает системный компонент для TUN-режима")
    tmp.unlink(missing_ok=True)


def uninstall() -> None:
    """Снять демона и убрать всё, что он у себя положил."""
    script = "; ".join([
        f"launchctl bootout system/{paths.HELPER_LABEL} 2>/dev/null || true",
        f"rm -f {shlex.quote(str(paths.HELPER_PLIST))}",
        f"rm -rf {shlex.quote(str(paths.HELPER_DIR))}",
        f"rm -f {shlex.quote(str(paths.HELPER_SOCKET))}",
    ])
    _osascript(script, "SCVPN удаляет системный компонент")
