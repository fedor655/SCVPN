"""Идентификатор устройства для панелей с привязкой к устройствам (HWID).

Зачем. Панели вроде Remnawave умеют ограничивать число устройств на аккаунт.
Клиент обязан представиться заголовком `x-hwid`, иначе подписка отдаёт не
серверы, а заглушку `vless://0000...@0.0.0.0:1#App not supported`.

Что уходит на сервер. Не сам идентификатор машины, а его SHA-256 вместе с
солью приложения: провайдеру нужно лишь стабильное «это то же устройство»,
знать UUID платы ему незачем. Плюс операционная система, её версия и модель —
их панель показывает в списке устройств, чтобы ты понимал, какое отключать.

Значение считается один раз и кладётся в settings.json. Дальше берётся оттуда,
даже если система переустановлена: менять HWID нельзя, иначе каждый раз
занимался бы новый слот в лимите устройств.

Соль та же, что на Windows и Android, но исходник другой (IOPlatformUUID), так
что один и тот же человек с Мака и с ПК займёт два слота — это верно, это
разные устройства.
"""
from __future__ import annotations

import hashlib
import platform
import re
import subprocess
import uuid

from shared.storage import load_settings, save_settings

# Соль, чтобы наружу уходил не сам идентификатор платы, а необратимая производная.
_SALT = "scvpn-hwid-v1"

_UUID_RE = re.compile(r'"IOPlatformUUID"\s*=\s*"([^"]+)"')


def _machine_source() -> str:
    """Что-нибудь стабильное и уникальное для этой машины.

    IOPlatformUUID выдаётся плате и переживает переустановку системы —
    ровно то, что нужно, чтобы не занимать новый слот в лимите устройств.
    """
    try:
        out = subprocess.run(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        m = _UUID_RE.search(out)
        if m and m.group(1):
            return m.group(1)
    except (OSError, subprocess.SubprocessError):
        pass
    # Запасной вариант: MAC-адрес. Хуже (меняется с сетевой картой), но лучше,
    # чем случайное значение — оно бы пережило только текущую установку.
    return f"mac-{uuid.getnode():012x}"


def device_id() -> str:
    """Стабильный HWID этого устройства. Считается один раз и запоминается."""
    settings = load_settings()
    saved = settings.get("hwid", "")
    if saved:
        return saved

    digest = hashlib.sha256(f"{_SALT}:{_machine_source()}".encode()).hexdigest()
    # Формат UUID — панели его ожидают чаще всего и точно принимают.
    hwid = f"{digest[:8]}-{digest[8:12]}-{digest[12:16]}-{digest[16:20]}-{digest[20:32]}"

    settings["hwid"] = hwid
    save_settings(settings)
    return hwid


def device_headers() -> dict[str, str]:
    """Заголовки, которых ждят панели с учётом устройств."""
    return {
        "x-hwid": device_id(),
        "x-device-os": platform.system() or "Darwin",
        "x-ver-os": platform.release() or "",
        "x-device-model": platform.node() or "Mac",
    }
