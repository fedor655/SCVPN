"""Управление системным прокси macOS.

macOS хранит прокси не глобально, а на каждом сетевом сервисе, и правятся они
утилитой `networksetup`. Администратору она доступна без пароля — это проверено,
поэтому режим прокси, в отличие от TUN, никаких повышений прав не требует.

Настраиваем только сервисы за реальным устройством (Wi-Fi, Ethernet): записей
VPN-конфигов в системе бывают десятки, прокси им ни к чему, а обход их всех
занимал бы секунды.

Прежнее состояние каждого сервиса пишем на диск перед включением. Так откат
переживает падение приложения: следующий запуск увидит снимок и вернёт как было.

Снимок же — единственное разрешение что-либо откатывать. Нет снимка — значит
этот прокси ставили не мы, и трогать его нельзя: на машине пользователя обычно
живёт ещё один-два клиента (Happ, Tailscale и подобные), и все они прописывают
себе ровно тот же 127.0.0.1, только на своём порту. Без такой проверки один
запуск SCVPN «в холостую» — открыл и закрыл, ни разу не подключившись — стирал
бы чужую настройку на всех сетевых сервисах разом.

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


def _load_snapshot() -> dict | None:
    """Снимок с диска или None, если его нет (или он нечитаем).

    Возвращённый снимок всегда одной формы: {"services": {...}, "proxy": {...}}.
    """
    try:
        data = json.loads(_SNAPSHOT.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    if "services" not in data:
        # Снимок прежнего формата: сервисы лежали прямо в корне, а свой адрес
        # мы никуда не писали. Понять его надо — он хранит НАСТОЯЩЕЕ прежнее
        # состояние сети, и потерять эту запись значит потерять настройки,
        # ради сохранности которых снимок и заводился.
        return {"services": data}
    return data


def enable(host: str = "127.0.0.1", port: int = 10809) -> None:
    """Включить системный HTTP/HTTPS-прокси на host:port."""
    services = hardware_services()
    if not services:
        raise RuntimeError("Не нашлось активных сетевых сервисов для настройки прокси")

    # Состояние сервисов запоминаем до первого изменения и только если снимка
    # ещё нет: повторный enable поверх включённого не должен запомнить наши же
    # настройки как «было». А вот адрес пишем всегда свежий — порт выбирается
    # при каждом подключении заново (find_free_port), и по устаревшему потом
    # не опознать собственный прокси.
    snapshot = _load_snapshot() or {}
    snapshot.setdefault("services", {s: _read_state(s) for s in services})
    snapshot["proxy"] = {"host": host, "port": int(port)}
    paths.ensure_dirs()
    _SNAPSHOT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")

    for service in services:
        for _kind, _get, set_cmd, _setstate in _KINDS:
            # Последний аргумент off — прокси без авторизации.
            _run([set_cmd, service, host, str(port), "off"])
        _run(["-setproxybypassdomains", service, *_BYPASS])


def disable() -> None:
    """Выключить системный прокси и вернуть то, что стояло до нас.

    Без снимка не делаем НИЧЕГО. Снимок — это и есть запись «прокси ставили
    мы», и одновременно единственный источник знания, к чему возвращать. Без
    него прежняя версия выставляла всем сервисам пустой Server, off и bypass
    «Empty» — то есть стирала настройку чужого клиента, даже если SCVPN сам
    в этот запуск ничего не включал.
    """
    snapshot = _load_snapshot()
    if snapshot is None:
        return
    services_was = snapshot.get("services", {})

    for service in hardware_services():
        if service not in services_was:
            # Сервиса не было в снимке — значит его прокси мы не трогали
            # (например, кабель воткнули уже после включения). Возвращать его
            # «как было» нам не к чему и не по праву.
            continue
        was = services_was[service]
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
    """Стоит ли сейчас НАШ прокси хотя бы на одном сервисе.

    Два условия, и оба нужны.

    Снимок: он есть только если включали мы. Переживает и падение приложения
    — следующий запуск по нему и опознает свою работу, и откатит её.

    Хост: на 127.0.0.1 сидят и другие VPN-клиенты (у владельца этой машины —
    Happ, ChatVPN_*, Tailscale). Новый снимок содержит и порт, и по адресу с
    портом чужой прокси не отличить от своего. Снимок прежнего формата портом
    не располагал — в нём восстанавливаем ровно как было, т.е. сверяемся по
    хосту, без порта. Это отоб услове снимка: чужой клиент своего снимка у
    нас не оставляет.
    """
    snapshot = _load_snapshot()
    if snapshot is None:
        return False
    ours = snapshot.get("proxy") or {}
    host = str(ours.get("host", ""))
    port = str(ours.get("port", ""))

    # Старый формат: снимок без блока proxy. Сверяемся по хосту.
    has_new_format = bool(ours)
    if not has_new_format:
        if not host:
            host = "127.0.0.1"  # дефолт старого формата
    else:
        if not host or not port:
            return False

    for service in hardware_services():
        web = _read_state(service).get("web", {})
        if web.get("Enabled") == "Yes" and web.get("Server") == host:
            if has_new_format:
                # Новый формат: требуем совпадение порта
                if web.get("Port") == port:
                    return True
            else:
                # Старый формат: только хост
                return True
    return False
