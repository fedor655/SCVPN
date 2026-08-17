"""TUN-режим для Windows: весь трафик устройства идёт через VPN.

Как устроено (намеренно просто и прозрачно):
  - Xray уже работает и слушает локальный SOCKS (как в режиме прокси) — именно
    он делает TLS/Reality-рукопожатие с сервером. Этот путь одинаков в обоих
    режимах, поэтому автоподбор отпечатка остаётся в силе.
  - sing-box поднимает виртуальный TUN-адаптер (через wintun.dll), забирает
    ВЕСЬ трафик системы и заворачивает его в этот локальный SOCKS Xray.
  - Чтобы не было петли (соединение самого Xray к серверу не должно снова
    попасть в TUN), IP сервера добавляется в route_exclude_address — sing-box
    сам прописывает обходной маршрут и САМ ЖЕ убирает все маршруты при выходе.

TUN требует прав администратора (создание адаптера и правка таблицы маршрутов).
"""
from __future__ import annotations

import ctypes
import ipaddress
import socket
import subprocess
import sys
import threading
from typing import Callable, Optional

from models import Server

from . import paths


# ----------------------------------------------------------------------
# Права администратора
# ----------------------------------------------------------------------
def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:  # noqa: BLE001
        return False


# Тексты ShellExecuteW для кодов возврата <= 32 (ошибка) — самые частые
# причины отказа, чтобы last_privilege_error() говорил по существу, а не
# "не получилось". Источник — документация Microsoft на ShellExecute.
_SHELL_EXECUTE_ERRORS = {
    0: "не хватило памяти или ресурсов операционной системы.",
    2: "не найден исполняемый файл для перезапуска.",
    3: "не найден путь для перезапуска.",
    5: "запрос на права администратора отклонён (нажато «Нет» в диалоге UAC).",
    8: "не хватило памяти для запуска.",
    26: "файл занят другим процессом.",
    31: "для этого файла не назначено приложение, которое могло бы его открыть.",
}

# Текст последней ошибки acquire_privilege(), когда та вернула "failed".
# Контракт acquire_privilege() -> str (общий с macOS) не трогаем — это просто
# карман для причины, которую иначе было бы некуда деть: main_window иначе
# показал бы одну и ту же зашитую фразу и на отказе пользователя от UAC, и на
# том, что ShellExecuteW не смог найти файл для перезапуска.
_last_error = ""


def last_privilege_error() -> str:
    """Что пошло не так в последнем acquire_privilege(), если не "restart"."""
    return _last_error


def relaunch_as_admin() -> bool:
    """Перезапустить приложение с правами администратора (вызовет UAC).

    Возвращает True, если запрос на повышение отправлен (текущий процесс надо
    закрыть). False — если не на Windows или пользователь отказался; причину
    смотри в last_privilege_error().
    """
    global _last_error
    if not sys.platform.startswith("win"):
        _last_error = "TUN-режим с повышением прав доступен только на Windows."
        return False
    try:
        import os

        workdir = str(paths.ROOT)
        if getattr(sys, "frozen", False):
            # собранный .exe: запускаем сам exe с теми же аргументами
            file = sys.executable
            params = " ".join(f'"{a}"' for a in sys.argv[1:])
        else:
            # из исходников: pythonw.exe "C:\...\run.py" + аргументы (пути абсолютные!)
            file = sys.executable
            script = os.path.abspath(sys.argv[0])
            rest = sys.argv[1:]
            params = " ".join(f'"{a}"' for a in [script, *rest])
        rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", file, params, workdir, 1)
        rc = int(rc)
        if rc > 32:  # >32 — успех (UAC показан)
            _last_error = ""
            return True
        _last_error = _SHELL_EXECUTE_ERRORS.get(rc, f"ShellExecuteW вернул код ошибки {rc}.")
        return False
    except Exception as e:  # noqa: BLE001
        _last_error = f"{type(e).__name__}: {e}"
        return False


# ----------------------------------------------------------------------
# Резолв IP сервера (для обходного маршрута)
# ----------------------------------------------------------------------
def resolve_ips(host: str) -> list[str]:
    """Список IP-адресов хоста, v4 и v6. Если host уже IP — вернуть его.

    Обе версии, а не только IPv4: список уходит в route_exclude_address, то есть
    в запасной пояс от петли «ядро -> TUN -> ядро». Сервер с IPv6-адресом при
    IPv4-only резолве давал пустой список, и его трафик заворачивало в туннель.
    """
    try:
        return [str(ipaddress.ip_address(host))]  # уже адрес
    except ValueError:
        pass
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_UNSPEC)
    except Exception:  # noqa: BLE001
        return []
    found = set()
    for i in infos:
        # У IPv6 getaddrinfo может отдать адрес с зоной («fe80::1%eth0»).
        # В маршрут такое не годится, а ip_address на нём падает — поэтому
        # зону срезаем, а остаток всё равно проверяем.
        try:
            found.add(str(ipaddress.ip_address(i[4][0].partition("%")[0])))
        except ValueError:
            continue
    return sorted(found)


# ----------------------------------------------------------------------
# Конфиг sing-box: только TUN -> SOCKS Xray (никакой крипты тут нет)
# ----------------------------------------------------------------------
# Режимы раздельного туннелирования (split tunneling).
SPLIT_OFF = "off"           # все приложения через VPN
SPLIT_EXCLUDE = "exclude"   # все через VPN, кроме выбранных
SPLIT_INCLUDE = "include"   # только выбранные через VPN

# Ядра, которые мы запускаем, и файлы с их PID — см. cleanup_stray().
# Оба живут отдельными процессами и переживают аварийное закрытие приложения.
CORES = {
    "singbox.pid": ("sing-box", "TUN-адаптер"),
    "xray.pid": ("xray", "соединение с сервером"),
    "awg.pid": ("scvpn-awg", "туннель AmneziaWG"),
}


def pid_file(name: str):
    return paths.DATA_DIR / name


def _process_matches(pid: int, image: str) -> bool:
    """Жив ли процесс с таким PID и это действительно нужный нам образ.

    Имя образа проверяем обязательно: номера процессов переиспользуются, и без
    этой сверки мы могли бы прибить чужой процесс, случайно получивший тот же.
    """
    try:
        out = subprocess.run(
            ["tasklist", "/fi", f"PID eq {pid}", "/fo", "csv", "/nh"],
            capture_output=True, text=True, encoding="cp866", errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
    except Exception:  # noqa: BLE001
        return False
    return image in out.lower()


def cleanup_stray(log: Optional[Callable[[str], None]] = None) -> bool:
    """Прибить ядра, пережившие прошлый запуск приложения.

    Зачем. И Xray, и sing-box — отдельные процессы, а в TUN-режиме ещё и с
    правами администратора. Если приложение закрылось аварийно или его сняли
    из диспетчера, ядра остаются работать сами по себе: туннель поднят, но
    управлять им уже нечем — не отключить и не переключить сервер. А если
    Xray при этом успел умереть, а sing-box нет, TUN отдаёт весь трафик
    системы в никуда, и снаружи это выглядит как «интернет пропал».

    Возвращает True, если что-то прибрали.
    """
    say = log or (lambda s: None)
    cleaned = False
    failed = False

    for name, (image, what) in CORES.items():
        f = pid_file(name)
        if not f.exists():
            continue
        try:
            pid = int(f.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            f.unlink(missing_ok=True)
            continue

        if not _process_matches(pid, image):
            f.unlink(missing_ok=True)   # процесс уже завершился штатно
            continue

        say(f"[*] С прошлого запуска остался {image} (PID {pid}) — держит {what}, убираю.")
        try:
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True, text=True,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except Exception as e:  # noqa: BLE001
            say(f"[!] Не удалось: {e}")

        if _process_matches(pid, image):
            failed = True
        else:
            f.unlink(missing_ok=True)
            cleaned = True

    if failed:
        say("[!] Не хватило прав снять зависшее ядро. Запусти SCVPN от имени "
            "администратора — или перезагрузись, если интернет не работает.")
    elif cleaned:
        say("[*] Зависшие ядра убраны, маршруты вернулись.")
    return cleaned


def build_singbox_config(
    socks_port: int,
    exclude_ips: list[str],
    *,
    log_level: str = "warn",
    split_mode: str = SPLIT_OFF,
    split_apps: list[str] | None = None,
) -> dict:
    """Конфиг sing-box: TUN -> SOCKS Xray, плюс правила раздельного туннеля.

    Раздельное туннелирование делает сам sing-box: он умеет сопоставлять
    соединение с процессом-владельцем (`process_name`) и отправлять его либо
    в туннель, либо напрямую. Поэтому это работает только в TUN-режиме —
    системный прокси про приложения ничего не знает.
    """
    # Маска по версии адреса: у IPv6 хост-префикс это /128, а не /32.
    excludes = [f"{ip}/128" if ":" in ip else f"{ip}/32" for ip in exclude_ips]
    apps = [a.strip() for a in (split_apps or []) if a.strip()]

    rules: list[dict] = []

    # Первым делом выводим из туннеля сам Xray. Без этого режим «Авто» в TUN
    # зацикливался: Xray решает пустить российский сайт напрямую, его прямое
    # соединение снова попадает в TUN, оттуда обратно в Xray — и так по кругу.
    # Раньше это обходили запретом «Авто» в TUN-режиме, теперь запрет не нужен.
    #
    # Рядом с ним обязан стоять scvpn-awg: у него свой UDP-сокет до сервера
    # WireGuard, и он не проходит через Xray. Попади этот сокет в туннель — тот
    # самый круг, только замкнутый на себя: пакеты туннеля идут в туннель.
    # Правило одно на оба пути, потому что причина у них одна.
    rules.append({
        "process_path": [str(paths.xray_exe()), str(paths.awg_exe())],
        "outbound": "direct",
    })

    if apps and split_mode == SPLIT_EXCLUDE:
        # Выбранные — мимо VPN, всё остальное (final) — в туннель.
        rules.append({"process_name": apps, "outbound": "direct"})
    elif apps and split_mode == SPLIT_INCLUDE:
        # Выбранные — в туннель, всё остальное — напрямую (см. final ниже).
        rules.append({"process_name": apps, "outbound": "to-xray"})

    final = "direct" if (apps and split_mode == SPLIT_INCLUDE) else "to-xray"

    route: dict = {"auto_detect_interface": True, "final": final, "rules": rules}

    return {
        "log": {"level": log_level},
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "SCVPNTun",
                "address": ["172.18.0.1/30"],
                "mtu": 1500,
                "auto_route": True,
                "strict_route": False,
                "stack": "gvisor",
                "route_exclude_address": excludes,
            }
        ],
        "outbounds": [
            {
                "type": "socks",
                "tag": "to-xray",
                "server": "127.0.0.1",
                "server_port": socks_port,
                "version": "5",
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": route,
    }


# ----------------------------------------------------------------------
# Запуск/остановка sing-box
# ----------------------------------------------------------------------
class Tun:
    def __init__(
        self,
        on_log: Optional[Callable[[str], None]] = None,
        on_state: Optional[Callable[[bool], None]] = None,
    ) -> None:
        self._proc: Optional[subprocess.Popen] = None
        self._reader: Optional[threading.Thread] = None
        self.on_log = on_log or (lambda s: None)
        self.on_state = on_state or (lambda running: None)

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(
        self,
        server: Server,
        socks_port: int,
        split_mode: str = SPLIT_OFF,
        split_apps: list[str] | None = None,
    ) -> None:
        if not is_admin():
            raise PermissionError("TUN-режим требует прав администратора.")
        exe = paths.singbox_exe()
        if not exe.exists():
            raise FileNotFoundError(f"Не найден sing-box: {exe}. Нажми «Скачать TUN».")
        if not paths.wintun_dll().exists():
            raise FileNotFoundError("Не найден wintun.dll. Нажми «Скачать TUN».")

        ips = resolve_ips(server.address)
        if not ips:
            self.on_log(f"[tun] не удалось определить IP сервера {server.address}, маршрут-исключение пуст")
        else:
            self.on_log(f"[tun] обход для IP сервера: {', '.join(ips)}")

        apps = split_apps or []
        if split_mode != SPLIT_OFF and apps:
            what = "мимо VPN" if split_mode == SPLIT_EXCLUDE else "через VPN"
            self.on_log(f"[tun] раздельный туннель: {what} — {', '.join(apps)}")

        cfg = build_singbox_config(
            socks_port, ips, split_mode=split_mode, split_apps=apps
        )
        cfg_path = paths.DATA_DIR / "singbox_running.json"
        import json
        cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")

        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._proc = subprocess.Popen(
            [str(exe), "run", "-c", str(cfg_path)],
            cwd=str(paths.BIN_DIR),  # рядом лежит wintun.dll
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=creationflags,
        )
        # PID на диск — чтобы следующий запуск приложения смог прибрать за собой,
        # если этот процесс переживёт нас (см. cleanup_stray).
        try:
            pid_file("singbox.pid").write_text(str(self._proc.pid), encoding="utf-8")
        except OSError:
            pass

        self.on_log("[tun] sing-box запущен (поднимаю TUN-адаптер)…")
        self.on_state(True)
        self._reader = threading.Thread(target=self._read_output, daemon=True)
        self._reader.start()

    def _read_output(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        for line in self._proc.stdout:
            line = line.rstrip("\n")
            if line:
                self.on_log("[tun] " + line)
        code = self._proc.poll()
        self.on_log(f"[tun] sing-box завершился (код {code})")
        self.on_state(False)

    def stop(self) -> bool:
        """Снять sing-box. True — он снят; False — пережил остановку.

        Тот же контракт возврата у macOS-версии (`Tun.stop()` в
        `desktop/macOS/`): там правду о снятии добывает ответ привилегированного
        демона, здесь — poll() своего же процесса. Общий у них смысл: пока
        sing-box жив, TUN-адаптер поднят и маршруты держатся, и интерфейс не
        имеет права показать «Отключено» — `ui/main_window.py` решает это по
        возврату.
        """
        if self._proc is None:
            return True
        if self._proc.poll() is None:
            self.on_log("[tun] останавливаю sing-box (маршруты вернутся сами)…")
            try:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=7)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
                    self._proc.wait(timeout=3)
            except Exception as e:  # noqa: BLE001
                self.on_log(f"[tun] ошибка остановки: {e}")
        if self._proc.poll() is None:
            # Ручку на живом процессе не отпускаем: иначе running врал бы
            # False, pid-файл ушёл бы вместе с единственным следом, и убрать
            # за собой не смог бы даже следующий запуск (см. cleanup_stray).
            self.on_log(
                "[tun] ТРЕВОГА: sing-box пережил остановку — туннель ещё держит маршруты"
            )
            return False
        self._proc = None
        pid_file("singbox.pid").unlink(missing_ok=True)
        self.on_state(False)
        return True


# ----------------------------------------------------------------------
# Обёртки контракта native: см. MacOS/native/tun.py — то же имя, другая
# реализация привилегий (там это не UAC, а установка демона через launchd).
# ----------------------------------------------------------------------
PRIVILEGE_QUESTION = (
    "TUN-режим (весь трафик) требует прав администратора.\n"
    "Перезапустить приложение от имени администратора?"
)


def privileged() -> bool:
    """Можно ли прямо сейчас поднять TUN. На Windows это права администратора."""
    return is_admin()


def acquire_privilege() -> str:
    """Запросить права. "restart" — процесс надо закрыть, поднимется новый."""
    return "restart" if relaunch_as_admin() else "failed"
