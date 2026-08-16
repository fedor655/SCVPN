"""Автоподбор рабочего TLS-отпечатка (fingerprint) для Reality/TLS.

Зачем: в свежих сборках Xray отпечаток chrome шлёт пост-квантовую кривую
(X25519MLKEM768), которую часть серверов не понимает — соединение виснет.
А fp=randomized выбирает отпечаток случайно, поэтому коннект нестабильный.

Чтобы «просто работало», при подключении мы по-быстрому проверяем несколько
отпечатков на реальном сервере и берём первый рабочий. Проверка — это короткий
HTTPS-запрос через временный локальный прокси (ходит только на api.ipify.org).
"""
from __future__ import annotations

import copy
import time
from typing import Callable, Optional

import requests

from core_runner import XrayRunner, find_free_port
from models import Server
from xray_config import build_config

PROBE_URL = "https://api.ipify.org"
# Куда ходит замер пинга. Не PROBE_URL: 204-й ответ пустой, и в измеренное
# время не попадает ни тело, ни его разбор. Тот же адрес у Android — числа на
# двух платформах сравнимы.
PING_URL = "https://www.gstatic.com/generate_204"
# Сколько отпечатков перебирать при замере (при подключении перебор полный).
PING_FP_TRIES = 3
# Порядок проверки: сперва без пост-квантовых кривых (самые совместимые).
FALLBACK_FPS = ["firefox", "chrome", "safari", "edge", "ios", "randomized"]


def candidate_fingerprints(server: Server, override: str) -> list[str]:
    """Список отпечатков для проверки в порядке предпочтения."""
    if override and override not in ("auto", ""):
        return [override]  # пользователь выбрал конкретный — без подбора
    cands: list[str] = []
    fp = (server.fingerprint or "").lower()
    if fp and fp not in ("randomized", "random"):
        cands.append(fp)  # сначала то, что указано в подписке (если конкретное)
    for f in FALLBACK_FPS:
        if f not in cands:
            cands.append(f)
    return cands


def _probe(server: Server, fp: str, route_mode: str, block_ads: bool, timeout: float) -> bool:
    """Запустить временное ядро с данным отпечатком и проверить выход в сеть."""
    s = copy.deepcopy(server)
    s.fingerprint = fp
    return xray_delay(s, route_mode=route_mode, block_ads=block_ads, timeout=timeout) is not None


def ping_delay(server: Server, route_mode: str = "global", block_ads: bool = False,
               timeout: float = 6.0, port_base: int = 20000) -> int | None:
    """Задержка до сервера с перебором отпечатков — то, что видно в колонке пинга.

    Отдельно от xray_delay, потому что у панелей сплошь и рядом стоит
    fingerprint=randomized, а это значит «панель не знает», а не «сервер
    просит случайный». Проба одним таким отпечатком проваливается, и живой
    сервер получает «нет ответа».

    Отпечатков перебирается меньше, чем при подключении: там перебор идёт один
    раз ради самого соединения, а здесь — по каждому серверу списка.
    """
    cands = candidate_fingerprints(server, "auto")[:PING_FP_TRIES]
    if server.security not in ("reality", "tls") or len(cands) <= 1:
        return xray_delay(server, route_mode=route_mode, block_ads=block_ads,
                          timeout=timeout, port_base=port_base, url=PING_URL)
    for fp in cands:
        probe = copy.deepcopy(server)
        probe.fingerprint = fp
        ms = xray_delay(probe, route_mode=route_mode, block_ads=block_ads,
                        timeout=timeout, port_base=port_base, url=PING_URL)
        if ms is not None:
            return ms
    return None


def xray_delay(server: Server, route_mode: str = "global", block_ads: bool = False,
               timeout: float = 6.0, port_base: int = 20000,
               url: str = PROBE_URL) -> int | None:
    """Задержка запроса **через сам сервер**, мс, или None.

    Отличие от tcp_ping принципиальное. Тот меряет время установки TCP-
    соединения, то есть отвечает на вопрос «порт открыт», а не «сервер
    работает»: мёртвый VLESS на живом 443 показывался честными 42 мс.
    Здесь поднимается временное ядро с конфигом этого сервера, и через него
    делается настоящий запрос — с рукопожатием протокола, TLS и всем, из-за
    чего сервер и может не работать.

    Плата известна: на каждый сервер уходит запуск xray и примерно полторы
    секунды на подъём портов.
    """
    # port_base разводит одновременные пробы по разным диапазонам: без него
    # две пробы выбирают один и тот же свободный порт — find_free_port
    # закрывает сокет сразу после проверки.
    sp = find_free_port(port_base)
    hp = find_free_port(max(port_base + 1, sp + 1))
    cfg = build_config(server, socks_port=sp, http_port=hp, route_mode=route_mode,
                       block_ads=block_ads, log_level="error")
    runner = XrayRunner(on_log=lambda x: None, on_state=lambda x: None)
    runner.start(cfg)
    try:
        time.sleep(1.3)  # дать ядру поднять порты
        proxies = {"http": f"http://127.0.0.1:{hp}", "https": f"http://127.0.0.1:{hp}"}
        # Время считаем вокруг запроса, а не вокруг всей пробы: подъём ядра —
        # плата за честность, к задержке до сервера отношения не имеет.
        started = time.monotonic()
        r = requests.get(url, timeout=timeout, proxies=proxies)
        if not r.ok:
            return None
        return int((time.monotonic() - started) * 1000)
    except Exception:
        return None
    finally:
        runner.stop()
        time.sleep(0.3)


def find_working_fingerprint(
    server: Server,
    override: str = "auto",
    route_mode: str = "global",
    block_ads: bool = False,
    log: Optional[Callable[[str], None]] = None,
    per_probe_timeout: float = 6.0,
) -> str:
    """Вернуть первый рабочий отпечаток. Если ни один не прошёл — первый кандидат."""
    say = log or (lambda s: None)
    cands = candidate_fingerprints(server, override)
    if len(cands) == 1:
        return cands[0]  # конкретный выбор пользователя — не проверяем
    say("[*] Подбираю рабочий TLS-отпечаток…")
    for fp in cands:
        if _probe(server, fp, route_mode, block_ads, per_probe_timeout):
            say(f"[+] Рабочий отпечаток: {fp}")
            return fp
        say(f"    {fp} — не подошёл")
    say("[!] Ни один отпечаток не прошёл проверку, пробую первый.")
    return cands[0]
