"""TUN-режим для macOS: весь трафик устройства идёт через VPN.

Как устроено:
  - Xray уже работает от имени пользователя и слушает локальный SOCKS (как в
    режиме прокси) — именно он делает TLS/Reality-рукопожатие с сервером. Этот
    путь одинаков в обоих режимах, поэтому автоподбор отпечатка остаётся в силе.
  - sing-box поднимает utun-адаптер, забирает ВЕСЬ трафик системы и заворачивает
    его в этот локальный SOCKS Xray. Он требует root, поэтому запускает его не
    приложение, а привилегированный демон (см. helper/).
  - Чтобы не было петли, у sing-box есть правило process_path для бинарника
    Xray — его соединения идут напрямую. Запасной пояс — route_exclude_address
    с IP сервера.

Этот модуль — тонкий клиент демона. Соединение держится открытым всё время
работы приложения: его обрыв демон читает как «приложение мертво» и снимает
туннель сам. Это главное отличие от windows-версии, где ядро живёт под нами.
"""
from __future__ import annotations

import json
import os
import signal
import socket
import threading
from typing import Callable, Optional

from helper.config import SPLIT_EXCLUDE, SPLIT_INCLUDE, SPLIT_OFF  # noqa: F401
from helper.install import install as _install_helper
from helper.install import installed as helper_installed
from shared.models import Server

from . import paths

PRIVILEGE_QUESTION = (
    "TUN-режим (весь трафик) работает через системный компонент,\n"
    "который нужно установить один раз. Понадобится пароль администратора.\n\n"
    "Установить сейчас?"
)


def privileged() -> bool:
    """Можно ли прямо сейчас поднять TUN. На macOS это установленный демон."""
    return helper_installed()


# Текст последней ошибки acquire_privilege(), когда та вернула не "ok"/"restart".
# Контракт acquire_privilege() -> str (общий с Windows) менять нельзя, а
# install() из helper/install.py поднимает содержательный RuntimeError —
# «Установка отменена.» или сырой stderr launchctl. Раньше этот текст просто
# терялся в except, и пользователь на macOS видел зашитую фразу ни о чём на
# самом частом первом включении TUN. Здесь — просто карман для него.
_last_error = ""


def last_privilege_error() -> str:
    """Что пошло не так в последнем acquire_privilege(), если не "ok"."""
    return _last_error


def acquire_privilege() -> str:
    """Поставить демона. "ok" — можно продолжать в этом же процессе."""
    global _last_error
    try:
        _install_helper()
    except RuntimeError as e:
        _last_error = str(e)
        return "failed"
    if helper_installed():
        _last_error = ""
        return "ok"
    _last_error = "демон не запустился после установки (launchd его не поднял)"
    return "failed"


# ----------------------------------------------------------------------
# Резолв IP сервера (для обходного маршрута)
# ----------------------------------------------------------------------
def resolve_ips(host: str) -> list[str]:
    """Список IPv4-адресов хоста. Если host уже IP — вернуть его."""
    try:
        socket.inet_aton(host)
        return [host]  # уже IPv4
    except OSError:
        pass
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET)
        return sorted({i[4][0] for i in infos})
    except Exception:  # noqa: BLE001
        return []


# ----------------------------------------------------------------------
# Уборка за прошлым запуском
# ----------------------------------------------------------------------
def cleanup_stray(log: Optional[Callable[[str], None]] = None) -> bool:
    """Прибить ядро Xray, пережившее прошлый запуск приложения.

    Про sing-box здесь заботиться не нужно: он под надзором демона, и демон
    снимает его сам, как только обрывается соединение с приложением. Остаётся
    Xray — он живёт от пользователя, и его мы можем снять сами.
    """
    say = log or (lambda s: None)
    f = paths.DATA_DIR / "xray.pid"
    if not f.exists():
        return False
    try:
        pid = int(f.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        f.unlink(missing_ok=True)
        return False

    # Имя образа сверяем обязательно: номера процессов переиспользуются, и без
    # этой сверки мы могли бы прибить чужой процесс, случайно получивший тот же.
    if not _process_is_xray(pid):
        f.unlink(missing_ok=True)
        return False

    say(f"[*] С прошлого запуска остался xray (PID {pid}) — убираю.")
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        say(f"[!] Не удалось: {e}")
        return False
    f.unlink(missing_ok=True)
    return True


def _process_is_xray(pid: int) -> bool:
    import subprocess

    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return out.rsplit("/", 1)[-1] == "xray"


# ----------------------------------------------------------------------
# Соединение с демоном
# ----------------------------------------------------------------------
class HelperError(RuntimeError):
    pass


class _Connection:
    """Одно соединение с демоном. Живёт, пока живёт туннель.

    У соединения ровно один читатель за раз. Пока идёт start() или разовый
    install_singbox(), это вызывающий поток (через request()). После start()
    читателем становится поток Tun._read_logs (через stream_logs()) — и с
    этого момента request() больше не читает: два потока, одновременно
    вызывающих readline() на одном и том же файле сокета, отдавали бы строки
    непредсказуемо кому попало, и ответ на stop() мог годами дожидаться,
    пока его по ошибке не съест поток логов (см. send() и Tun.stop()).
    """

    def __init__(self, on_log: Callable[[str], None]) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(str(paths.HELPER_SOCKET))
        except OSError as e:
            raise HelperError(
                f"Системный компонент не отвечает ({e}).\n"
                "Меню «⋯» → «Переустановить системный компонент»."
            ) from e
        self._file = self.sock.makefile("r", encoding="utf-8")
        self._on_log = on_log

    def request(self, payload: dict, timeout: float = 240.0) -> dict:
        """Отправить команду и дождаться ответа. Строки log по пути отдаём наружу.

        Годится только пока соединение читает исключительно вызывающий поток
        — то есть до того, как запущен Tun._read_logs (см. класс выше).
        """
        self.sock.settimeout(timeout)
        self.sock.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode())
        for line in self._file:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "log" in msg:
                self._on_log(msg["log"])
                continue
            return msg
        raise HelperError("Системный компонент закрыл соединение.")

    def send(self, payload: dict, timeout: float = 5.0) -> None:
        """Отправить команду, не читая ответ. Для случая, когда чтение уже
        занято потоком логов (см. Tun.stop())."""
        self.sock.settimeout(timeout)
        self.sock.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode())

    def stream_logs(self, on_log: Callable[[str], None]) -> None:
        """Читать лог до обрыва. Возврат означает, что соединение закрылось."""
        self.sock.settimeout(None)
        for line in self._file:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "log" in msg:
                on_log(msg["log"])

    def close(self) -> None:
        # shutdown раньше close: если поток стоит в блокирующем recv внутри
        # stream_logs, одного close() ему может не хватить, чтобы проснуться
        # немедленно — тот же приём демон применяет к самому себе на своей
        # стороне (см. Outbox._overflow в helper/daemon.py).
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._file.close()
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def install_singbox(progress: Optional[Callable[[str], None]] = None) -> str:
    """Попросить демона скачать sing-box себе. Вернуть версию."""
    say = progress or (lambda s: None)
    if not helper_installed():
        raise HelperError("Сначала установи системный компонент (включи TUN-режим).")
    conn = _Connection(say)
    try:
        reply = conn.request({"cmd": "install_singbox"})
    finally:
        conn.close()
    if not reply.get("ok"):
        raise HelperError(reply.get("error", "не удалось установить sing-box"))
    return reply.get("version", "?")


# ----------------------------------------------------------------------
# Туннель
# ----------------------------------------------------------------------
class Tun:
    def __init__(
        self,
        on_log: Optional[Callable[[str], None]] = None,
        on_state: Optional[Callable[[bool], None]] = None,
    ) -> None:
        self._conn: Optional[_Connection] = None
        self._pump: Optional[threading.Thread] = None
        self._running = False
        self.on_log = on_log or (lambda s: None)
        self.on_state = on_state or (lambda running: None)

    @property
    def running(self) -> bool:
        return self._running

    def start(
        self,
        server: Server,
        socks_port: int,
        split_mode: str = SPLIT_OFF,
        split_apps: list[str] | None = None,
    ) -> None:
        if not helper_installed():
            raise HelperError("Системный компонент не установлен.")

        if self._conn is not None:
            # Прошлая сессия не закрыла своё соединение сама — например,
            # on_state(False) уже пришёл (sing-box умер сам, см. _read_logs),
            # а вызывающая сторона на этот сигнал стоп не позвала (main_window
            # чистит только когда vpn_mode остаётся "tun"; переключение
            # способа подключения посреди поднятого TUN этот путь не
            # проходит). Без явного закрытия здесь второй start() поверх
            # первого завёл бы ещё один сокет и поток поверх уже висящего.
            self.stop()

        # Ключ tun_stack появится в DEFAULT_SETTINGS только в Задаче 11 —
        # .get() с умолчанием "gvisor" не чинить, так и задумано.
        from shared.storage import load_settings

        stack = load_settings().get("tun_stack", "gvisor")

        ips = resolve_ips(server.address)
        if not ips:
            self.on_log(f"[tun] не удалось определить IP сервера {server.address}, маршрут-исключение пуст")
        else:
            self.on_log(f"[tun] обход для IP сервера: {', '.join(ips)}")

        apps = split_apps or []
        if split_mode != SPLIT_OFF and apps:
            what = "мимо VPN" if split_mode == SPLIT_EXCLUDE else "через VPN"
            self.on_log(f"[tun] раздельный туннель: {what} — {', '.join(apps)}")

        conn = _Connection(lambda s: self.on_log("[tun] " + s))
        try:
            reply = conn.request({
                "cmd": "start",
                "socks_port": socks_port,
                "exclude_ips": ips,
                "split_mode": split_mode,
                "split_apps": apps,
                "stack": stack,
                "xray_path": str(paths.xray_exe().resolve()),
            }, timeout=60.0)
            if not reply.get("ok"):
                raise HelperError(reply.get("error", "не удалось поднять TUN"))
        except Exception:
            # Сюда попадает и request() (таймаут, обрыв, кривой кадр лога),
            # и HelperError выше при reply["ok"] is False, и AttributeError,
            # если reply вдруг окажется не словарём (.get() на нём же и
            # упадёт — сегодня демон шлёт только словари, но эта ветка не
            # должна зависеть от того, что он никогда не пришлёт иначе).
            # Всё это — уже ПОСЛЕ того, как демон мог поднять туннель. Если
            # тут не закрыть conn, соединение зависает в traceback исключения
            # (тот же путь, которым QMessageBox.critical в main_window держит
            # e), а туннель остаётся поднятым до тех пор, пока сборщик мусора
            # не доберётся до сокета — то есть непредсказуемо.
            conn.close()
            raise

        self._conn = conn
        self._running = True
        self.on_log("[tun] sing-box запущен (поднимаю utun-адаптер)…")
        self.on_state(True)

        # Соединение остаётся открытым: демон читает его обрыв как «приложение
        # мертво» и снимает туннель сам. С этого момента и до stop() читает
        # сокет только этот поток — см. предупреждение в _Connection.
        self._pump = threading.Thread(target=self._read_logs, daemon=True)
        self._pump.start()

    def _read_logs(self) -> None:
        conn = self._conn
        if conn is None:
            return

        def on_line(s: str) -> None:
            self.on_log("[tun] " + s)
            # Демон снял sing-box сам — упал ли он, или его забрал другой
            # клиент — а соединение при этом НЕ рвёт: обрыв связи демон
            # читает как «приложение мертво», а тут приложение живо, просто
            # без туннеля (см. Supervisor._pump в helper/daemon.py). Без этой
            # проверки Tun продолжал бы считать себя подключённым до
            # следующего действия пользователя — та самая ложь о состоянии,
            # от которой уходил весь проект. conn здесь не трогаем: закрыть
            # его безопасно можно только из другого потока (см. stop() и
            # docstring _Connection.close), а мы сейчас внутри цикла чтения
            # этого же соединения.
            if self._running and s.startswith("sing-box завершился"):
                self._running = False
                self.on_state(False)

        try:
            conn.stream_logs(on_line)
        except OSError:
            pass
        if self._running:
            self._running = False
            self.on_log("[tun] системный компонент закрыл соединение")
            self.on_state(False)

    def stop(self) -> None:
        conn = self._conn
        self._conn = None
        if conn is None:
            if self._running:
                self._running = False
                self.on_state(False)
            return
        self.on_log("[tun] останавливаю туннель (маршруты вернутся сами)…")
        self._running = False
        try:
            # request() здесь не годится: ответ на sock читает поток
            # _read_logs (запущен в start()), и вычитывать сокет из двух
            # потоков одновременно нельзя — ответ мог достаться не тому. Шлём
            # команду не дожидаясь ответа, а закрытие соединения ниже — это
            # ВТОРОЙ, независимый способ снять туннель, и на него самого по
            # себе демон уже реагирует правильно (см. docstring модуля).
            conn.send({"cmd": "stop"})
        except OSError as e:
            self.on_log(f"[tun] не удалось отправить команду остановки: {e}")
        finally:
            # Даже если команда stop не дошла или её съел разрыв связи —
            # демон увидит обрыв соединения и снимет туннель сам.
            conn.close()
        self.on_state(False)
