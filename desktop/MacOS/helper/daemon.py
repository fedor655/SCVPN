"""Привилегированный демон SCVPN: поднимает и стережёт sing-box.

Зачем он есть. TUN на macOS требует root. Можно было бы спрашивать пароль на
каждое подключение через osascript, но тогда остаётся дыра, из-за которой
такие клиенты и славятся нестабильностью: приложение упало или его сняли, а
sing-box работает от root и держит маршруты. Весь трафик системы уходит в
мёртвый туннель, и выглядит это как «интернет пропал». Прибить sing-box может
только root, то есть нужен ещё один диалог пароля — а показать его уже некому.

Поэтому: приложение держит открытое соединение с этим демоном всё время
работы. Оборвалось соединение — значит приложение мертво — демон сам сносит
sing-box и возвращает маршруты. Не при следующем запуске, а сразу.

Демон запускает только бинарники из своей папки, принадлежащие root и
недоступные на запись остальным: сокет открыт группе admin, а всё, что
оттуда приходит, — недоверенный ввод (см. config.validate).

Граница доверия, без прикрас. Сокет открыт группе admin с правами 0660: это
защищает от посторонних пользователей, но не от своих. Любой процесс,
работающий от администратора, может подключиться и поднять туннель без
пароля, тогда как sudo пароль бы спросил. Новых возможностей это никому не
даёт — администратор на macOS и так может sudo и запустить sing-box сам, — но
разница есть: пока приложение установлено, управление туннелем стоит на одну
проверку дешевле. Проверки пира (LOCAL_PEERCRED) здесь нарочно нет, она за
рамками согласованной схемы.

Только стандартная библиотека: демон должен подниматься даже когда с
приложением что-то не так.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request
from collections import deque
from pathlib import Path
from typing import Any, Callable

from .config import ValidationError, build, validate

SOCKET_PATH = "/var/run/scvpn-helper.sock"
HELPER_DIR = Path("/Library/Application Support/SCVPN")
BIN_DIR = HELPER_DIR / "bin"
RUN_DIR = HELPER_DIR / "run"

# Файл-замок против второго демона (см. _acquire_singleton_lock).
LOCK_PATH = "/var/run/scvpn-helper.lock"

SINGBOX_RELEASES_API = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# Группа, которой открыт сокет. Обычные пользователи в неё не входят.
_ADMIN_GROUP = "admin"

# Потолки на размер запроса. config.validate() ограничивает длину каждого
# имени приложения, но не число элементов в списках: 200 000 имён — это конфиг
# на десяток мегабайт, который root молча запишет на диск. Столько приложений
# и исключений не бывает, поэтому граница стоит здесь, на входе демона.
_MAX_SPLIT_APPS = 256
_MAX_EXCLUDE_IPS = 1024
_MAX_LINE = 1 << 20   # 1 МиБ на строку запроса — с потолками выше с запасом

# Сколько ждать ухода sing-box: сначала по SIGTERM (он разбирает маршруты сам),
# потом по SIGKILL. Вынесено в константы, чтобы проверки не ждали по семь секунд.
STOP_GRACE_SEC = 7
KILL_GRACE_SEC = 3
SWEEP_GRACE_SEC = 3

# Сколько сообщений держим для клиента, который перестал читать сокет.
_OUTBOX_LIMIT = 256

# Сигналы, по которым демон уходит сам, сняв туннель. SIGHUP здесь не для
# красоты: демона запускают и руками (`python run.py --helper`), и закрытое
# окно терминала не должно оставлять root-овый sing-box с маршрутами.
_EXIT_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT)


def log(msg: str) -> None:
    """В stderr — launchd сложит его в StandardErrorPath."""
    print(f"[helper] {msg}", file=sys.stderr, flush=True)


# ----------------------------------------------------------------------
# Единственность демона
# ----------------------------------------------------------------------
# Держим дескриптор модульной переменной: если он попадёт только в локальную
# переменную функции, сборщик мусора его закроет вместе с блокировкой, и
# второй демон спокойно встанет следом за первым.
_lock_fd: int | None = None


def _acquire_singleton_lock(path: str | Path = LOCK_PATH) -> None:
    """Не пустить второй экземпляр демона поверх работающего.

    launchd держит один экземпляр сам, но ничто не мешает запустить второй
    руками (`sudo python run.py --helper`) поверх уже работающего launchd-
    демона. kill_stale_singbox() бьёт по всей командной строке sing-box, не
    различая, чей это процесс, — второй демон снёс бы РАБОЧИЙ туннель первого.
    А следом main() отвязывает и перехватывает сокет — так второй экземпляр
    забрал бы себе клиента первого, который остался бы говорить в пустоту.

    flock — ровно тот примитив, которым такие вещи принято решать в POSIX:
    неблокирующий эксклюзивный захват до какой-либо разрушительной операции.
    Замок на файле, а не на PID: PID-файлы врут после падения без очистки, а
    flock снимается ядром сам, как только процесс, державший дескриптор,
    умирает — второй демон встанет сразу же, без ручной уборки.
    """
    global _lock_fd
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise RuntimeError(
            f"другой экземпляр демона уже работает (замок занят: {path})"
        ) from None
    _lock_fd = fd


# ----------------------------------------------------------------------
# Проверка бинарника перед запуском
# ----------------------------------------------------------------------
def check_binary(path: Path) -> None:
    """Убедиться, что это наш бинарник и подменить его пользователь не мог.

    Демон работает от root. Запустить файл, в который может писать обычный
    пользователь, значит отдать ему root — поэтому три проверки: файл лежит в
    нашей папке, принадлежит root, и не доступен на запись группе и остальным.
    """
    try:
        resolved = path.resolve(strict=True)
    except OSError as e:
        raise PermissionError(f"нет такого бинарника: {path} ({e})") from e

    if not resolved.is_relative_to(BIN_DIR.resolve()):
        raise PermissionError(f"бинарник вне {BIN_DIR}: {resolved}")

    # Порядок проверок выбран так, чтобы каждая была причиной отказа хотя бы в
    # одном случае: проверка на root стоит последней, иначе она срабатывала бы
    # первой на любом пользовательском файле и накрывала бы собой остальные —
    # в том числе в проверках, которые гоняются не от root.
    st = resolved.stat()
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise PermissionError(f"бинарник доступен на запись не только root: {resolved}")
    if not st.st_mode & stat.S_IXUSR:
        raise PermissionError(f"бинарник не исполняемый: {resolved}")
    if st.st_uid != 0:
        raise PermissionError(f"бинарник не принадлежит root: {resolved}")


def _checked_xray_path(raw: object) -> str:
    """Проверить путь к ядру Xray, присланный клиентом.

    Этот путь попадает в правило process_path, которое выпускает процесс мимо
    туннеля. Подставив туда чужой бинарник, злоумышленник раздал бы себе обход
    VPN — поэтому проверяем имя, существование и права.

    Имя проверяем ПОСЛЕ канонизации, а не до. Раньше было наоборот, и симлинк
    с именем xray, ведущий на /bin/sh, проходил проверку именем, а в правило
    уезжал уже /bin/sh — ровно тот обход, который эта функция обязана закрыть.

    Чего здесь нет: требования root-владельца. Ядро Xray лежит в папке самого
    пользователя и ему же принадлежит — от владельца мы не защищаемся, он и
    так может делать со своим файлом что угодно. Защищаемся от чужих: файл,
    открытый на запись группе или остальным, отклоняем.
    """
    if not isinstance(raw, str) or not raw.startswith("/"):
        raise ValidationError(f"путь к ядру должен быть абсолютным, пришло {raw!r}")
    try:
        resolved = Path(raw).resolve(strict=True)
    except OSError as e:
        raise ValidationError(f"нет такого файла: {raw} ({e})") from e
    if resolved.name != "xray":
        raise ValidationError(
            f"ожидался бинарник с именем xray, а путь ведёт на {resolved.name!r}"
        )
    if not resolved.is_file():
        raise ValidationError(f"это не файл: {resolved}")
    st = resolved.stat()
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise ValidationError(f"ядро доступно на запись группе или остальным: {resolved}")
    return str(resolved)


def _check_sizes(req: dict) -> None:
    """Отбить запрос, из которого выйдет конфиг непристойного размера."""
    for key, limit in (("split_apps", _MAX_SPLIT_APPS), ("exclude_ips", _MAX_EXCLUDE_IPS)):
        value = req.get(key)
        if isinstance(value, list) and len(value) > limit:
            raise ValidationError(
                f"слишком длинный список {key}: {len(value)}, потолок {limit}"
            )


# ----------------------------------------------------------------------
# Установка sing-box (демон качает его себе сам)
# ----------------------------------------------------------------------
def pick_singbox_asset(assets: list[dict]) -> str:
    """URL архива sing-box для darwin/arm64 из списка ассетов релиза."""
    for asset in assets:
        name = asset.get("name", "")
        if name.endswith("darwin-arm64.tar.gz"):
            return asset["browser_download_url"]
    raise RuntimeError("в релизе sing-box не найден архив darwin-arm64.tar.gz")


def install_singbox(say: Callable[[str], None]) -> str:
    """Скачать sing-box в свою папку. Вернуть версию."""
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    os.chown(HELPER_DIR, 0, 0)
    os.chown(BIN_DIR, 0, 0)
    BIN_DIR.chmod(0o755)

    say("Узнаю последнюю версию sing-box…")
    req = urllib.request.Request(
        SINGBOX_RELEASES_API, headers={"Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310
        data = json.loads(r.read().decode())
    tag = data.get("tag_name", "?")
    url = pick_singbox_asset(data.get("assets", []))

    say(f"Версия sing-box {tag}. Скачиваю…")
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "sing-box.tar.gz"
        with urllib.request.urlopen(url, timeout=180) as r, archive.open("wb") as f:  # noqa: S310
            shutil.copyfileobj(r, f)

        say("Распаковываю…")
        found = None
        with tarfile.open(archive) as t:
            for member in t.getmembers():
                if member.isfile() and Path(member.name).name == "sing-box":
                    extracted = t.extractfile(member)
                    if extracted is None:
                        continue
                    found = Path(tmp) / "sing-box"
                    found.write_bytes(extracted.read())
                    break
        if found is None:
            raise RuntimeError("sing-box не найден в архиве")

        target = BIN_DIR / "sing-box"
        shutil.move(str(found), str(target))

    # root:wheel 0755 — иначе check_binary откажется его запускать, и правильно.
    os.chown(target, 0, 0)
    target.chmod(0o755)
    say(f"Готово. sing-box {tag} установлен.")
    return tag


# ----------------------------------------------------------------------
# Надзор за sing-box
# ----------------------------------------------------------------------
class Supervisor:
    """Один живой sing-box и его конфиг. Останавливается при обрыве клиента."""

    def __init__(self) -> None:
        self.proc: subprocess.Popen | None = None
        self._reader: threading.Thread | None = None
        # Клиентов может оказаться больше одного (соединений никто не считает),
        # а sing-box один на всех. Под замком start и stop не переплетаются, и
        # процесс не остаётся без хозяина между «создал» и «записал в self».
        self._lock = threading.RLock()

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, params: dict, xray_path: str, on_log: Callable[[str], None]) -> None:
        with self._lock:
            # Двух sing-box рядом быть не должно: они подерутся за default
            # route. Прежнего снимаем, осиротевшего от прошлого демона
            # подметаем, и если хоть один остался жив — не поднимаем ничего.
            if self.running:
                self.stop()
            if self.running:
                raise RuntimeError("прежний sing-box не снялся, второй поверх него не поднимаю")
            if not kill_stale_singbox():
                raise RuntimeError("осиротевший sing-box держит маршруты, сначала снимите его")

            exe = BIN_DIR / "sing-box"
            check_binary(exe)

            RUN_DIR.mkdir(parents=True, exist_ok=True)
            RUN_DIR.chmod(0o700)
            cfg_path = RUN_DIR / "singbox.json"
            cfg_path.write_text(
                json.dumps(build(params, xray_path), ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            cfg_path.chmod(0o600)

            self.proc = subprocess.Popen(
                [str(exe), "run", "-c", str(cfg_path)],
                cwd=str(BIN_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
            log(f"sing-box запущен, PID {self.proc.pid}")
            # Колбэк передаём аргументом, а не читаем self._on_log из потока:
            # после рестарта «sing-box завершился» от старого процесса ушло бы
            # новому клиенту, как будто это про его туннель.
            self._reader = threading.Thread(
                target=self._pump, args=(self.proc, on_log), daemon=True
            )
            self._reader.start()

    def _pump(self, proc: subprocess.Popen, on_log: Callable[[str], None]) -> None:
        if proc.stdout is None:
            return
        for line in proc.stdout:
            line = line.rstrip("\n")
            if line:
                on_log(line)
        code = proc.poll()
        on_log(f"sing-box завершился (код {code})")
        log(f"sing-box завершился (код {code})")

    def stop(self) -> None:
        """Снять sing-box и отпустить ручку только после подтверждённой смерти.

        Раньше self.proc обнулялся первым делом, а неудача wait() глоталась.
        Если процесс не умер (непрерываемый сон для TUN-процесса правдоподобен),
        демон терял ручку на живом sing-box: running врал False, оба finally его
        пропускали, а следующий start поднимал второй рядом с первым.
        """
        with self._lock:
            proc = self.proc
            if proc is None:
                return
            if proc.poll() is not None:
                self.proc = None
                return

            log("останавливаю sing-box (маршруты вернутся сами)")
            try:
                proc.terminate()
                proc.wait(timeout=STOP_GRACE_SEC)
            except subprocess.TimeoutExpired:
                log("sing-box не ушёл по SIGTERM — добиваю")
                try:
                    proc.kill()
                    proc.wait(timeout=KILL_GRACE_SEC)
                except (subprocess.TimeoutExpired, OSError) as e:
                    log(f"ТРЕВОГА: sing-box PID {proc.pid} пережил SIGKILL ({e}), "
                        f"туннель остаётся поднятым — ручку не отпускаю")
                    return
            except OSError as e:
                log(f"ошибка остановки sing-box PID {proc.pid}: {e}")
                if proc.poll() is None:
                    return

            self.proc = None


SUPERVISOR = Supervisor()


def _stale_pattern() -> str:
    """Шаблон командной строки, которую составляем только мы."""
    return re.escape(f"{BIN_DIR / 'sing-box'} run -c {RUN_DIR / 'singbox.json'}")


def _proc_tool(args: list[str]) -> subprocess.CompletedProcess | None:
    """Запустить pgrep/pkill. None — инструмент не отработал, ответа нет."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        log(f"не смог выполнить {args[0]}: {e}")
        return None
    # 0 — нашлось, 1 — никого не нашлось. Всё остальное (2 — кривой шаблон,
    # 3 — внутренняя ошибка) молчать нельзя: так защита от сироты погаснет
    # незаметно, а узнаем мы об этом по пропавшему интернету.
    if r.returncode not in (0, 1):
        log(f"{args[0]} вернул {r.returncode}: {r.stderr.strip()}")
    return r


def _stale_pids() -> list[str] | None:
    """PID-ы осиротевшего sing-box. None — посмотреть не удалось.

    Разница между «никого нет» и «не смог узнать» здесь решающая: на этот
    ответ опирается запрет поднимать туннель поверх чужого sing-box. Молчаливое
    «никого» при сломанном pgrep пустило бы второй поверх первого, поэтому
    неизвестность — это не пустой список, а отказ.
    """
    r = _proc_tool(["/usr/bin/pgrep", "-f", _stale_pattern()])
    if r is None or r.returncode not in (0, 1):
        return None
    return r.stdout.split()


def kill_stale_singbox() -> bool:
    """Снять sing-box, переживший прошлый запуск демона. True — чисто.

    Обрыв клиента демон видит сам, а вот собственную смерть по -9 — нет: Popen
    вместе с демоном пропадает, а sing-box остаётся держать маршруты. Это ровно
    та мёртвая сеть, ради которой всё затевалось, поэтому новый демон начинает
    с чистого листа. Шаблон — целая командная строка, которую составляем только
    мы: чужой процесс под неё не попадёт, а наш попадёт, даже если его успели
    завернуть в оболочку.

    Ждём именно смерти, а не отправки сигнала. pkill возвращается сразу, и
    раньше демон рапортовал об успехе, пока сирота была жива: sing-box,
    игнорирующий SIGTERM, оставался, клиент подключался и поднимал ВТОРОЙ
    рядом с ним. Двое дерутся за default route — та же мёртвая сеть, ради
    которой всё затевалось. Поэтому: SIGTERM, ожидание, при неудаче SIGKILL,
    и только по факту исчезновения — запись об успехе.

    Не смогли посмотреть — отвечаем False, а не True. Неизвестность здесь
    ничем не лучше живой сироты: решение по этому ответу принимается одно и
    то же — поднимать туннель или нет.
    """
    left = _stale_pids()
    if left is None:
        log("ТРЕВОГА: не смог проверить, остался ли sing-box от прошлого запуска — "
            "считаю, что остался")
        return False
    if not left:
        return True

    pattern = _stale_pattern()
    for sig in ("-TERM", "-KILL"):
        log(f"остался sing-box от прошлого запуска демона: {' '.join(left)}, шлю {sig}")
        if _proc_tool(["/usr/bin/pkill", sig, "-f", pattern]) is None:
            return False
        deadline = time.monotonic() + SWEEP_GRACE_SEC
        while time.monotonic() < deadline:
            left = _stale_pids()
            if left is None:
                return False
            if not left:
                log("осиротевший sing-box снят")
                return True
            time.sleep(0.2)

    log(f"ТРЕВОГА: осиротевший sing-box не снялся: {' '.join(left)} — "
        f"поднимать туннель поверх него нельзя, он держит маршруты")
    return False


# ----------------------------------------------------------------------
# Протокол
# ----------------------------------------------------------------------
def handle_line(line: str, state: dict[str, Any]) -> dict:
    """Разобрать одну строку запроса и выполнить её. Всегда возвращает ответ.

    Демон не имеет права падать от кривого ввода: клиент — недоверенный, а
    падение демона означает, что sing-box останется без надзора.
    """
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError("ожидался объект")
    except Exception as e:  # noqa: BLE001
        # Не только ValueError: на глубоко вложенном JSON разборщик отдаёт
        # RecursionError, и он выходил наружу, минуя все ветки, — а наружу это
        # обрыв соединения, то есть снятие туннеля одной кривой строкой.
        return {"ok": False, "error": f"не разобрал запрос: {type(e).__name__}: {e}"}

    cmd = req.get("cmd")
    say: Callable[[str], None] = state.get("say") or (lambda s: None)

    try:
        if cmd == "start":
            _check_sizes(req)
            params = validate(req)
            # Путь к ядру приходит от клиента, но правило process_path даёт
            # процессу выход мимо туннеля — значит путь надо проверить, а не
            # принять на слово (см. _checked_xray_path).
            xray_path = _checked_xray_path(req.get("xray_path"))
            SUPERVISOR.start(params, xray_path, say)
            return {"ok": True, "running": True}

        if cmd == "stop":
            SUPERVISOR.stop()
            # Не зашитое False: stop() имеет право вернуться с живым процессом,
            # если тот пережил SIGKILL. Ответить «выключено», пока маршруты
            # держатся, — это ровно та ложь про состояние, от которой уходим.
            return {"ok": not SUPERVISOR.running, "running": SUPERVISOR.running}

        if cmd == "status":
            return {"ok": True, "running": SUPERVISOR.running,
                    "singbox": (BIN_DIR / "sing-box").exists()}

        if cmd == "install_singbox":
            tag = install_singbox(say)
            return {"ok": True, "version": tag}

        return {"ok": False, "error": f"неизвестная команда: {cmd!r}"}

    except ValidationError as e:
        return {"ok": False, "error": str(e)}
    except PermissionError as e:
        return {"ok": False, "error": f"отказано: {e}"}
    except Exception as e:  # noqa: BLE001
        log(f"ошибка при обработке {cmd!r}: {e}")
        return {"ok": False, "error": str(e)}


class Outbox:
    """Исходящие сообщения клиенту. Отправка не должна доставать до sing-box.

    Логи sing-box идут клиенту по этому же соединению: _pump -> say -> отправка.
    Если писать прямо из _pump и клиент перестанет читать, sendall встанет,
    труба stdout переполнится — и заблокируется сам sing-box. Связь получается
    такая: поведение клиентского сокета управляет ядром, поднимающим туннель.
    Поэтому пишет отдельный поток, а очередь ограничена.

    Но выбрасывать при переполнении можно только логи. Ответ на команду
    выбрасывать нельзя ни при каких обстоятельствах: клиент его ждёт, и
    потерянный ответ на start оставляет приложение в убеждении, что туннеля
    нет, — пока весь трафик системы идёт в туннель. Это та же ложь про
    состояние, ради ухода от которой написан весь модуль. Поэтому для ответа
    место освобождается за счёт самого старого лога, а не за счёт ответа.

    Но у «не выбрасываем» обязан быть предел. Если клиент не читает, а логов,
    за счёт которых можно освободить место, в очереди нет, — расти дальше
    некуда: это память root-процесса. На `_hard_limit` кадрах разговор
    заканчивается: такой клиент завис, соединение закрывается, а dead-man's
    switch снимет туннель, следить за которым уже некому. Молча расти нельзя.
    """

    def __init__(self, conn: socket.socket, maxsize: int = _OUTBOX_LIMIT) -> None:
        self._conn = conn
        self._maxsize = maxsize
        # Запас сверх обычного потолка на случай, когда выбрасывать нечего.
        self._hard_limit = maxsize * 4
        self._items: deque[dict] = deque()
        # Сколько в очереди логов. Без счётчика поиск «самого старого лога»
        # обходил всю очередь впустую на каждом кадре, когда логов в ней нет.
        self._logs = 0
        self._cv = threading.Condition()
        self._closed = False
        self._overflowed = False
        self.dropped = 0
        self._thread = threading.Thread(target=self._run, daemon=True)

    def pending(self) -> int:
        with self._cv:
            return len(self._items)

    def start(self) -> Outbox:
        self._thread.start()
        return self

    def send(self, obj: dict) -> None:
        """Ответ клиенту. Не блокирует, не бросает и не выбрасывается."""
        self._put(obj, droppable=False)

    def send_log(self, obj: dict) -> None:
        """Строка лога. Всё то же самое, но при тесноте её и выбрасываем."""
        self._put(obj, droppable=True)

    def _put(self, obj: dict, droppable: bool) -> None:
        with self._cv:
            if self._closed:
                return
            if len(self._items) >= self._maxsize:
                if droppable:
                    self._note_drop()
                    return
                # Ответу место освобождаем за счёт самого старого лога.
                if self._logs:
                    self._drop_oldest_log()
                    self._note_drop()
                elif len(self._items) >= self._hard_limit:
                    self._overflow()
                    return
            self._items.append(obj)
            if "log" in obj:
                self._logs += 1
            self._cv.notify()

    def _overflow(self) -> None:
        """Клиент не читает ответы, а выбрасывать нечего. Заканчиваем разговор."""
        if self._overflowed:
            return
        self._overflowed = True
        self._closed = True
        log(f"очередь ответов переполнена ({len(self._items)} кадров) — "
            f"клиент не читает, закрываю соединение")
        # shutdown, а не close: readline у обслуживающего потока получит EOF,
        # тот уйдёт в finally, а finally у нас и есть dead-man's switch.
        try:
            self._conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self._cv.notify()

    def _drop_oldest_log(self) -> bool:
        """Убрать самый старый лог. Вызывать только когда счётчик не нулевой."""
        for i, item in enumerate(self._items):
            if "log" in item:
                del self._items[i]
                self._logs -= 1
                return True
        self._logs = 0
        return False

    def _note_drop(self) -> None:
        self.dropped += 1
        if self.dropped == 1:
            log("клиент не читает сокет — выбрасываю логи, чтобы не тормозить sing-box")

    def close(self, timeout: float = 2.0) -> None:
        """Дать писателю дослать очередь и уйти."""
        with self._cv:
            self._closed = True
            self._cv.notify()
        if self._thread.is_alive():
            self._thread.join(timeout)

    def _run(self) -> None:
        while True:
            with self._cv:
                while not self._items and not self._closed:
                    self._cv.wait()
                if not self._items:
                    return
                obj = self._items.popleft()
                if "log" in obj:
                    self._logs -= 1
            try:
                # errors="replace": в тексте ошибки лежит то, что прислал
                # клиент, вплоть до одиночного суррогата, а строгий encode на
                # нём падает — и это уронило бы соединение, то есть сняло бы
                # туннель из-за одного кривого имени в запросе.
                data = json.dumps(obj, ensure_ascii=False) + "\n"
                self._conn.sendall(data.encode("utf-8", "replace"))
            except OSError:
                return


def serve_client(conn: socket.socket) -> None:
    """Обслужить одного клиента и прибрать за ним, когда он отвалится.

    Обрыв соединения — это и есть dead-man's switch: приложение мертво,
    значит туннель надо снять, иначе система останется без интернета.
    """
    # Всё, что может бросить, — внутри try. Снаружи оставался запуск Outbox, а
    # поток создать не всегда удаётся (accept-цикл плодит их без ограничения):
    # исключение уходило мимо finally, то есть мимо самого dead-man's switch.
    outbox: Outbox | None = None
    try:
        outbox = Outbox(conn).start()
        send = outbox.send
        state: dict[str, Any] = {"say": lambda s: outbox.send_log({"log": s})}
        # errors="replace": на кривых байтах читатель не должен разваливаться,
        # пусть мусор дойдёт до handle_line и получит вежливый отказ.
        with conn.makefile("r", encoding="utf-8", errors="replace") as reader:
            while True:
                # Читаем с потолком: строка без перевода строки не должна расти
                # в памяти root-процесса бесконечно. Упёрлись в потолок —
                # разговор окончен, такой клиент нам не свой.
                line = reader.readline(_MAX_LINE)
                if not line:
                    break
                if not line.endswith("\n") and len(line) >= _MAX_LINE:
                    send({"ok": False, "error": "запрос длиннее допустимого"})
                    break
                line = line.strip()
                if not line:
                    continue
                send(handle_line(line, state))
    except OSError as e:
        log(f"соединение оборвалось: {e}")
    except Exception as e:  # noqa: BLE001
        log(f"обслуживание клиента прервалось: {type(e).__name__}: {e}")
    finally:
        # Единственная ветка выхода: сюда приходят и обрыв, и EOF, и любая
        # неожиданная ошибка выше. Второго клиента приложение не открывает,
        # поэтому «туннель поднят, а этот клиент ушёл» всегда значит «снимать».
        if SUPERVISOR.running:
            log("клиент отключился, а туннель поднят — снимаю его")
            SUPERVISOR.stop()
        if outbox is not None:
            outbox.close()
        try:
            conn.close()
        except OSError:
            pass


def _on_signal(signum, _frame) -> None:  # noqa: ANN001
    """Уйти, сняв туннель. Первым делом — заглушить повторные сигналы.

    Без этого второй SIGTERM, пришедший пока stop() ждёт ухода sing-box,
    поднимал SystemExit прямо из ожидания: снятие обрывалось на середине,
    демон уходил с кодом 0, а sing-box оставался жив с маршрутами.
    """
    for sig in _EXIT_SIGNALS:
        try:
            signal.signal(sig, signal.SIG_IGN)
        except (OSError, ValueError):
            pass
    log(f"сигнал {signum} — снимаю туннель и выхожу")
    raise SystemExit(0)


def install_signal_handlers() -> None:
    """Перехватить сигналы, по которым иначе умерли бы молча, мимо finally.

    Голый Python умирает от SIGTERM/SIGHUP/SIGQUIT без всякой уборки, и
    sing-box остаётся сиротой с чужими маршрутами. От SIGKILL защиты нет —
    её роль играет подметание при следующем старте (kill_stale_singbox).
    """
    for sig in _EXIT_SIGNALS:
        signal.signal(sig, _on_signal)


def serve_forever(srv: socket.socket) -> int:
    """Принимать клиентов, пока не попросят уйти. На выходе — снять туннель."""
    # ponytail: клиентов обслуживаем по одному в потоке, без ограничения их
    # числа. Приложение открывает ровно одно соединение; если понадобится
    # защита от заваливания, ставить семафор на число живых потоков.
    # KeyboardInterrupt здесь не ловится: SIGINT перехвачен install_signal_handlers
    # и приходит сюда как SystemExit — finally отрабатывает одинаково для обоих.
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=serve_client, args=(conn,), daemon=True).start()
    finally:
        SUPERVISOR.stop()
        srv.close()
    return 0


def main() -> int:
    if os.geteuid() != 0:
        log("демон обязан работать от root")
        return 1

    # До этой черты — только чтение. Дальше идут разрушительные операции
    # (снятие чужого sing-box, перехват сокета), поэтому единственность
    # проверяем первым делом, раньше kill_stale_singbox.
    try:
        _acquire_singleton_lock()
    except RuntimeError as e:
        log(str(e))
        return 1

    install_signal_handlers()

    if not kill_stale_singbox():
        log("предыдущий sing-box снять не удалось — туннель поднимать не буду")

    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCKET_PATH)

    # Открываем сокет группе admin и только ей: обычный пользователь не должен
    # уметь поднять туннель и подсунуть свои правила маршрутизации.
    import grp

    os.chown(SOCKET_PATH, 0, grp.getgrnam(_ADMIN_GROUP).gr_gid)
    os.chmod(SOCKET_PATH, 0o660)

    srv.listen(4)
    log(f"слушаю {SOCKET_PATH}")

    try:
        return serve_forever(srv)
    finally:
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
