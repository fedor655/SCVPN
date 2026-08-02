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
def build_singbox_config(socks_port: int, exclude_ips: list[str], *, log_level: str = "warn") -> dict:
    excludes = [f"{ip}/32" for ip in exclude_ips]
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
        "route": {
            "auto_detect_interface": True,
            "final": "to-xray",
        },
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

    def start(self, server: Server, socks_port: int) -> None:
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

        cfg = build_singbox_config(socks_port, ips)
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
        self.on_state(False)
