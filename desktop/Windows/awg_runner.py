"""Запуск и остановка scvpn-awg.exe — AmneziaWG в виде локального SOCKS5.

Устроено так же, как core_runner.XrayRunner: конфиг пишется в файл рядом с
конфигом Xray, процесс запускается без окна консоли, вывод читается отдельным
потоком и уходит в on_log, PID кладётся на диск (см. tun.cleanup_stray).

Отличие одно, и оно важное: start() возвращает управление не сразу, а после
строки готовности от самого бинарника. Xray поднимается следом и сразу
подключается к этому порту — стартуй мы их одновременно, первые соединения
уходили бы в закрытый порт, и «подключено» означало бы «ничего не грузится».

Модуль намеренно не зависит от Qt — его легко проверить отдельно.
"""
from __future__ import annotations

import subprocess
import threading
from collections import deque
from typing import Callable, Optional

from models import Server
from native import paths

# Строка, которую scvpn-awg печатает, когда туннель поднят и порт слушается.
# Это контракт с awg/main.go, а не украшение: менять только вместе с ним.
READY_MARK = "[awg] готов:"

# Сколько ждать готовности. Рукопожатие WireGuard — это один пакет туда и
# обратно, но на мёртвом сервере ответа не будет вовсе, и ждать вечно нельзя.
START_TIMEOUT = 20.0


def build_conf(server: Server) -> str:
    """Собрать .conf формата wg-quick из полей сервера.

    Обратная операция к subscription.parse_wg_conf: на диск для бинарника
    кладётся именно .conf, потому что его же формат читает и разбирает
    awg/conf.go — второго формата обмена заводить незачем.
    """
    # IPv6-адрес сервера обязан быть в скобках: без них разбор Endpoint не
    # отличит двоеточия адреса от двоеточия перед портом.
    host = f"[{server.address}]" if ":" in server.address else server.address

    lines = ["[Interface]", f"PrivateKey = {server.private_key}"]
    if server.local_address:
        lines.append(f"Address = {server.local_address}")
    if server.wg_dns:
        lines.append(f"DNS = {server.wg_dns}")
    if server.mtu:
        lines.append(f"MTU = {server.mtu}")
    for part in server.awg.split(","):
        name, sep, value = part.partition("=")
        if sep:
            lines.append(f"{name.strip()} = {value.strip()}")

    lines += ["", "[Peer]", f"PublicKey = {server.public_key}"]
    if server.preshared_key:
        lines.append(f"PresharedKey = {server.preshared_key}")
    lines.append(f"Endpoint = {host}:{server.port}")
    lines.append(f"AllowedIPs = {server.allowed_ips or '0.0.0.0/0,::/0'}")
    if server.keepalive:
        lines.append(f"PersistentKeepalive = {server.keepalive}")
    return "\n".join(lines) + "\n"


class AwgRunner:
    def __init__(
        self,
        on_log: Optional[Callable[[str], None]] = None,
        on_state: Optional[Callable[[bool], None]] = None,
    ) -> None:
        self._proc: Optional[subprocess.Popen] = None
        self._reader: Optional[threading.Thread] = None
        self._ready = threading.Event()
        # Последние строки вывода — чтобы в исключении назвать настоящую
        # причину («нет PrivateKey», «не занять порт»), а не «не запустился».
        self._tail: deque[str] = deque(maxlen=10)
        self.on_log = on_log or (lambda s: None)
        self.on_state = on_state or (lambda running: None)

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(self, server: Server, socks_port: int, timeout: float = START_TIMEOUT) -> None:
        """Поднять туннель и вернуться, когда он готов принимать соединения.

        Бросает исключение, если бинарника нет, если он умер на старте или если
        строка готовности так и не пришла.
        """
        if self.running:
            self.stop()

        exe = paths.awg_exe()
        if not exe.exists():
            raise FileNotFoundError(
                f"Не найден AmneziaWG: {exe}\n"
                "Собери его из папки awg/ этого репозитория\n"
                "(go build -o bin/scvpn-awg.exe ./awg) и положи рядом с xray.exe."
            )

        paths.ensure_dirs()
        cfg_path = paths.AWG_CONFIG_FILE
        cfg_path.write_text(build_conf(server), encoding="utf-8")

        self._ready.clear()
        self._tail.clear()

        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._proc = subprocess.Popen(
            [str(exe), "-config", str(cfg_path), "-socks", f"127.0.0.1:{socks_port}"],
            cwd=str(paths.BIN_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=creationflags,
        )
        # PID на диск — как у xray и sing-box: если приложение закроется
        # аварийно, туннель останется жить сам по себе, и следующий запуск
        # должен его найти и снять (см. tun.cleanup_stray).
        try:
            (paths.DATA_DIR / "awg.pid").write_text(str(self._proc.pid), encoding="utf-8")
        except OSError:
            pass

        self.on_log(f"[awg] запуск: {exe.name} -socks 127.0.0.1:{socks_port}")
        self._reader = threading.Thread(target=self._read_output, daemon=True)
        self._reader.start()

        # Ждать полный таймаут после смерти процесса незачем: поток чтения
        # будит нас тем же событием, когда закрывается вывод.
        if not self._ready.wait(timeout):
            self.stop()
            raise RuntimeError(
                f"AmneziaWG не поднялся за {timeout:.0f} с. {self._why()}"
            )
        if not self.running:
            code = self._proc.poll() if self._proc else None
            self.stop()
            raise RuntimeError(f"AmneziaWG завершился (код {code}). {self._why()}")

        self.on_state(True)

    def _why(self) -> str:
        """Последнее, что сказал сам бинарник, — он объясняет лучше нас."""
        return self._tail[-1] if self._tail else "Вывода от него не было."

    def _read_output(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        for line in self._proc.stdout:
            line = line.rstrip("\n")
            if not line:
                continue
            self._tail.append(line)
            self.on_log(line)
            if READY_MARK in line:
                self._ready.set()
        code = self._proc.poll()
        self.on_log(f"[awg] процесс завершился (код {code})")
        self._ready.set()
        self.on_state(False)

    def stop(self) -> None:
        if self._proc is None:
            return
        if self._proc.poll() is None:
            self.on_log("[awg] остановка туннеля…")
            try:
                # Сперва terminate: там, где он приходит сигналом, бинарник
                # успевает погасить туннель сам. На Windows это сразу
                # TerminateProcess, и сессию на сервере доедает её же таймаут —
                # держать ради этого процесс дольше не за чем.
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
            except Exception as e:  # noqa: BLE001
                self.on_log(f"[awg] ошибка остановки: {e}")
        self._proc = None
        (paths.DATA_DIR / "awg.pid").unlink(missing_ok=True)
        # Конфиг уносим вместе с процессом: в нём приватный ключ туннеля, и
        # между сеансами он не нужен никому. Конфиг Xray, наоборот, остаётся —
        # его показывают, чтобы было видно, что ушло ядру.
        paths.AWG_CONFIG_FILE.unlink(missing_ok=True)
        self.on_state(False)
