"""Модель одного VPN-сервера и сборка из неё outbound-секции конфига Xray.

Server хранит уже разобранные поля ссылки (vless:// и т.п.).
Метод to_outbound() превращает их в JSON-объект, понятный ядру Xray.
Здесь нет ничего «магического» — это прямой перевод параметров ссылки
в формат конфига Xray (см. https://xtls.github.io/config/).
"""
from __future__ import annotations

import uuid as _uuid
from dataclasses import dataclass, field
from typing import Any, Optional

# Локальный SOCKS5 бинарника scvpn-awg — через него ходит wireguard-outbound.
# Порт объявлен здесь, а не рядом с 10808/10809 в xray_config, чтобы у
# to_outbound() было значение по умолчанию без обратной зависимости модели от
# сборки конфига.
DEFAULT_AWG_PORT = 10810


@dataclass
class Server:
    # --- основное ---
    protocol: str = "vless"        # vless | vmess | trojan | shadowsocks | wireguard
    name: str = ""                  # отображаемое имя (из #fragment)
    address: str = ""               # хост или IP
    port: int = 443

    # --- учётные данные ---
    uuid: str = ""                  # id для vless/vmess
    password: str = ""              # пароль для trojan
    method: str = ""                # шифр для shadowsocks
    alter_id: int = 0               # vmess alterId (обычно 0)

    # --- транспорт (streamSettings) ---
    network: str = "tcp"            # tcp | ws | grpc | http | quic | kcp
    security: str = "none"          # none | tls | reality
    flow: str = ""                  # xtls-rprx-vision и т.п. (vless)

    # TLS / Reality
    sni: str = ""                   # serverName
    fingerprint: str = ""           # uTLS fingerprint (chrome/firefox/...)
    alpn: str = ""                  # h2,http/1.1
    public_key: str = ""            # Reality pbk
    short_id: str = ""              # Reality sid
    spider_x: str = "/"             # Reality spx
    allow_insecure: bool = False    # пропускать ошибки сертификата (TLS)

    # параметры путей транспорта
    ws_path: str = "/"              # путь для ws / http
    ws_host: str = ""               # Host-заголовок для ws
    grpc_service: str = ""          # serviceName для grpc

    # --- WireGuard / AmneziaWG ---
    # Имена полей заморожены контрактом и одинаковы на всех четырёх платформах:
    # profiles.json переносят между ними как есть. Endpoint пира — это уже
    # существующие address/port, а публичный ключ сервера — public_key: у
    # Reality то же самое значение и тот же смысл.
    private_key: str = ""           # приватный ключ клиента (base64)
    preshared_key: str = ""         # PresharedKey (base64), пусто — если нет
    local_address: str = ""         # Address интерфейса через запятую
    allowed_ips: str = ""           # "0.0.0.0/0,::/0"; пусто — полный
    wg_dns: str = ""                # DNS интерфейса через запятую
    mtu: int = 0                    # 0 — взять 1420
    keepalive: int = 0              # 0 — не слать
    # Параметры обфускации одной строкой вида "jc=10,jmin=47" в именах UAPI.
    # Одним полем намеренно: Amnezia добавляет их от версии к версии, и разбор
    # поимённо означал бы правку четырёх платформ на каждый новый ключ. Пустое
    # значение — обычный WireGuard без обфускации, это рабочий режим.
    awg: str = ""

    # сырые параметры на всякий случай (для отладки)
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def title(self) -> str:
        return self.name or f"{self.address}:{self.port}"

    # ------------------------------------------------------------------
    # Сборка outbound для Xray
    # ------------------------------------------------------------------
    def to_outbound(self, tag: str = "proxy", awg_port: int = DEFAULT_AWG_PORT) -> dict[str, Any]:
        if self.protocol == "wireguard":
            # WireGuard держит не Xray, а отдельный scvpn-awg, и отдаёт его
            # локальным SOCKS5 — Xray просто ходит в этот порт. Так весь код
            # маршрутизации, DNS, TUN и системного прокси остаётся общим.
            # streamSettings здесь не нужен и вреден: до 127.0.0.1 нечего
            # шифровать и не за кого себя выдавать.
            return {
                "tag": tag,
                "protocol": "socks",
                "settings": {"servers": [{"address": "127.0.0.1", "port": awg_port}]},
            }

        out: dict[str, Any] = {"tag": tag, "protocol": self.protocol}

        if self.protocol == "vless":
            out["settings"] = {
                "vnext": [{
                    "address": self.address,
                    "port": self.port,
                    "users": [{
                        "id": self.uuid,
                        "encryption": "none",
                        **({"flow": self.flow} if self.flow else {}),
                    }],
                }]
            }
        elif self.protocol == "vmess":
            out["settings"] = {
                "vnext": [{
                    "address": self.address,
                    "port": self.port,
                    "users": [{
                        "id": self.uuid,
                        "alterId": self.alter_id,
                        "security": "auto",
                    }],
                }]
            }
        elif self.protocol == "trojan":
            out["settings"] = {
                "servers": [{
                    "address": self.address,
                    "port": self.port,
                    "password": self.password,
                }]
            }
        elif self.protocol == "shadowsocks":
            out["settings"] = {
                "servers": [{
                    "address": self.address,
                    "port": self.port,
                    "method": self.method,
                    "password": self.password,
                }]
            }
        else:
            raise ValueError(f"Неизвестный протокол: {self.protocol}")

        out["streamSettings"] = self._stream_settings()
        return out

    def _stream_settings(self) -> dict[str, Any]:
        ss: dict[str, Any] = {"network": self.network}

        # --- безопасность транспорта ---
        if self.security == "reality":
            ss["security"] = "reality"
            ss["realitySettings"] = {
                "serverName": self.sni,
                "fingerprint": self.fingerprint or "chrome",
                "publicKey": self.public_key,
                "shortId": self.short_id,
                "spiderX": self.spider_x or "/",
            }
        elif self.security == "tls":
            ss["security"] = "tls"
            tls: dict[str, Any] = {
                "serverName": self.sni or self.address,
                "allowInsecure": self.allow_insecure,
            }
            if self.fingerprint:
                tls["fingerprint"] = self.fingerprint
            if self.alpn:
                tls["alpn"] = [a.strip() for a in self.alpn.split(",") if a.strip()]
            ss["tlsSettings"] = tls
        else:
            ss["security"] = "none"

        # --- настройки конкретного транспорта ---
        if self.network == "ws":
            ws: dict[str, Any] = {"path": self.ws_path or "/"}
            host = self.ws_host or self.sni
            if host:
                ws["headers"] = {"Host": host}
            ss["wsSettings"] = ws
        elif self.network == "grpc":
            ss["grpcSettings"] = {"serviceName": self.grpc_service}
        elif self.network == "http":  # h2
            ss["httpSettings"] = {
                "path": self.ws_path or "/",
                **({"host": [self.ws_host]} if self.ws_host else {}),
            }
        # tcp / прочее — без доп. настроек

        return ss

    # ------------------------------------------------------------------
    # Сериализация для хранения профилей
    # ------------------------------------------------------------------
    def to_dict(self) -> dict[str, Any]:
        return {k: v for k, v in self.__dict__.items()}

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Server":
        known = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in d.items() if k in known})

    def key(self) -> str:
        """Грубый ключ для отсева дубликатов при обновлении подписки.

        public_key последним запасным — из-за WireGuard: у него нет ни uuid, ни
        пароля, и два разных пира на одном host:port схлопывались бы в одну
        строку списка. Формат строки при этом не меняется.
        """
        secret = self.uuid or self.password or self.public_key
        return f"{self.protocol}://{secret}@{self.address}:{self.port}/{self.network}/{self.security}"

