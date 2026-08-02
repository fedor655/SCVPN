"""Сборка полного конфига Xray из выбранного сервера.

Конфиг состоит из:
  - log         — куда писать логи ядра;
  - inbounds    — локальные «входы»: SOCKS и HTTP на 127.0.0.1, в них ходит
                  системный прокси / TUN-движок;
  - outbounds   — «выходы»: наш сервер (proxy), прямой выход (direct), чёрная
                  дыра (block);
  - routing     — правила: что слать в proxy, что напрямую, что блокировать;
  - dns         — какие DNS использовать.

Готовый словарь сериализуется в JSON и отдаётся ядру xray.exe.
"""
from __future__ import annotations

from typing import Any

from .models import Server

# Локальные порты по умолчанию (только на 127.0.0.1, наружу не торчат).
DEFAULT_SOCKS_PORT = 10808
DEFAULT_HTTP_PORT = 10809

# Режимы маршрутизации.
ROUTE_GLOBAL = "global"        # весь трафик через VPN (кроме локалки)
ROUTE_BYPASS_RU = "bypass_ru"  # российские сайты и IP — напрямую, остальное в VPN


def build_config(
    server: Server,
    *,
    socks_port: int = DEFAULT_SOCKS_PORT,
    http_port: int = DEFAULT_HTTP_PORT,
    route_mode: str = ROUTE_GLOBAL,
    block_ads: bool = False,
    log_path: str | None = None,
    log_level: str = "warning",
) -> dict[str, Any]:
    cfg: dict[str, Any] = {
        "log": {"loglevel": log_level},
        "inbounds": _inbounds(socks_port, http_port),
        "outbounds": [
            server.to_outbound("proxy"),
            {"tag": "direct", "protocol": "freedom", "settings": {}},
            {"tag": "block", "protocol": "blackhole", "settings": {}},
        ],
        "routing": _routing(route_mode, block_ads),
        "dns": _dns(route_mode),
    }
    if log_path:
        cfg["log"]["access"] = log_path
        cfg["log"]["error"] = log_path
    return cfg


def _inbounds(socks_port: int, http_port: int) -> list[dict[str, Any]]:
    sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic"]}
    return [
        {
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {"udp": True, "auth": "noauth"},
            "sniffing": sniffing,
        },
        {
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": http_port,
            "protocol": "http",
            "settings": {},
            "sniffing": sniffing,
        },
    ]


def _routing(route_mode: str, block_ads: bool) -> dict[str, Any]:
    rules: list[dict[str, Any]] = []

    # 1) реклама в чёрную дыру (по желанию)
    if block_ads:
        rules.append({
            "type": "field",
            "outboundTag": "block",
            "domain": ["geosite:category-ads-all"],
        })

    # 2) локальная сеть и приватные адреса — всегда напрямую
    rules.append({
        "type": "field",
        "outboundTag": "direct",
        "ip": ["geoip:private"],
    })
    rules.append({
        "type": "field",
        "outboundTag": "direct",
        "domain": ["geosite:private"],
    })

    # 3) режим «обход РФ»: российские сайты и IP — напрямую
    if route_mode == ROUTE_BYPASS_RU:
        rules.append({
            "type": "field",
            "outboundTag": "direct",
            "domain": ["geosite:category-ru", "geosite:yandex", "geosite:vk", "geosite:mailru"],
        })
        rules.append({
            "type": "field",
            "outboundTag": "direct",
            "ip": ["geoip:ru"],
        })

    # 4) всё остальное — в VPN. Явное правило не обязательно (default outbound —
    #    первый в списке, т.е. proxy), но добавим для наглядности.
    rules.append({
        "type": "field",
        "outboundTag": "proxy",
        "network": "tcp,udp",
    })

    return {"domainStrategy": "IPIfNonMatch", "rules": rules}


def _dns(route_mode: str) -> dict[str, Any]:
    # DNS через прокси, чтобы провайдер не видел запросы и не было утечки.
    servers: list[Any] = ["https://1.1.1.1/dns-query", "8.8.8.8"]
    if route_mode == ROUTE_BYPASS_RU:
        # российские домены резолвим через российский DNS напрямую
        servers.insert(0, {
            "address": "77.88.8.8",  # Yandex DNS
            "domains": ["geosite:category-ru"],
        })
    return {"servers": servers, "queryStrategy": "UseIP"}
