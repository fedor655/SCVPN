"""Парсер ссылок и подписок.

Поддерживает ссылки:
  vless://, vmess://, trojan://, ss:// (shadowsocks)
и подписки — это URL, который возвращает либо текст со списком таких ссылок
(по одной на строку), либо тот же текст в base64.

Никакой обфускации: каждая функция делает ровно то, что написано в её имени.
"""
from __future__ import annotations

import base64
import json
from urllib.parse import parse_qs, unquote, urlparse

import requests

from .models import Server

# Многие панели (3x-ui, Marzban, Remnawave) отдают список ссылок в base64,
# ориентируясь на User-Agent известного клиента. Используем распространённый,
# чтобы подписка отдавала именно список vless://-ссылок, а не clash-конфиг.
# Значение можно поменять в настройках — никакого скрытого смысла тут нет.
DEFAULT_USER_AGENT = "v2rayNG/1.9.5"


def fetch_subscription(url: str, user_agent: str = DEFAULT_USER_AGENT, timeout: int = 30) -> list["Server"]:
    """Скачать подписку по URL и вернуть список серверов."""
    r = requests.get(url, headers={"User-Agent": user_agent}, timeout=timeout)
    r.raise_for_status()
    return parse_subscription_text(r.text)


# ----------------------------------------------------------------------
# Вспомогательное: устойчивый base64 (с возможным отсутствием паддинга)
# ----------------------------------------------------------------------
def _b64decode(data: str) -> bytes:
    data = data.strip().replace("\n", "").replace("\r", "")
    # url-safe и обычный алфавит
    data = data.replace("-", "+").replace("_", "/")
    pad = (-len(data)) % 4
    data += "=" * pad
    return base64.b64decode(data)


def _b64decode_text(data: str) -> str:
    return _b64decode(data).decode("utf-8", errors="replace")


# ----------------------------------------------------------------------
# Парсинг отдельных ссылок
# ----------------------------------------------------------------------
def parse_link(link: str) -> Server | None:
    """Разобрать одну ссылку в Server. Вернёт None, если формат не распознан."""
    link = link.strip()
    if not link:
        return None
    try:
        if link.startswith("vless://"):
            return _parse_vless(link)
        if link.startswith("vmess://"):
            return _parse_vmess(link)
        if link.startswith("trojan://"):
            return _parse_trojan(link)
        if link.startswith("ss://"):
            return _parse_ss(link)
    except Exception as e:  # noqa: BLE001 — не роняем парсинг всей подписки из-за одной кривой ссылки
        print(f"[subscription] не смог разобрать ссылку: {e}: {link[:60]}...")
    return None


def _get1(qs: dict, key: str, default: str = "") -> str:
    v = qs.get(key)
    return v[0] if v else default


def _parse_vless(link: str) -> Server:
    # vless://uuid@host:port?params#name
    u = urlparse(link)
    qs = parse_qs(u.query)
    s = Server(protocol="vless")
    s.uuid = unquote(u.username or "")
    s.address = u.hostname or ""
    s.port = u.port or 443
    s.name = unquote(u.fragment) if u.fragment else ""
    s.network = _get1(qs, "type", "tcp")
    s.security = _get1(qs, "security", "none")
    s.flow = _get1(qs, "flow", "")
    s.sni = _get1(qs, "sni") or _get1(qs, "peer")
    s.fingerprint = _get1(qs, "fp")
    s.alpn = _get1(qs, "alpn")
    s.public_key = _get1(qs, "pbk")
    s.short_id = _get1(qs, "sid")
    s.spider_x = _get1(qs, "spx", "/")
    s.ws_path = unquote(_get1(qs, "path", "/"))
    s.ws_host = _get1(qs, "host")
    s.grpc_service = _get1(qs, "serviceName")
    s.allow_insecure = _get1(qs, "allowInsecure") in ("1", "true")
    s.extra = {k: v[0] for k, v in qs.items()}
    return s


def _parse_vmess(link: str) -> Server:
    # vmess://base64(json)
    raw = link[len("vmess://"):]
    cfg = json.loads(_b64decode_text(raw))
    s = Server(protocol="vmess")
    s.name = cfg.get("ps", "")
    s.address = cfg.get("add", "")
    s.port = int(cfg.get("port", 443) or 443)
    s.uuid = cfg.get("id", "")
    s.alter_id = int(cfg.get("aid", 0) or 0)
    s.network = cfg.get("net", "tcp")
    s.security = cfg.get("tls", "") or "none"
    if s.security == "":
        s.security = "none"
    s.sni = cfg.get("sni", "") or cfg.get("host", "")
    s.fingerprint = cfg.get("fp", "")
    s.alpn = cfg.get("alpn", "")
    s.ws_path = cfg.get("path", "/") or "/"
    s.ws_host = cfg.get("host", "")
    s.grpc_service = cfg.get("path", "") if s.network == "grpc" else ""
    s.extra = cfg
    return s


def _parse_trojan(link: str) -> Server:
    # trojan://password@host:port?params#name
    u = urlparse(link)
    qs = parse_qs(u.query)
    s = Server(protocol="trojan")
    s.password = unquote(u.username or "")
    s.address = u.hostname or ""
    s.port = u.port or 443
    s.name = unquote(u.fragment) if u.fragment else ""
    s.network = _get1(qs, "type", "tcp")
    s.security = _get1(qs, "security", "tls")
    s.sni = _get1(qs, "sni") or _get1(qs, "peer")
    s.fingerprint = _get1(qs, "fp")
    s.alpn = _get1(qs, "alpn")
    s.ws_path = unquote(_get1(qs, "path", "/"))
    s.ws_host = _get1(qs, "host")
    s.grpc_service = _get1(qs, "serviceName")
    s.allow_insecure = _get1(qs, "allowInsecure") in ("1", "true")
    s.extra = {k: v[0] for k, v in qs.items()}
    return s


def _parse_ss(link: str) -> Server:
    # Возможные формы:
    #   ss://base64(method:password)@host:port#name
    #   ss://base64(method:password@host:port)#name
    s = Server(protocol="shadowsocks")
    body = link[len("ss://"):]
    if "#" in body:
        body, frag = body.split("#", 1)
        s.name = unquote(frag)
    if "@" in body:
        userinfo, hostpart = body.rsplit("@", 1)
        # userinfo может быть base64 или открытым method:password
        try:
            method_pass = _b64decode_text(userinfo)
        except Exception:  # noqa: BLE001
            method_pass = unquote(userinfo)
        host, _, port = hostpart.partition(":")
    else:
        decoded = _b64decode_text(body)
        method_pass, _, hostpart = decoded.partition("@")
        host, _, port = hostpart.partition(":")
    s.method, _, s.password = method_pass.partition(":")
    s.address = host
    s.port = int(port or 8388)
    return s


# ----------------------------------------------------------------------
# Парсинг подписки целиком (текст или base64-текст)
# ----------------------------------------------------------------------
def parse_subscription_text(text: str) -> list[Server]:
    """Разобрать содержимое подписки в список серверов.

    Подписка часто приходит как base64 от списка ссылок. Пробуем оба варианта.
    """
    text = text.strip()
    candidates: list[str] = []

    # 1) как есть (вдруг это уже список ссылок)
    candidates.append(text)
    # 2) как base64 целиком
    try:
        candidates.append(_b64decode_text(text))
    except Exception:  # noqa: BLE001
        pass

    best: list[Server] = []
    for cand in candidates:
        servers: list[Server] = []
        for line in cand.splitlines():
            sv = parse_link(line)
            if sv:
                servers.append(sv)
        if len(servers) > len(best):
            best = servers
    return best
