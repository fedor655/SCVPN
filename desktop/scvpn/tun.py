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
import socket
import subprocess
import sys
import threading
from typing import Callable, Optional

from . import paths
from .models import Server


# ----------------------------------------------------------------------
# Права администратора
# ----------------------------------------------------------------------
def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:  # noqa: BLE001
        return False


def relaunch_as_admin() -> bool:
    """Перезапустить приложение с правами администратора (вызовет UAC).

    Возвращает True, если запрос на повышение отправлен (текущий процесс надо
    закрыть). False — если не на Windows или пользователь отказался.
    """
    if not sys.platform.startswith("win"):
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
        return int(rc) > 32  # >32 — успех (UAC показан)
    except Exception:  # noqa: BLE001
        return False


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
# Конфиг sing-box: только TUN -> SOCKS Xray (никакой крипты тут нет)
# ----------------------------------------------------------------------
# Режимы раздельного туннелирования (split tunneling).
SPLIT_OFF = "off"           # все приложения через VPN
SPLIT_EXCLUDE = "exclude"   # все через VPN, кроме выбранных
SPLIT_INCLUDE = "include"   # только выбранные через VPN

# Файл с PID запущенного нами sing-box — см. cleanup_stray().
PID_FILE_NAME = "singbox.pid"


def _pid_file():
    return paths.DATA_DIR / PID_FILE_NAME


def _is_singbox(pid: int) -> bool:
    """Жив ли процесс с таким PID и это действительно sing-box.

    Проверяем имя образа, потому что PID переиспользуются: без этого мы могли
    бы прибить чужой процесс, случайно получивший тот же номер.
    """
    try:
        out = subprocess.run(
            ["tasklist", "/fi", f"PID eq {pid}", "/fo", "csv", "/nh"],
            capture_output=True, text=True, encoding="cp866", errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
    except Exception:  # noqa: BLE001
        return False
    return "sing-box" in out.lower()


def cleanup_stray(log: Optional[Callable[[str], None]] = None) -> bool:
    """Прибить sing-box, переживший прошлый запуск приложения.

    Зачем. sing-box поднимается с правами администратора и живёт отдельным
    процессом. Если приложение закрылось аварийно (или его сняли из диспетчера),
    sing-box остаётся — а с ним и TUN-адаптер, который забирает весь трафик
    системы и отдаёт его в SOCKS уже мёртвого Xray. Снаружи это выглядит как
    «интернет пропал»: соединения просто висят до таймаута.

    Возвращает True, если что-то прибрали.
    """
    say = log or (lambda s: None)
    f = _pid_file()
    if not f.exists():
        return False

    try:
        pid = int(f.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        f.unlink(missing_ok=True)
        return False

    if not _is_singbox(pid):
        f.unlink(missing_ok=True)   # процесс уже завершился штатно
        return False

    say(f"[tun] с прошлого запуска остался sing-box (PID {pid}) — он держит TUN, убираю.")
    try:
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            capture_output=True, text=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except Exception as e:  # noqa: BLE001
        say(f"[tun] не удалось: {e}")

    if _is_singbox(pid):
        say("[!] Не хватило прав снять зависший sing-box. Запусти SCVPN от имени "
            "администратора — или перезагрузись, если интернет не работает.")
        return False

    f.unlink(missing_ok=True)
    say("[tun] зависший TUN убран, маршруты вернулись.")
    return True


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
    excludes = [f"{ip}/32" for ip in exclude_ips]
    apps = [a.strip() for a in (split_apps or []) if a.strip()]

    rules: list[dict] = []
    if apps and split_mode == SPLIT_EXCLUDE:
        # Выбранные — мимо VPN, всё остальное (final) — в туннель.
        rules.append({"process_name": apps, "outbound": "direct"})
    elif apps and split_mode == SPLIT_INCLUDE:
        # Выбранные — в туннель, всё остальное — напрямую (см. final ниже).
        rules.append({"process_name": apps, "outbound": "to-xray"})

    final = "direct" if (apps and split_mode == SPLIT_INCLUDE) else "to-xray"

    route: dict = {"auto_detect_interface": True, "final": final}
    if rules:
        route["rules"] = rules

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
class SingBoxTun:
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
            _pid_file().write_text(str(self._proc.pid), encoding="utf-8")
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

    def stop(self) -> None:
        if self._proc is None:
            return
        if self._proc.poll() is None:
            self.on_log("[tun] останавливаю sing-box (маршруты вернутся сами)…")
            try:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=7)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
            except Exception as e:  # noqa: BLE001
                self.on_log(f"[tun] ошибка остановки: {e}")
        self._proc = None
        _pid_file().unlink(missing_ok=True)
        self.on_state(False)
