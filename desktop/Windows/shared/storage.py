"""Хранение профилей и настроек в обычных JSON-файлах в папке data/.

Файлы можно открыть любым текстовым редактором и проверить, что внутри —
никаких бинарных баз и скрытых полей.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from native import paths
from .models import Server
from .subinfo import SubscriptionInfo


# ----------------------------------------------------------------------
# Подписка = именованный URL + список серверов, полученных с него
# ----------------------------------------------------------------------
@dataclass
class Subscription:
    name: str = ""
    url: str = ""
    updated: str = ""
    added: str = ""              # когда подписку добавили в приложение
    servers: list[Server] = field(default_factory=list)
    # Сведения от панели: срок, трафик, автообновление. Хранятся, чтобы экран
    # подписки открывался мгновенно и работал без сети — цифры от последнего
    # успешного обновления, дата этого обновления лежит в info.fetched.
    info: SubscriptionInfo = field(default_factory=SubscriptionInfo)

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "url": self.url,
            "updated": self.updated,
            "added": self.added,
            "info": self.info.to_dict(),
            "servers": [s.to_dict() for s in self.servers],
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Subscription":
        return cls(
            name=d.get("name", ""),
            url=d.get("url", ""),
            updated=d.get("updated", ""),
            added=d.get("added", ""),
            info=SubscriptionInfo.from_dict(d.get("info", {})),
            servers=[Server.from_dict(x) for x in d.get("servers", [])],
        )


# ----------------------------------------------------------------------
# Профили: подписки + одиночные серверы (добавленные ссылкой вручную)
# ----------------------------------------------------------------------
@dataclass
class Profiles:
    subscriptions: list[Subscription] = field(default_factory=list)
    servers: list[Server] = field(default_factory=list)  # одиночные

    def all_servers(self) -> list[Server]:
        result: list[Server] = list(self.servers)
        for sub in self.subscriptions:
            result.extend(sub.servers)
        return result

    def to_dict(self) -> dict[str, Any]:
        return {
            "subscriptions": [s.to_dict() for s in self.subscriptions],
            "servers": [s.to_dict() for s in self.servers],
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Profiles":
        return cls(
            subscriptions=[Subscription.from_dict(x) for x in d.get("subscriptions", [])],
            servers=[Server.from_dict(x) for x in d.get("servers", [])],
        )


def load_profiles() -> Profiles:
    if paths.PROFILES_FILE.exists():
        try:
            data = json.loads(paths.PROFILES_FILE.read_text(encoding="utf-8"))
            return Profiles.from_dict(data)
        except Exception as e:  # noqa: BLE001
            print(f"[storage] не смог прочитать профили: {e}")
    return Profiles()


def save_profiles(profiles: Profiles) -> None:
    paths.ensure_dirs()
    paths.PROFILES_FILE.write_text(
        json.dumps(profiles.to_dict(), ensure_ascii=False, indent=2), encoding="utf-8"
    )


# ----------------------------------------------------------------------
# Настройки приложения
# ----------------------------------------------------------------------
DEFAULT_SETTINGS: dict[str, Any] = {
    "socks_port": 10808,
    "http_port": 10809,
    "route_mode": "global",   # global | bypass_ru
    "block_ads": False,
    "system_proxy": True,      # включать системный прокси при подключении (для режима proxy)
    "selected_key": "",        # Server.key() выбранного сервера
    "tls_fingerprint": "auto",  # auto = автоподбор; либо chrome/firefox/safari/...
    "vpn_mode": "proxy",       # proxy = системный прокси; tun = весь трафик (нужен админ)
    "split_mode": "off",       # off | exclude | include — раздельное туннелирование (только TUN)
    "split_apps": [],          # имена .exe, к которым применяется split_mode
    "tun_stack": "gvisor",     # сетевой стек sing-box в TUN (только macOS)
}


def load_settings() -> dict[str, Any]:
    settings = dict(DEFAULT_SETTINGS)
    if paths.SETTINGS_FILE.exists():
        try:
            settings.update(json.loads(paths.SETTINGS_FILE.read_text(encoding="utf-8")))
        except Exception as e:  # noqa: BLE001
            print(f"[storage] не смог прочитать настройки: {e}")
    return settings


def save_settings(settings: dict[str, Any]) -> None:
    paths.ensure_dirs()
    paths.SETTINGS_FILE.write_text(
        json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def now_iso() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M")
