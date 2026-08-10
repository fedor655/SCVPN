"""Управление системным прокси macOS.

macOS хранит прокси не глобально, а на каждом сетевом сервисе, и правятся они
утилитой `networksetup`. Администратору она доступна без пароля — это проверено,
поэтому режим прокси, в отличие от TUN, никаких повышений прав не требует.

Настраиваем только сервисы за реальным устройством (Wi-Fi, Ethernet): записей
VPN-конфигов в системе бывают десятки, прокси им ни к чему, а обход их всех
занимал бы секунды.

Прежнее состояние каждого сервиса пишем на диск перед включением. Так откат
переживает падение приложения: следующий запуск увидит снимок и вернёт как было.

Это «режим как в браузере»: его уважают почти все приложения с интерфейсом.
Консольные утилиты переменные прокси читают сами и про эту настройку не знают —
для них есть TUN-режим.
"""
from __future__ import annotations

import json
import re
import subprocess

from . import paths

# Обход прокси для локальных адресов.
_BYPASS = [
    "localhost", "127.0.0.1", "10.0.0.0/8", "172.16.0.0/12",
    "192.168.0.0/16", "*.local",
]

# Файл со снимком: что стояло у каждого сервиса до нашего вмешательства.
_SNAPSHOT = paths.DATA_DIR / "sysproxy_backup.json"

# Строки `networksetup -listnetworkserviceorder` идут парами:
#   (4) Wi-Fi
#   (Hardware Port: Wi-Fi, Device: en0)
# У выключенных сервисов вместо номера стоит звёздочка, у VPN-конфигов
# второй строки нет вовсе.
_ORDER_RE = re.compile(r"^\((?P<idx>[\d*]+)\)\s+(?P<name>.+)$")
_PORT_RE = re.compile(r"^\(Hardware Port: .*, Device: (?P<dev>[^)]*)\)$")

# Ключи `networksetup -getwebproxy`: "Enabled: Yes" / "Server: ..." / "Port: ..."
_STATE_RE = re.compile(r"^(?P<key>Enabled|Server|Port):\s*(?P<value>.*)$")

# Два вида прокси и команды к каждому: чтение, установка, выключение.
# SOCKS сюда намеренно не входит: наружу мы отдаём только HTTP-порт Xray, а
# записать его в -setsocksfirewallproxy значило бы отправить SOCKS-клиентов
# на HTTP-инбаунд. Кому нужен весь трафик — тому TUN.
_KINDS = (
    ("web", "-getwebproxy", "-setwebproxy", "-setwebproxystate"),
    ("secure", "-getsecurewebproxy", "-setsecurewebproxy", "-setsecurewebproxystate"),
)


def _run(args: list[str]) -> str:
    return subprocess.run(
        ["networksetup", *args], capture_output=True, text=True, timeout=20
    ).stdout


def hardware_services() -> list[str]:
    """Включённые сетевые сервисы, за которыми стоит реальное устройство."""
    out = _run(["-listnetworkserviceorder"])
    services: list[str] = []
    pending: str | None = None
    for raw in out.splitlines():
        line = raw.strip()
        m = _ORDER_RE.match(line)
        if m:
            pending = None if m.group("idx") == "*" else m.group("name")
            continue
        m = _PORT_RE.match(line)
        if m:
            if pending and m.group("dev").strip():
                services.append(pending)
            pending = None
    return services


def _read_bypass(service: str) -> list[str]:
    """Список обхода прокси сервиса — по домену на строку."""
    out = _run(["-getproxybypassdomains", service])
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    # Пустой список networksetup описывает не пустым выводом, а человеческой
    # фразой вида "There aren't any bypass domains set on Wi-Fi." — сравнивать
    # с ней целиком нельзя, она содержит имя сервиса и может отличаться между
    # версиями macOS. Домены пробелов не содержат, а фраза — предложение с
    # пробелами, этим и отличаем.
    return [line for line in lines if " " not in line]


def _read_state(service: str) -> dict[str, dict[str, str] | list[str]]:
    """Текущие настройки прокси одного сервиса — в том виде, в каком их вернуть."""
    state: dict[str, dict[str, str] | list[str]] = {}
    for kind, get, _set, _setstate in _KINDS:
        fields: dict[str, str] = {}
        for line in _run([get, service]).splitlines():
            m = _STATE_RE.match(line.strip())
            if m:
                fields[m.group("key")] = m.group("value").strip()
        state[kind] = fields
    state["bypass"] = _read_bypass(service)
    return state


def enable(host: str = "127.0.0.1", port: int = 10809) -> None:
    """Включить системный HTTP/HTTPS-прокси на host:port."""
    services = hardware_services()
    if not services:
        raise RuntimeError("Не нашлось активных сетевых сервисов для настройки прокси")

    # Снимок пишем до первого изменения и только если его ещё нет: повторный
    # enable поверх включённого не должен запомнить наши же настройки как «было».
    if not _SNAPSHOT.exists():
        paths.ensure_dirs()
        snapshot = {s: _read_state(s) for s in services}
        _SNAPSHOT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")

    for service in services:
        for _kind, _get, set_cmd, _setstate in _KINDS:
            # Последний аргумент off — прокси без авторизации.
            _run([set_cmd, service, host, str(port), "off"])
        _run(["-setproxybypassdomains", service, *_BYPASS])


def disable() -> None:
    """Выключить системный прокси и вернуть то, что стояло до нас."""
    try:
        snapshot = json.loads(_SNAPSHOT.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        snapshot = {}

    for service in hardware_services():
        was = snapshot.get(service, {})
        for kind, _get, set_cmd, setstate_cmd in _KINDS:
            fields = was.get(kind, {})
            # -set*proxy сам взводит Enabled (даже при пустом Server — проверено
            # на этой машине), поэтому нужное состояние Enabled выставляем
            # отдельной командой следом. Без этого шага, если «было» — пусто и
            # выключено, Server/Port от нашего enable() тихо остаются висеть.
            _run([set_cmd, service, fields.get("Server", ""), fields.get("Port", "0"), "off"])
            _run([setstate_cmd, service, "on" if fields.get("Enabled") == "Yes" else "off"])
        # Список обхода возвращаем к тому, что было — если был пуст, "Empty"
        # это то же самое, что и понимает networksetup.
        bypass = was.get("bypass") or []
        _run(["-setproxybypassdomains", service, *(bypass if bypass else ["Empty"])])

    _SNAPSHOT.unlink(missing_ok=True)


def is_enabled() -> bool:
    """Стоит ли сейчас наш прокси хотя бы на одном сервисе."""
    for service in hardware_services():
        web = _read_state(service).get("web", {})
        if web.get("Enabled") == "Yes" and web.get("Server", "").startswith("127.0.0.1"):
            return True
    return False
