"""Постановка и снятие привилегированного демона SCVPN.

Единственное место во всём приложении, где спрашивается пароль администратора,
и спрашивается он один раз за установку. Дальше приложение говорит с демоном
по сокету и никаких повышений прав не просит.

Скрипт установки собирается здесь и целиком отдаётся osascript одной строкой:
так пользователь видит один системный диалог, а не череду.
"""
from __future__ import annotations

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
    """Демон стоит под ЭТУ сборку, а не просто когда-то стоял.

    Сравниваем содержимое файла с тем, что даёт plist_text() прямо сейчас, а
    не факт его существования. ProgramArguments внутри — абсолютный путь к
    программе; после переезда .app или перехода исходники<->сборка старый
    plist остаётся на диске, но указывает в никуда. launchd с KeepAlive вечно
    перезапускал бы несуществующий путь, а приложение считало бы, что всё
    поставлено и работает.
    """
    try:
        return paths.HELPER_PLIST.read_text(encoding="utf-8") == plist_text()
    except (OSError, ValueError):
        # OSError — когда файл не существует или доступ запрещён.
        # ValueError (подкласс которого UnicodeDecodeError) — когда содержимое
        # испорчено (printf не атомарен, обрыв записи на середине UTF-8
        # многобайтовой последовательности) или это бинарный plist (результат
        # plutil -convert binary1), не читающийся как UTF-8 текст.
        return False


def _as_literal(s: str) -> str:
    """Экранировать строку в AppleScript double-quoted string literal.

    `json.dumps` для этого не годится, хотя выглядит подходяще: JSON и
    AppleScript совпадают только на `\\`, `\"`, `\n`, `\r`, `\t`. Не-ASCII
    json.dumps по умолчанию уводит в `\\uXXXX` — а такую escape-
    последовательность AppleScript не компилирует вовсе, синтаксическая
    ошибка на пустом месте. Промпт демона — русский текст, поэтому install()
    и uninstall() падали на любой машине, не показав пользователю даже
    диалог пароля. Не-ASCII здесь просто не трогаем: osascript читает `-e` в
    UTF-8.
    """
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    s = s.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return '"' + s + '"'


def _do_shell_script_command(script: str, prompt: str) -> str:
    """Собрать AppleScript-текст `do shell script ...` одним системным диалогом.

    Вынесено отдельной функцией, чтобы саму сборку строки можно было
    проверить настоящим `osascript` без повышения прав: `with administrator
    privileges` из проверяемого текста убирается, а `do shell script ... with
    prompt ...` без него компилируется и выполняется как обычный пользователь
    (проверено вручную) — значит компилируемость и содержимое литералов
    проверяются тем же кодом, которым пользуется install()/uninstall().
    """
    return (f'do shell script {_as_literal(script)} with prompt {_as_literal(prompt)} '
            f'with administrator privileges')


def _osascript(script: str, prompt: str) -> None:
    """Выполнить shell-скрипт от администратора одним системным диалогом."""
    r = subprocess.run(
        ["osascript", "-e", _do_shell_script_command(script, prompt)],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        err = (r.stderr or "").strip()
        if "User canceled" in err or "-128" in err:
            raise RuntimeError("Установка отменена.")
        raise RuntimeError(err or "не удалось выполнить установку")


def install() -> None:
    """Поставить демона. Спросит пароль администратора — один раз."""
    script = " && ".join([
        f"mkdir -p {shlex.quote(str(paths.HELPER_DIR))}",
        f"chown root:wheel {shlex.quote(str(paths.HELPER_DIR))}",
        f"chmod 755 {shlex.quote(str(paths.HELPER_DIR))}",
        # Содержимое plist едет прямо в скрипте, а не копией файла из
        # пользовательской папки: cp из user-writable пути — это TOCTOU, окно
        # на подмену файла или подсунутый симлинк между записью и cp, ровно
        # пока пользователь вводит пароль. Здесь подменять нечего — текст
        # приходит вместе со скриптом, который целиком выполняется от root.
        f"printf %s {shlex.quote(plist_text())} > {shlex.quote(str(paths.HELPER_PLIST))}",
        f"chown root:wheel {shlex.quote(str(paths.HELPER_PLIST))}",
        f"chmod 644 {shlex.quote(str(paths.HELPER_PLIST))}",
        # bootout молча падает, если демона ещё нет — отсюда || true. Он же
        # даёт этому шагу успешный код возврата независимо от исхода, поэтому
        # цепочка && им не обрывается.
        f"launchctl bootout system/{paths.HELPER_LABEL} 2>/dev/null || true",
        f"launchctl bootstrap system {shlex.quote(str(paths.HELPER_PLIST))}",
    ])
    _osascript(script, "SCVPN устанавливает системный компонент для TUN-режима")


def uninstall() -> None:
    """Снять демона и убрать всё, что он у себя положил."""
    script = " && ".join([
        f"launchctl bootout system/{paths.HELPER_LABEL} 2>/dev/null || true",
        f"rm -f {shlex.quote(str(paths.HELPER_PLIST))}",
        f"rm -rf {shlex.quote(str(paths.HELPER_DIR))}",
        f"rm -f {shlex.quote(str(paths.HELPER_SOCKET))}",
    ])
    _osascript(script, "SCVPN удаляет системный компонент")
