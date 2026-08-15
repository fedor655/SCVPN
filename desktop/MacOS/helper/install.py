"""Постановка и снятие привилегированного демона SCVPN.

Единственное место во всём приложении, где спрашивается пароль администратора,
и спрашивается он один раз за установку. Дальше приложение говорит с демоном
по сокету и никаких повышений прав не просит.

Скрипт установки собирается здесь и целиком отдаётся osascript одной строкой:
так пользователь видит один системный диалог, а не череду.
"""
from __future__ import annotations

import hashlib
import os
import plistlib
import shlex
import subprocess
import sys
from pathlib import Path

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


# Файлы, из которых состоит демон при запуске из исходников. Список короткий
# намеренно: демон обходится стандартной библиотекой и ничего из shared/ и
# native/ не импортирует, поэтому копировать весь проект незачем.
_DAEMON_FILES = ("run.py", "helper/__init__.py", "helper/config.py", "helper/daemon.py")


def _base_python() -> str:
    """Интерпретатор для демона: базовый, а не venv-овский.

    venv лежит внутри проекта, а проект вполне может лежать в ~/Documents —
    оттуда root не прочитает даже pyvenv.cfg (см. install()). Демону venv и не
    нужен: сторонних пакетов он не требует.
    """
    return getattr(sys, "_base_executable", None) or sys.executable


def program_arguments() -> list[str]:
    """Чем launchd будет запускать демона.

    В собранном .app это сам исполняемый файл бандла с флагом --helper —
    отдельный интерпретатор Python в системе поэтому не нужен. При запуске из
    исходников это базовый python и копия run.py в root-овой папке демона: на
    сами исходники указывать нельзя, см. install().
    """
    if paths.FROZEN:
        return [sys.executable, "--helper"]
    return [_base_python(), str(paths.HELPER_CODE_DIR / "run.py"), "--helper"]


def _code_fingerprint() -> str:
    """Отпечаток исходников демона — чтобы installed() видел устаревшую копию.

    Копия в root-овой папке живёт своей жизнью: правка daemon.py в проекте её
    не меняет, а plist остаётся прежним — и приложение считало бы, что стоит
    та версия, которую мы только что написали, пока launchd крутит старую.
    Отпечаток едет в plist, поэтому проверка «стоит ли демон под ЭТУ сборку»
    ловит и это, тем же сравнением содержимого, что и переезд .app.
    """
    h = hashlib.sha256()
    for rel in _DAEMON_FILES:
        h.update((paths.ROOT / rel).read_bytes())
    return h.hexdigest()[:16]


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
    if not paths.FROZEN:
        # Демон её не читает — она здесь только затем, чтобы installed()
        # отличил копию кода от нынешних исходников (см. _code_fingerprint).
        data["EnvironmentVariables"] = {"SCVPN_HELPER_CODE": _code_fingerprint()}
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
    # только для стенда Фазы 2 плана переписывания (docs/macos-swift-implementation-plan.md,
    # раздел 0.3) — удаляется в Задаче 8.3
    if os.environ.get("SCVPN_ASSUME_HELPER"):
        return True
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


def _code_steps() -> list[str]:
    """Шаги установки, кладущие код демона в его root-овую папку.

    Зачем копия вместо запуска прямо из проекта. launchd запускает демона от
    root, а у root-процессов нет доступа к ~/Documents, ~/Desktop и
    ~/Downloads: TCC отдаёт EPERM на open(). Проект (вместе с venv внутри)
    вполне может лежать в такой папке — тогда python падает с
    `PermissionError: ... venv/pyvenv.cfg` ещё до импорта site, launchd с
    KeepAlive перезапускает его по кругу, сокет не появляется никогда, а
    «Скачать компоненты TUN» упирается в «Системный компонент не отвечает» —
    при том что plist на месте и installed() честно говорит True.

    Содержимое файлов едет прямо в скрипте, как и plist, а не копируется
    откуда-то с диска: cp читал бы исходники от имени root и споткнулся бы о
    тот же самый TCC, а промежуточная папка в доступном root месте была бы
    окном на подмену кода, который root потом запускает (тот же TOCTOU, из-за
    которого plist пишется printf'ом). Файлов три, все — стандартная
    библиотека, суммарно десятки килобайт: в командную строку помещаются с
    запасом.
    """
    code = shlex.quote(str(paths.HELPER_CODE_DIR))
    steps = [f"rm -rf {code}", f"mkdir -p {code}/helper"]
    for rel in _DAEMON_FILES:
        text = (paths.ROOT / rel).read_text(encoding="utf-8")
        steps.append(f"printf %s {shlex.quote(text)} > {shlex.quote(str(paths.HELPER_CODE_DIR / rel))}")
    steps += [f"chown -R root:wheel {code}", f"chmod -R go-w {code}"]
    return steps


# Папки, к которым TCC не пускает процессы root. Держим кортежем, а не
# вычисляем на месте: список один и тот же в отказе установщика и в проверке
# расположения бандла.
_TCC_DIRS = (Path.home() / "Documents", Path.home() / "Desktop", Path.home() / "Downloads")


def _refuse_tcc_location() -> None:
    """root не читает ~/Documents, ~/Desktop, ~/Downloads — TCC отдаёт EPERM.

    Демон, запущенный launchd из такой папки, не стартует никогда, а
    installed() при этом честно отвечает True: plist на месте. Получается
    компонент, который «установлен» и не работает. Отказываем на входе.

    Из исходников это уже закрыто копией кода в root-овой папке
    (см. _code_steps), поэтому проверка касается только собранного .app: там
    ProgramArguments указывает внутрь бандла, где бы тот ни лежал.
    """
    if not paths.FROZEN:
        return
    app = paths.ROOT.parent.parent  # .../SCVPN.app/Contents/MacOS -> .../SCVPN.app
    for bad in _TCC_DIRS:
        if app.is_relative_to(bad):
            raise RuntimeError(
                "Перенеси SCVPN.app в /Applications и запусти оттуда.\n"
                "Из этой папки системный компонент не запустится: у процессов "
                "root нет доступа к Документам, Рабочему столу и Загрузкам."
            )


def install() -> None:
    """Поставить демона. Спросит пароль администратора — один раз."""
    _refuse_tcc_location()
    script = " && ".join([
        f"mkdir -p {shlex.quote(str(paths.HELPER_DIR))}",
        f"chown root:wheel {shlex.quote(str(paths.HELPER_DIR))}",
        f"chmod 755 {shlex.quote(str(paths.HELPER_DIR))}",
        *([] if paths.FROZEN else _code_steps()),
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
