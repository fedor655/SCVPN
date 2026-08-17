"""Парсер ссылок и подписок.

Поддерживает ссылки:
  vless://, vmess://, trojan://, ss:// (shadowsocks),
  wireguard:// и awg:// (WireGuard / AmneziaWG)
и подписки — это URL, который возвращает либо текст со списком таких ссылок
(по одной на строку), либо тот же текст в base64.

Отдельно от ссылок разбирается многострочный .conf формата wg-quick —
parse_wg_conf(). Это тот же текст, который лежит в QR-коде у панелей Amnezia,
и разбирать его надо до разбиения на строки.

Никакой обфускации: каждая функция делает ровно то, что написано в её имени.
"""
from __future__ import annotations

import base64
import json
from urllib.parse import parse_qs, unquote, urlparse

import requests

from native.hwid import device_headers
from models import Server
from subinfo import SubscriptionInfo

# Многие панели (3x-ui, Marzban, Remnawave) отдают список ссылок в base64,
# ориентируясь на User-Agent известного клиента. Используем распространённый,
# чтобы подписка отдавала именно список vless://-ссылок, а не clash-конфиг.
# Значение можно поменять в настройках — никакого скрытого смысла тут нет.
DEFAULT_USER_AGENT = "v2rayNG/1.9.5"

# Параметры обфускации AmneziaWG в именах UAPI и в том же порядке, что в
# awg/conf.go, — там же объяснено, почему список берётся как есть, а не
# разбирается поимённо. Порядок фиксирован, чтобы один и тот же конфиг всегда
# давал одну и ту же строку Server.awg, какой бы стороной он ни пришёл.
AWG_PARAMS = (
    "jc", "jmin", "jmax",
    "s1", "s2", "s3", "s4",
    "h1", "h2", "h3", "h4",
    "i1", "i2", "i3", "i4", "i5",
)

# Порт WireGuard по умолчанию — если в ссылке или Endpoint его не указали.
DEFAULT_WG_PORT = 51820


class SubscriptionError(Exception):
    """Подписка ответила, но серверов не отдала — и объяснила почему."""


def fetch_subscription_full(
    url: str, user_agent: str = DEFAULT_USER_AGENT, timeout: int = 30
) -> tuple[list["Server"], SubscriptionInfo]:
    """Серверы + служебные сведения подписки (срок, трафик, автообновление).

    Кроме User-Agent шлём идентификатор устройства: панели с привязкой к
    устройствам без него отдают заглушку вместо серверов (см. hwid.py).
    """
    headers = {"User-Agent": user_agent}
    headers.update(device_headers())

    try:
        r = requests.get(url, headers=headers, timeout=timeout)
    except (requests.ConnectionError, requests.Timeout) as e:
        # Частый случай: домен провайдера подписки заблокирован, а сами его
        # VPN-серверы доступны. Получается замкнутый круг — подписку не
        # обновить без VPN, а VPN не включить без серверов. Обычная ошибка
        # сети об этом не говорит, поэтому объясняем прямо.
        raise SubscriptionError(
            f"Не удалось связаться с сайтом подписки ({urlparse(url).hostname}).\n\n"
            "Чаще всего это значит, что домен провайдера заблокирован, — сами "
            "VPN-серверы при этом обычно работают.\n\n"
            "Что делать: подключись к любому уже добавленному серверу и нажми "
            "«Обновить» ещё раз. Если серверов нет ни одного — добавь один "
            "ссылкой vless:// или отсканируй QR."
        ) from e
    if not r.ok:
        # HTTPError от requests пользователю ничего не говорит, а показать его
        # надо: 401/403 у панели означают «ссылка протухла», а не поломку
        # клиента. Swift-версия оборачивает так же — тексты обязаны совпадать.
        raise SubscriptionError(f"Подписка ответила кодом {r.status_code}.")

    servers = parse_subscription_text(r.text)
    _raise_if_panel_stub(servers, r.headers)
    return servers, SubscriptionInfo.from_headers(r.headers)


def _raise_if_panel_stub(servers: list["Server"], headers) -> None:
    """Отличить заглушку панели от настоящего списка серверов.

    Панель не возвращает ошибку HTTP: она отдаёт один фиктивный
    `vless://0000...@0.0.0.0:1`, у которого в имени написана причина. Без этой
    проверки такая строка молча попадала бы в список серверов — ровно это и
    выглядело как «сервер App not supported», к которому нельзя подключиться.
    """
    stub = [s for s in servers if s.address in ("0.0.0.0", "127.0.0.1", "") or s.port <= 1]
    if not servers or len(stub) != len(servers):
        return

    reason = stub[0].name.strip() if stub[0].name else ""
    lower = {k.lower(): str(v).lower() for k, v in headers.items()}

    if lower.get("x-hwid-max-devices-reached") == "true":
        raise SubscriptionError(
            f"Достигнут лимит устройств на аккаунте ({reason or 'limit of devices reached'}).\n\n"
            "Освободи слот в личном кабинете подписки или у поддержки провайдера, "
            "затем нажми «Обновить» ещё раз."
        )
    if lower.get("x-hwid-not-supported") == "true":
        raise SubscriptionError(
            "Панель не приняла идентификатор устройства.\n\n"
            "Похоже, у провайдера включена привязка к устройствам, а клиент "
            "представился неверно. Сообщи об этом — это чинится в SCVPN."
        )
    raise SubscriptionError(
        f"Подписка вернула не список серверов, а сообщение: «{reason or 'без пояснения'}»."
    )


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


def _b64_std(data: str) -> str:
    """Ключ WireGuard в обычный base64 — тот, что ждёт scvpn-awg.

    В ссылке алфавит url-safe, в .conf обычный; на диске по контракту лежит
    обычный. Заодно это единственная проверка ключа на нашей стороне: обрезанный
    ключ UAPI принял бы молча, и туннель просто не поднялся бы без объяснений.
    """
    if not data:
        return ""
    raw = _b64decode(data)
    if len(raw) != 32:
        raise ValueError(f"ключ длиной {len(raw)} байт вместо 32")
    return base64.b64encode(raw).decode("ascii")


def _int(value: str) -> int:
    """Число из конфига; 0 — если там мусор или пусто (0 значит «по умолчанию»)."""
    try:
        return int(value.strip())
    except ValueError:
        return 0


def _csv(value: str) -> str:
    """Список через запятую без пробелов: "a/32, b/128" -> "a/32,b/128"."""
    return ",".join(p.strip() for p in value.split(",") if p.strip())


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
        if link.startswith(("wireguard://", "awg://")):
            return _parse_wireguard(link)
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


def _parse_wireguard(link: str) -> Server:
    # wireguard://<base64 privkey>@host:port?publickey=..&address=..&jc=..#имя
    #
    # Однострочная форма нужна только подпискам: панель отдаёт список ссылок по
    # одной на строку, и многострочный .conf туда не помещается.
    u = urlparse(link)
    # Ключи параметров приводим к нижнему регистру: панели пишут и publickey,
    # и publicKey, а значение от этого не меняется.
    qs = {k.lower(): v for k, v in parse_qs(u.query).items()}
    s = Server(protocol="wireguard")
    s.private_key = _b64_std(unquote(u.username or ""))
    s.public_key = _b64_std(_get1(qs, "publickey"))
    s.preshared_key = _b64_std(_get1(qs, "presharedkey"))
    s.address = u.hostname or ""
    s.port = u.port or DEFAULT_WG_PORT
    s.name = unquote(u.fragment) if u.fragment else ""
    s.local_address = _csv(_get1(qs, "address"))
    s.allowed_ips = _csv(_get1(qs, "allowedips")) or "0.0.0.0/0,::/0"
    s.wg_dns = _csv(_get1(qs, "dns"))
    s.mtu = _int(_get1(qs, "mtu"))
    s.keepalive = _int(_get1(qs, "keepalive"))
    s.awg = ",".join(f"{n}={_get1(qs, n)}" for n in AWG_PARAMS if _get1(qs, n))
    s.extra = {k: v[0] for k, v in qs.items()}
    return s


# ----------------------------------------------------------------------
# Многострочный .conf (wg-quick + AmneziaWG)
# ----------------------------------------------------------------------
def parse_wg_conf(text: str) -> Server | None:
    """Разобрать .conf в Server. None — это не .conf.

    Два разных исхода нужны вызывающему. None значит «секции [Interface] тут
    нет», и строку ещё имеет смысл попробовать как ссылку или URL подписки.
    ValueError значит «это .conf, но в нём не хватает обязательного» — тогда
    человеку надо сказать, чего именно, а не «не распознано».

    Разбор повторяет awg/conf.go: тот же файл читает сам бинарник, здесь он
    нужен только затем, чтобы разложить поля по профилю.
    """
    lines = text.splitlines()
    if not any(l.strip().lower() == "[interface]" for l in lines):
        return None

    s = Server(protocol="wireguard", allowed_ips="")
    awg: dict[str, str] = {}
    section = ""
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line.startswith(("#", ";")):
            # Имя панели кладут комментарием — больше нам из комментариев
            # ничего не нужно.
            name = _conf_name(line)
            if name and not s.name:
                s.name = name
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        raw_key, sep, raw_value = line.partition("=")
        if not sep:
            continue
        key, value = raw_key.strip().lower(), raw_value.strip()
        if not value:
            continue
        if section == "interface":
            if key == "privatekey":
                s.private_key = _b64_std(value)
            elif key == "address":
                s.local_address = _csv(value)
            elif key == "dns":
                s.wg_dns = _csv(value)
            elif key == "mtu":
                s.mtu = _int(value)
            elif key in AWG_PARAMS:
                awg[key] = value
            # ListenPort, Table, PreUp/PostUp к юзерспейс-стеку отношения не
            # имеют — молча пропускаем, файл от этого не «кривой».
        elif section == "peer":
            if key == "publickey":
                s.public_key = _b64_std(value)
            elif key == "presharedkey":
                s.preshared_key = _b64_std(value)
            elif key == "endpoint":
                s.address, s.port = _endpoint(value)
            elif key == "allowedips":
                s.allowed_ips = _csv(value)
            elif key == "persistentkeepalive" and value.lower() != "off":
                s.keepalive = _int(value)

    s.awg = ",".join(f"{n}={awg[n]}" for n in AWG_PARAMS if n in awg)
    # Пустой AllowedIPs у wg-quick значит «ничего не маршрутизировать», но в
    # клиентском конфиге это всегда опечатка: туннель поднимется и не пропустит
    # ни байта. Ставим полный — так же поступает awg/conf.go.
    if not s.allowed_ips:
        s.allowed_ips = "0.0.0.0/0,::/0"

    missing = [what for what, got in (
        ("PrivateKey", s.private_key),
        ("PublicKey в [Peer]", s.public_key),
        ("Endpoint в [Peer]", s.address),
        ("Address в [Interface]", s.local_address),
    ) if not got]
    if missing:
        raise ValueError("В конфиге WireGuard нет: " + ", ".join(missing))
    return s


def _conf_name(line: str) -> str:
    """Имя сервера из комментария вида `# Name = Амстердам`."""
    key, sep, value = line.lstrip("#;").strip().partition("=")
    return value.strip() if sep and key.strip().lower() == "name" else ""


def _endpoint(value: str) -> tuple[str, int]:
    """Endpoint пира в (хост, порт). IPv6 приходит в скобках — снимаем их."""
    host, sep, port = value.rpartition(":")
    if not sep:
        return value.strip("[]"), DEFAULT_WG_PORT
    return host.strip().strip("[]"), _int(port) or DEFAULT_WG_PORT


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
