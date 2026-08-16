"""Снять эталонные файлы с работающей Python-версии для тестов C#-порта.

Единственный смысл этого скрипта — зафиксировать нынешнее поведение до того,
как Python-версия будет удалена. После удаления сверять C# станет не с чем.

Запуск (годится и macOS — сетевые модули не нужны):
    python3 tools/make_golden.py

Пишет JSON-файлы в ../Windows-cs/SCVPN.Tests/Golden/.

Данные синтетические: UUID, пароли и домены выдуманы, ничего личного в git
не попадает.
"""
from __future__ import annotations

import hashlib
import json
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
OUT = PROJECT.parent / "Windows-cs" / "SCVPN.Tests" / "Golden"

sys.path.insert(0, str(PROJECT))

# subscription.py импортирует requests на уровне модуля, а сам парсер ссылок
# сети не касается. Подставляем заглушку, чтобы скрипт работал где угодно.
if "requests" not in sys.modules:
    fake = types.ModuleType("requests")

    class _NetError(Exception):
        pass

    fake.ConnectionError = _NetError
    fake.Timeout = _NetError
    fake.HTTPError = _NetError
    fake.get = lambda *a, **k: None
    sys.modules["requests"] = fake

import subinfo  # noqa: E402
import subscription  # noqa: E402
from models import Server  # noqa: E402
from native import hwid, paths  # noqa: E402
from native.tun import (  # noqa: E402
    SPLIT_EXCLUDE,
    SPLIT_INCLUDE,
    SPLIT_OFF,
    build_singbox_config,
)
from xray_config import ROUTE_BYPASS_RU, ROUTE_GLOBAL, build_config  # noqa: E402

# Путь до xray попадает в конфиг sing-box и зависит от машины. В эталоне вместо
# него метка: C#-тест подставит свой путь и сравнит так же.
XRAY_PLACEHOLDER = "<XRAY_EXE>"


# ----------------------------------------------------------------------
# Входные данные: по ссылке на каждый разумный случай и на каждый кривой
# ----------------------------------------------------------------------
LINKS = [
    # --- vless ---
    ("vless-reality-vision",
     "vless://11111111-2222-3333-4444-555555555555@ru1.example.com:443"
     "?type=tcp&security=reality&flow=xtls-rprx-vision&sni=www.microsoft.com"
     "&fp=chrome&pbk=PUBKEY123&sid=a1b2&spx=%2F#%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D1%8F%201"),
    ("vless-ws-tls",
     "vless://11111111-2222-3333-4444-555555555555@de.example.com:8443"
     "?type=ws&security=tls&sni=cdn.example.com&host=cdn.example.com"
     "&path=%2Fws%3Fed%3D2048&alpn=h2%2Chttp%2F1.1&fp=firefox#DE-WS"),
    ("vless-grpc-tls",
     "vless://11111111-2222-3333-4444-555555555555@nl.example.com:443"
     "?type=grpc&security=tls&serviceName=grpcSvc&sni=nl.example.com#NL-gRPC"),
    ("vless-plain-tcp",
     "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:80#plain"),
    ("vless-no-port",
     "vless://11111111-2222-3333-4444-555555555555@noport.example.com"
     "?security=reality&pbk=K&sid=&sni=a.com#no-port"),
    ("vless-allow-insecure",
     "vless://11111111-2222-3333-4444-555555555555@insecure.example.com:443"
     "?security=tls&allowInsecure=1&sni=insecure.example.com#insecure"),
    ("vless-peer-instead-of-sni",
     "vless://11111111-2222-3333-4444-555555555555@peer.example.com:443"
     "?security=tls&peer=peer.example.com#peer"),
    ("vless-http-h2",
     "vless://11111111-2222-3333-4444-555555555555@h2.example.com:443"
     "?type=http&security=tls&path=%2Fh2&host=h2.example.com#H2"),
    ("vless-empty-fragment",
     "vless://11111111-2222-3333-4444-555555555555@nofrag.example.com:443?security=tls"),

    # --- vmess (base64 от JSON) ---
    ("vmess-ws-tls",
     "vmess://eyJ2IjoiMiIsInBzIjoiVk1FU1MtV1MiLCJhZGQiOiJ2bS5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMi"
     "LCJpZCI6IjExMTExMTExLTIyMjItMzMzMy00NDQ0LTU1NTU1NTU1NTU1NSIsImFpZCI6IjAiLCJuZXQiOiJ3cyIs"
     "InR5cGUiOiJub25lIiwiaG9zdCI6InZtLmV4YW1wbGUuY29tIiwicGF0aCI6Ii92bWVzcyIsInRscyI6InRscyJ9"),
    ("vmess-tcp-plain",
     "vmess://eyJ2IjoiMiIsInBzIjoiVk1FU1MtVENQIiwiYWRkIjoiMi4zLjQuNSIsInBvcnQiOjEwMDg2LCJpZCI6"
     "IjExMTExMTExLTIyMjItMzMzMy00NDQ0LTU1NTU1NTU1NTU1NSIsImFpZCI6MCwibmV0IjoidGNwIiwidGxzIjoi"
     "In0="),

    # --- trojan ---
    ("trojan-tcp-tls",
     "trojan://p%40ssw0rd@tj.example.com:443?security=tls&sni=tj.example.com&fp=chrome#Trojan"),
    ("trojan-ws",
     "trojan://password@tjws.example.com:2083"
     "?type=ws&security=tls&path=%2Ftj&host=tjws.example.com#Trojan-WS"),
    ("trojan-default-security",
     "trojan://password@tjdef.example.com:443#Trojan-default"),

    # --- shadowsocks ---
    # base64(method:password)@host:port#name
    ("ss-userinfo-base64",
     "ss://YWVzLTI1Ni1nY206c2VjcmV0MTIz@ss.example.com:8388#SS-1"),
    # целиком base64: base64(method:password@host:port)
    ("ss-whole-base64",
     "ss://YWVzLTI1Ni1nY206c2VjcmV0MTIzQHNzMi5leGFtcGxlLmNvbTo4Mzg5#SS-2"),
    # открытый userinfo без base64
    ("ss-plain-userinfo",
     "ss://chacha20-ietf-poly1305:pass%20word@ss3.example.com:9000#SS-3"),
    ("ss-no-port",
     "ss://YWVzLTI1Ni1nY206c2VjcmV0MTIz@ss4.example.com#SS-4"),

    # --- то, что разобрать нельзя ---
    ("bad-scheme", "http://example.com/"),
    ("bad-empty", ""),
    ("bad-garbage", "vless://"),
    ("bad-vmess-not-base64", "vmess://не-base64-вовсе"),
]

SUBSCRIPTION_TEXTS = [
    ("plain-list",
     "vless://11111111-2222-3333-4444-555555555555@a.example.com:443?security=tls#A\n"
     "vless://11111111-2222-3333-4444-555555555555@b.example.com:443?security=tls#B\n"
     "\n"
     "trojan://pw@c.example.com:443#C\n"),
    ("base64-list", None),      # заполняется ниже
    ("with-garbage-lines",
     "# комментарий\n"
     "vless://11111111-2222-3333-4444-555555555555@d.example.com:443#D\n"
     "не ссылка вовсе\n"),
    ("empty", ""),
    ("panel-stub",
     "vless://00000000-0000-0000-0000-000000000000@0.0.0.0:1#App%20not%20supported\n"),
]

HEADER_CASES = [
    ("full", {
        "profile-title": "base64:0J/QvtC00L/QuNGB0LrQsA==",
        "profile-update-interval": "12",
        "subscription-userinfo": "upload=1024; download=2048; total=107374182400; expire=1788405825",
        "content-disposition": 'attachment; filename="user_key-1"',
        "support-url": "https://t.me/support",
        "profile-web-page-url": "https://panel.example.com/",
        "announce": "base64:0J/RgNC40LLQtdGCINC80LjRgA==",
        "x-hwid-max-devices-reached": "false",
    }),
    ("device-limit", {
        "subscription-userinfo": "upload=0; download=0; total=0; expire=0",
        "x-hwid-max-devices-reached": "true",
        "x-hwid-not-supported": "false",
    }),
    ("plain-title", {
        "profile-title": "My Subscription",
        "content-disposition": "attachment; filename=noquotes",
        "subscription-userinfo": "upload=5; download=6",
    }),
    ("float-values", {
        "subscription-userinfo": "upload=1.0; download=2.5; total=3.0; expire=1788405825.0",
    }),
    ("broken-interval", {"profile-update-interval": "не число"}),
    ("empty", {}),
]

HWID_SOURCES = [
    "8f3a6c12-9d4e-4b7a-a1c5-2e9b7f0d6a34",
    "00000000-0000-0000-0000-000000000000",
    "mac-a1b2c3d4e5f6",
    "ЮНИКОД-МАШИНА",
]

BYTES_CASES = [0, -1, 1, 1023, 1024, 1536, 1048576, 1073741824, 107374182400, 1099511627776]
INTERVAL_CASES = [0, -3, 1, 12, 24, 48, 72, 25]


# ----------------------------------------------------------------------
def dump(name: str, data) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"  -> {path.relative_to(OUT.parent.parent.parent)}")


def golden_links() -> None:
    out = []
    for name, link in LINKS:
        s = subscription.parse_link(link)
        out.append({
            "name": name,
            "link": link,
            "server": s.to_dict() if s else None,
            "outbound": s.to_outbound("proxy") if s else None,
        })
    dump("links.json", out)


def golden_subscription_texts() -> None:
    import base64 as _b64

    plain = SUBSCRIPTION_TEXTS[0][1]
    cases = list(SUBSCRIPTION_TEXTS)
    cases[1] = ("base64-list", _b64.b64encode(plain.encode()).decode().rstrip("="))

    out = []
    for name, text in cases:
        servers = subscription.parse_subscription_text(text)
        out.append({
            "name": name,
            "text": text,
            "servers": [s.to_dict() for s in servers],
        })
    dump("subscription_texts.json", out)


def golden_xray_configs() -> None:
    servers = {
        "reality": subscription.parse_link(LINKS[0][1]),
        "ws-tls": subscription.parse_link(LINKS[1][1]),
        "grpc": subscription.parse_link(LINKS[2][1]),
        "vmess": subscription.parse_link(dict(LINKS)["vmess-ws-tls"]),
        "trojan": subscription.parse_link(dict(LINKS)["trojan-tcp-tls"]),
        "ss": subscription.parse_link(dict(LINKS)["ss-userinfo-base64"]),
    }
    options = [
        ("global-plain", dict(route_mode=ROUTE_GLOBAL, block_ads=False)),
        ("global-ads", dict(route_mode=ROUTE_GLOBAL, block_ads=True)),
        ("bypass-ru", dict(route_mode=ROUTE_BYPASS_RU, block_ads=False)),
        ("bypass-ru-ads", dict(route_mode=ROUTE_BYPASS_RU, block_ads=True)),
    ]
    out = []
    for sname, server in servers.items():
        for oname, opts in options:
            cfg = build_config(server, socks_port=10808, http_port=10809,
                               log_level="warning", **opts)
            out.append({
                "name": f"{sname}/{oname}",
                "server": server.to_dict(),
                "socks_port": 10808,
                "http_port": 10809,
                "route_mode": opts["route_mode"],
                "block_ads": opts["block_ads"],
                "log_level": "warning",
                "config": cfg,
            })
    dump("xray_configs.json", out)


def golden_singbox_configs() -> None:
    xray_path = str(paths.xray_exe())
    cases = [
        ("off-no-apps", dict(split_mode=SPLIT_OFF, split_apps=[])),
        ("exclude-two", dict(split_mode=SPLIT_EXCLUDE, split_apps=["Telegram.exe", "chrome.exe"])),
        ("include-two", dict(split_mode=SPLIT_INCLUDE, split_apps=["Telegram.exe", "chrome.exe"])),
        ("include-empty", dict(split_mode=SPLIT_INCLUDE, split_apps=[])),
        ("exclude-blank-names", dict(split_mode=SPLIT_EXCLUDE, split_apps=["  ", "ok.exe"])),
    ]
    out = []
    for name, opts in cases:
        cfg = build_singbox_config(10808, ["93.184.216.34", "1.1.1.1"],
                                   log_level="warn", **opts)
        text = json.dumps(cfg, ensure_ascii=False).replace(
            json.dumps(xray_path)[1:-1], XRAY_PLACEHOLDER)
        out.append({
            "name": name,
            "socks_port": 10808,
            "exclude_ips": ["93.184.216.34", "1.1.1.1"],
            "log_level": "warn",
            "split_mode": opts["split_mode"],
            "split_apps": opts["split_apps"],
            "config": json.loads(text),
        })
    dump("singbox_configs.json", out)


def golden_subinfo() -> None:
    out = []
    for name, headers in HEADER_CASES:
        info = subinfo.SubscriptionInfo.from_headers(headers)
        d = info.to_dict()
        d["fetched"] = ""      # время снятия эталона в сравнении не участвует
        out.append({
            "name": name,
            "headers": headers,
            "info": d,
            "used": info.used,
            "unlimited": info.unlimited,
            "used_ratio": info.used_ratio,
            "device_limit_reached": info.device_limit_reached,
        })
    dump("subscription_info.json", out)


def golden_hwid() -> None:
    out = []
    for source in HWID_SOURCES:
        digest = hashlib.sha256(f"{hwid._SALT}:{source}".encode()).hexdigest()
        value = f"{digest[:8]}-{digest[8:12]}-{digest[12:16]}-{digest[16:20]}-{digest[20:32]}"
        out.append({"source": source, "hwid": value})
    dump("hwid.json", {"salt": hwid._SALT, "cases": out})


def golden_labels() -> None:
    dump("labels.json", {
        "human_bytes": [{"value": n, "text": subinfo.human_bytes(n)} for n in BYTES_CASES],
        "human_interval": [{"hours": h, "text": subinfo.human_interval(h)}
                           for h in INTERVAL_CASES],
    })


def golden_profiles() -> None:
    """Файл профилей ровно того вида, что лежит у пользователя на диске."""
    from storage import Profiles, Subscription

    sub = Subscription(
        name="Моя подписка",
        url="https://panel.example.com/sub/abc123",
        updated="2026-08-16 12:00",
        added="2026-01-09 18:30",
        info=subinfo.SubscriptionInfo.from_headers(HEADER_CASES[0][1]),
        servers=[subscription.parse_link(LINKS[0][1]), subscription.parse_link(LINKS[1][1])],
    )
    sub.info.fetched = "16.08.2026 12:00"
    single = subscription.parse_link(dict(LINKS)["trojan-tcp-tls"])
    profiles = Profiles(subscriptions=[sub], servers=[single])
    dump("profiles.json", profiles.to_dict())

    from storage import DEFAULT_SETTINGS

    settings = dict(DEFAULT_SETTINGS)
    settings.update({
        "hwid": "deadbeef-1234-5678-9abc-def012345678",
        "selected_key": single.key(),
        "split_apps": ["Telegram.exe"],
        "vpn_mode": "tun",
        # Ключ, которого C#-версия знать не обязана: он не должен потеряться
        # при первом же сохранении настроек.
        "unknown_future_key": {"nested": [1, 2, 3]},
    })
    dump("settings.json", settings)


def golden_keys() -> None:
    """Server.key() — по нему отсеиваются дубликаты и хранится выбранный сервер."""
    out = []
    for name, link in LINKS:
        s = subscription.parse_link(link)
        if s:
            out.append({"name": name, "key": s.key()})
    dump("server_keys.json", out)


if __name__ == "__main__":
    print(f"Эталоны -> {OUT}")
    golden_links()
    golden_keys()
    golden_subscription_texts()
    golden_xray_configs()
    golden_singbox_configs()
    golden_subinfo()
    golden_hwid()
    golden_labels()
    golden_profiles()
    print("Готово.")
