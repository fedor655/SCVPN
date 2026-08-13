"""Запуск и остановка ядра xray.exe.

Класс XrayRunner:
  - пишет конфиг в файл (data/xray_running.json — можно открыть и посмотреть);
  - запускает xray.exe как дочерний процесс (без чёрного окна консоли);
  - читает его вывод в отдельном потоке и отдаёт строки через колбэк on_log;
  - умеет аккуратно остановить процесс.

Модуль намеренно не зависит от Qt — его легко проверить отдельно.
"""
from __future__ import annotations

import json
import socket
import subprocess
import threading
from pathlib import Path
from typing import Callable, Optional

from native import paths


def find_free_port(preferred: int) -> int:
    """Найти свободный TCP-порт на 127.0.0.1, начиная с preferred.

    Нужно, чтобы не конфликтовать с другими VPN-клиентами (например, Happ
    держит 10808/10809). Если ближайшие заняты — берём первый свободный,
    в крайнем случае любой эфемерный.
    """
    for port in range(preferred, preferred + 100):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class XrayRunner:
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

    def start(self, config: dict) -> None:
        if self.running:
            self.stop()

        exe = paths.xray_exe()
        if not exe.exists():
            raise FileNotFoundError(
                f"Не найдено ядро Xray: {exe}\n"
                "Скачай его кнопкой в приложении или положи xray.exe в папку bin/."
            )

        paths.ensure_dirs()
        cfg_path: Path = paths.XRAY_CONFIG_FILE
        cfg_path.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")

        creationflags = 0
        startupinfo = None
        if hasattr(subprocess, "CREATE_NO_WINDOW"):  # Windows: без окна консоли
            creationflags = subprocess.CREATE_NO_WINDOW

        self._proc = subprocess.Popen(
            [str(exe), "run", "-c", str(cfg_path)],
            cwd=str(paths.BIN_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=creationflags,
            startupinfo=startupinfo,
        )
        # PID на диск — если приложение закроется аварийно, ядро останется
        # работать само по себе, и следующий запуск должен его найти и снять
        # (см. tun.cleanup_stray).
        try:
            (paths.DATA_DIR / "xray.pid").write_text(str(self._proc.pid), encoding="utf-8")
        except OSError:
            pass

        self.on_log(f"[core] запуск: {exe.name} run -c {cfg_path.name}")
        self.on_state(True)

        self._reader = threading.Thread(target=self._read_output, daemon=True)
        self._reader.start()

    def _read_output(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        for line in self._proc.stdout:
            line = line.rstrip("\n")
            if line:
                self.on_log(line)
        # поток вывода закрылся — значит процесс завершился
        code = self._proc.poll()
        self.on_log(f"[core] процесс завершился (код {code})")
        self.on_state(False)

    def stop(self) -> None:
        if self._proc is None:
            return
        if self._proc.poll() is None:
            self.on_log("[core] остановка ядра…")
            try:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
            except Exception as e:  # noqa: BLE001
                self.on_log(f"[core] ошибка остановки: {e}")
        self._proc = None
        (paths.DATA_DIR / "xray.pid").unlink(missing_ok=True)
        self.on_state(False)
