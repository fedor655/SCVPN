"""Конфиг sing-box для TUN на macOS плюс валидация того, что прислал клиент.

Почему валидация именно здесь. Демон работает от root и слушает сокет,
доступный группе admin. Всё, что приходит в сокет, — недоверенный ввод, даже
если прислало его наше же приложение. Поэтому демон не принимает готовый
конфиг: он принимает горстку параметров, проверяет каждый и собирает JSON сам.
Путь к xray сюда тоже не приходит извне — его подставляет демон.

Отличия от windows-варианта конфига:
  - нет strict_route: поле поддержано только на Linux и Windows;
  - нет interface_name: utun-устройства именует ядро, своё имя не задать;
  - wintun не нужен, TUN на macOS штатный.
"""
from __future__ import annotations

import ipaddress

# Режимы раздельного туннелирования (split tunneling).
SPLIT_OFF = "off"           # все приложения через VPN
SPLIT_EXCLUDE = "exclude"   # все через VPN, кроме выбранных
SPLIT_INCLUDE = "include"   # только выбранные через VPN
SPLIT_MODES = (SPLIT_OFF, SPLIT_EXCLUDE, SPLIT_INCLUDE)

# Сетевой стек sing-box. gvisor — свой стек в пространстве пользователя, самый
# предсказуемый на darwin; system быстрее, но опирается на хостовый стек;
# mixed — system для TCP и gvisor для UDP.
STACKS = ("gvisor", "system", "mixed")

_MAX_APP_NAME = 64


class ValidationError(ValueError):
    """Клиент прислал то, что демон не станет исполнять."""


def _port(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"порт должен быть целым числом, пришло {value!r}")
    if not 1 <= value <= 65535:
        raise ValidationError(f"порт вне диапазона: {value}")
    return value


def _app_name(value: object) -> str:
    """Имя процесса для правила sing-box. Только имя — никаких путей."""
    if not isinstance(value, str):
        raise ValidationError(f"имя приложения должно быть строкой, пришло {value!r}")
    name = value.strip()
    if not name:
        raise ValidationError("пустое имя приложения")
    if len(name) > _MAX_APP_NAME:
        raise ValidationError(f"слишком длинное имя приложения: {name[:20]}…")
    if "/" in name or "\\" in name or name in (".", ".."):
        raise ValidationError(f"имя приложения не может быть путём: {name!r}")
    return name


def validate(params: dict) -> dict:
    """Проверить параметры от клиента и вернуть очищенный набор.

    Невалидные IP молча отбрасываем — список исключений это лишь запасной
    пояс от петли, главный пояс это правило process_path для xray. А вот
    испорченный порт или режим — уже ошибка: молча подставлять умолчание
    значит поднять туннель не тем, чем просили.
    """
    clean: dict = {"socks_port": _port(params.get("socks_port"))}

    mode = params.get("split_mode", SPLIT_OFF)
    if mode not in SPLIT_MODES:
        raise ValidationError(f"неизвестный режим раздельного туннеля: {mode!r}")
    clean["split_mode"] = mode

    apps = params.get("split_apps") or []
    if not isinstance(apps, list):
        raise ValidationError("split_apps должен быть списком")
    clean["split_apps"] = [_app_name(a) for a in apps]

    stack = params.get("stack", "gvisor")
    if stack not in STACKS:
        raise ValidationError(f"неизвестный сетевой стек: {stack!r}")
    clean["stack"] = stack

    ips: list[str] = []
    for raw in params.get("exclude_ips") or []:
        try:
            ips.append(str(ipaddress.ip_address(raw)))
        except (ValueError, TypeError):
            continue
    clean["exclude_ips"] = ips

    level = params.get("log_level", "warn")
    clean["log_level"] = level if level in ("trace", "debug", "info", "warn", "error") else "warn"

    return clean


def build(params: dict, xray_path: str) -> dict:
    """Конфиг sing-box: TUN -> SOCKS Xray, плюс правила раздельного туннеля.

    Раздельное туннелирование делает сам sing-box: он умеет сопоставлять
    соединение с процессом-владельцем (`process_name`) и отправлять его либо
    в туннель, либо напрямую. Поэтому это работает только в TUN-режиме —
    системный прокси про приложения ничего не знает.

    `params` обязан быть результатом validate(): здесь проверок уже нет.
    """
    excludes = [
        f"{ip}/32" if ipaddress.ip_address(ip).version == 4 else f"{ip}/128"
        for ip in params["exclude_ips"]
    ]
    apps = params["split_apps"]
    mode = params["split_mode"]

    rules: list[dict] = []

    # Первым делом выводим из туннеля сам Xray. Без этого соединение ядра к
    # серверу снова попадает в TUN, оттуда обратно в ядро — и так по кругу.
    # Это правило переживает смену IP сервера, в отличие от списка исключений
    # ниже, поэтому оно главный пояс, а route_exclude_address — запасной.
    rules.append({"process_path": [xray_path], "outbound": "direct"})

    if apps and mode == SPLIT_EXCLUDE:
        # Выбранные — мимо VPN, всё остальное (final) — в туннель.
        rules.append({"process_name": apps, "outbound": "direct"})
    elif apps and mode == SPLIT_INCLUDE:
        # Выбранные — в туннель, всё остальное — напрямую (см. final ниже).
        rules.append({"process_name": apps, "outbound": "to-xray"})

    final = "direct" if (apps and mode == SPLIT_INCLUDE) else "to-xray"

    return {
        "log": {"level": params["log_level"]},
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.18.0.1/30"],
                "mtu": 1500,
                "auto_route": True,
                "stack": params["stack"],
                "route_exclude_address": excludes,
            }
        ],
        "outbounds": [
            {
                "type": "socks",
                "tag": "to-xray",
                "server": "127.0.0.1",
                "server_port": params["socks_port"],
                "version": "5",
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "auto_detect_interface": True,
            "final": final,
            "rules": rules,
        },
    }
