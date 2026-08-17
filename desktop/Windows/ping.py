"""Измерение задержки до сервера — обычный TCP-connect к host:port.

Это не ICMP-пинг, а время установки TCP-соединения (как happ-tcping):
показывает, насколько быстро отвечает порт сервера. Для VPN это полезнее,
чем ICMP, потому что меряет именно доступность нужного порта.

Годится не всем: у WireGuard порт сервера — UDP, и коннекта на нём нет вовсе,
так что для него эта мера не «менее точная», а невозможная. Решает это
вызывающий (см. ui/workers.py) — здесь про протоколы ничего не знают.
"""
from __future__ import annotations

import socket
import time


def tcp_ping(host: str, port: int, timeout: float = 3.0) -> int | None:
    """Вернуть задержку в миллисекундах или None, если порт недоступен."""
    try:
        # Резолвим имя и пробуем подключиться к первому адресу.
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        return None

    for family, socktype, proto, _canon, sockaddr in infos:
        s = socket.socket(family, socktype, proto)
        s.settimeout(timeout)
        try:
            start = time.perf_counter()
            s.connect(sockaddr)
            elapsed_ms = int((time.perf_counter() - start) * 1000)
            return elapsed_ms
        except (socket.timeout, OSError):
            continue
        finally:
            s.close()
    return None
