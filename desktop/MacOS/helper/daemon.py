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
import urllib.request
from pathlib import Path
from typing import Any, Callable

from .config import ValidationError, build, validate

SOCKET_PATH = "/var/run/scvpn-helper.sock"
HELPER_DIR = Path("/Library/Application Support/SCVPN")
BIN_DIR = HELPER_DIR / "bin"
RUN_DIR = HELPER_DIR / "run"

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


def log(msg: str) -> None:
    """В stderr — launchd сложит его в StandardErrorPath."""
    print(f"[helper] {msg}", file=sys.stderr, flush=True)


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

    st = resolved.stat()
    if st.st_uid != 0:
        raise PermissionError(f"бинарник не принадлежит root: {resolved}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise PermissionError(f"бинарник доступен на запись не только root: {resolved}")
    if not st.st_mode & stat.S_IXUSR:
        raise PermissionError(f"бинарник не исполняемый: {resolved}")


def _checked_xray_path(raw: object) -> str:
    """Проверить путь к ядру Xray, присланный клиентом.

    Этот путь попадает в правило process_path, которое выпускает процесс мимо
    туннеля. Подставив туда чужой бинарник, злоумышленник раздал бы себе обход
    VPN — поэтому проверяем и имя, и что файл существует.
    """
    if not isinstance(raw, str) or not raw.startswith("/"):
        raise ValidationError(f"путь к ядру должен быть абсолютным, пришло {raw!r}")
    path = Path(raw)
    if path.name != "xray":
        raise ValidationError(f"ожидался бинарник с именем xray, пришло {path.name!r}")
    if not path.is_file():
        raise ValidationError(f"нет такого файла: {path}")
    return str(path.resolve())


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
        self._on_log: Callable[[str], None] = lambda s: None
        # Клиентов может оказаться больше одного (соединений никто не считает),
        # а sing-box один на всех. Под замком start и stop не переплетаются, и
        # процесс не остаётся без хозяина между «создал» и «записал в self».
        self._lock = threading.RLock()

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, params: dict, xray_path: str, on_log: Callable[[str], None]) -> None:
        with self._lock:
            if self.running:
                self.stop()

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

            self._on_log = on_log
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
            self._reader = threading.Thread(target=self._pump, args=(self.proc,), daemon=True)
            self._reader.start()

    def _pump(self, proc: subprocess.Popen) -> None:
        if proc.stdout is None:
            return
        for line in proc.stdout:
            line = line.rstrip("\n")
            if line:
                self._on_log(line)
        code = proc.poll()
        self._on_log(f"sing-box завершился (код {code})")
        log(f"sing-box завершился (код {code})")

    def stop(self) -> None:
        with self._lock:
            proc = self.proc
            self.proc = None
            if proc is None or proc.poll() is not None:
                return
            log("останавливаю sing-box (маршруты вернутся сами)")
            try:
                proc.terminate()
                try:
                    proc.wait(timeout=7)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)
            except Exception as e:  # noqa: BLE001
                log(f"ошибка остановки: {e}")


SUPERVISOR = Supervisor()


def kill_stale_singbox() -> None:
    """Снять sing-box, переживший прошлый запуск демона.

    Обрыв клиента демон видит сам, а вот собственную смерть по -9 — нет: Popen
    вместе с демоном пропадает, а sing-box остаётся держать маршруты. Это ровно
    та мёртвая сеть, ради которой всё затевалось, поэтому новый демон начинает
    с чистого листа. Шаблон — целая командная строка, которую составляем только
    мы: чужой процесс под неё не попадёт, а наш попадёт, даже если его успели
    завернуть в оболочку.
    """
    pattern = re.escape(f"{BIN_DIR / 'sing-box'} run -c {RUN_DIR / 'singbox.json'}")
    try:
        r = subprocess.run(["/usr/bin/pkill", "-f", pattern], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        log(f"не смог поискать осиротевший sing-box: {e}")
        return
    if r.returncode == 0:
        log("снял sing-box, оставшийся от прошлого запуска демона")


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
    except ValueError as e:
        return {"ok": False, "error": f"не разобрал запрос: {e}"}

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
            return {"ok": True, "running": False}

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


def serve_client(conn: socket.socket) -> None:
    """Обслужить одного клиента и прибрать за ним, когда он отвалится.

    Обрыв соединения — это и есть dead-man's switch: приложение мертво,
    значит туннель надо снять, иначе система останется без интернета.
    """
    lock = threading.Lock()

    def send(obj: dict) -> None:
        with lock:
            try:
                # errors="replace": в тексте ошибки лежит то, что прислал
                # клиент, вплоть до одиночного суррогата, а строгий encode на
                # нём падает — и это уронило бы соединение, то есть сняло бы
                # туннель из-за одного кривого имени в запросе.
                data = json.dumps(obj, ensure_ascii=False) + "\n"
                conn.sendall(data.encode("utf-8", "replace"))
            except OSError:
                pass

    state: dict[str, Any] = {"say": lambda s: send({"log": s})}

    try:
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
    finally:
        # Единственная ветка выхода: сюда приходят и обрыв, и EOF, и любая
        # неожиданная ошибка выше. Второго клиента приложение не открывает,
        # поэтому «туннель поднят, а этот клиент ушёл» всегда значит «снимать».
        if SUPERVISOR.running:
            log("клиент отключился, а туннель поднят — снимаю его")
            SUPERVISOR.stop()
        try:
            conn.close()
        except OSError:
            pass


def main() -> int:
    if os.geteuid() != 0:
        log("демон обязан работать от root")
        return 1

    # SIGTERM прилетает при launchctl unload и при выключении: без обработчика
    # Python умрёт молча, минуя finally, и оставит sing-box сиротой.
    def _on_signal(signum, _frame):  # noqa: ANN001, ANN202
        log(f"сигнал {signum} — снимаю туннель и выхожу")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    kill_stale_singbox()

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

    # ponytail: клиентов обслуживаем по одному в потоке, без ограничения их
    # числа. Приложение открывает ровно одно соединение; если понадобится
    # защита от заваливания, ставить семафор на число живых потоков.
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=serve_client, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        SUPERVISOR.stop()
        srv.close()
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
    return 0
