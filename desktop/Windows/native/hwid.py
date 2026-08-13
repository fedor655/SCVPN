"""Идентификатор устройства для панелей с привязкой к устройствам (HWID).

Зачем. Панели вроде Remnawave умеют ограничивать число устройств на аккаунт.
Клиент обязан представиться заголовком `x-hwid`, иначе подписка отдаёт не
серверы, а заглушку `vless://0000...@0.0.0.0:1#App not supported`. Именно так
и выглядела «странная строка App not supported» в списке серверов.

Что уходит на сервер. Не сам идентификатор машины, а его SHA-256 вместе с
солью приложения: провайдеру нужно лишь стабильное «это то же устройство»,
знать MachineGuid ему незачем. Плюс операционная система, её версия и модель —
их панель показывает в списке устройств, чтобы ты понимал, какое отключать.

Значение считается один раз и кладётся в settings.json. Дальше берётся оттуда,
даже если железо или Windows переустановлены: менять HWID нельзя, иначе каждый
раз занимался бы новый слот в лимите устройств.
"""
from __future__ import annotations

import hashlib
import platform
import uuid

from shared.storage import load_settings, save_settings

# Соль, чтобы наружу уходил не сам MachineGuid, а необратимая производная.
_SALT = "scvpn-hwid-v1"


def _machine_source() -> str:
    """Что-нибудь стабильное и уникальное для этой машины."""
    if platform.system() == "Windows":
        try:
            import winreg

            key = winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE,
                r"SOFTWARE\Microsoft\Cryptography",
                0,
                winreg.KEY_READ | winreg.KEY_WOW64_64KEY,
            )
            with key:
                guid, _ = winreg.QueryValueEx(key, "MachineGuid")
                if guid:
                    return str(guid)
        except OSError:
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
    """Заголовки, которых ждут панели с учётом устройств."""
    return {
        "x-hwid": device_id(),
        "x-device-os": platform.system() or "Windows",
        "x-ver-os": platform.release() or "",
        "x-device-model": platform.node() or "PC",
    }
