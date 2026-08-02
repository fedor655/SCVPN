"""Служебные сведения о подписке, которые панель шлёт в заголовках ответа.

Стандарт де-факто у панелей (Marzban, Remnawave, 3x-ui): рядом со списком
серверов в HTTP-заголовках едут срок действия, потраченный трафик, интервал
автообновления, ссылка на поддержку. Приложение их просто показывает — сами
цифры считает панель, мы ничего не додумываем.

Чего в заголовках нет — того и не показываем. Например, даты активации
подписки там не бывает, поэтому в интерфейсе стоит дата, когда подписку
добавили в приложение, и подписана она именно так.
"""
from __future__ import annotations

import base64
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


def _maybe_base64(value: str) -> str:
    """Панели шлют название либо как есть, либо как `base64:...`."""
    if not value.startswith("base64:"):
        return value
    try:
        return base64.b64decode(value[7:]).decode("utf-8", "replace")
    except Exception:  # noqa: BLE001
        return value


@dataclass
class SubscriptionInfo:
    title: str = ""              # profile-title
    account: str = ""            # имя файла из content-disposition — обычно логин
    upload: int = 0              # байт
    download: int = 0            # байт
    total: int = 0               # байт, 0 = безлимит
    expire: int = 0              # unix-время, 0 = бессрочно
    update_interval: int = 0     # часы (profile-update-interval у панелей в часах)
    support_url: str = ""
    web_page_url: str = ""
    announce: str = ""
    hwid: dict[str, str] = field(default_factory=dict)
    fetched: str = ""            # когда мы это прочитали

    # ---------- производные величины, чтобы интерфейс не считал сам ----------

    @property
    def used(self) -> int:
        return self.upload + self.download

    @property
    def unlimited(self) -> bool:
        return self.total <= 0

    @property
    def used_ratio(self) -> float:
        """Доля израсходованного лимита, 0..1. При безлимите — 0."""
        if self.unlimited:
            return 0.0
        return min(1.0, self.used / self.total)

    @property
    def expires_at(self) -> datetime | None:
        return datetime.fromtimestamp(self.expire) if self.expire else None

    @property
    def days_left(self) -> int | None:
        d = self.expires_at
        if d is None:
            return None
        return (d - datetime.now()).days

    @property
    def device_limit_reached(self) -> bool:
        return self.hwid.get("x-hwid-max-devices-reached") == "true"

    # ---------- сериализация ----------

    def to_dict(self) -> dict[str, Any]:
        return {
            "title": self.title, "account": self.account,
            "upload": self.upload, "download": self.download, "total": self.total,
            "expire": self.expire, "update_interval": self.update_interval,
            "support_url": self.support_url, "web_page_url": self.web_page_url,
            "announce": self.announce, "hwid": self.hwid, "fetched": self.fetched,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "SubscriptionInfo":
        return cls(
            title=d.get("title", ""), account=d.get("account", ""),
            upload=int(d.get("upload", 0)), download=int(d.get("download", 0)),
            total=int(d.get("total", 0)), expire=int(d.get("expire", 0)),
            update_interval=int(d.get("update_interval", 0)),
            support_url=d.get("support_url", ""), web_page_url=d.get("web_page_url", ""),
            announce=d.get("announce", ""), hwid=dict(d.get("hwid", {})),
            fetched=d.get("fetched", ""),
        )

    @classmethod
    def from_headers(cls, headers) -> "SubscriptionInfo":
        h = {k.lower(): str(v) for k, v in headers.items()}
        info = cls(fetched=datetime.now().strftime("%d.%m.%Y %H:%M"))

        info.title = _maybe_base64(h.get("profile-title", ""))
        info.announce = _maybe_base64(h.get("announce", ""))
        info.support_url = h.get("support-url", "")
        info.web_page_url = h.get("profile-web-page-url", "")

        # content-disposition: attachment; filename=F_Semin_key-1
        disp = h.get("content-disposition", "")
        if "filename=" in disp:
            info.account = disp.split("filename=", 1)[1].strip().strip('"; ')

        # subscription-userinfo: upload=0; download=123; total=0; expire=1788405825
        for part in h.get("subscription-userinfo", "").split(";"):
            if "=" not in part:
                continue
            key, _, raw = part.strip().partition("=")
            try:
                value = int(float(raw))
            except ValueError:
                continue
            if key in ("upload", "download", "total", "expire"):
                setattr(info, key, value)

        try:
            info.update_interval = int(h.get("profile-update-interval", "0"))
        except ValueError:
            info.update_interval = 0

        info.hwid = {k: v for k, v in h.items() if k.startswith("x-hwid")}
        return info


# ----------------------------------------------------------------------
# Человеческие подписи — одни и те же во всех местах интерфейса
# ----------------------------------------------------------------------
def human_bytes(n: int) -> str:
    if n <= 0:
        return "0 Б"
    for unit, size in (("ТБ", 1 << 40), ("ГБ", 1 << 30), ("МБ", 1 << 20), ("КБ", 1 << 10)):
        if n >= size:
            return f"{n / size:.2f} {unit}"
    return f"{n} Б"


def human_interval(hours: int) -> str:
    """Интервал автообновления. Панели шлют его в часах."""
    if hours <= 0:
        return "не задано"
    if hours % 24 == 0:
        days = hours // 24
        return f"раз в {days} дн." if days > 1 else "раз в сутки"
    return f"раз в {hours} ч."
