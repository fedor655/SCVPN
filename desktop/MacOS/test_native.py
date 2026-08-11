"""Проверки платформенного слоя macOS.

Без фреймворков: обычные assert и печать результата — так же, как smoke_test.py.
Запуск:  ./test.sh
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


@check
def test_paths_data_dir_in_application_support():
    from native import paths

    if paths.FROZEN:
        assert paths.DATA_DIR.name == "SCVPN", paths.DATA_DIR
        assert "Application Support" in str(paths.DATA_DIR), paths.DATA_DIR
    else:
        # В разработке данные лежат рядом с проектом (ROOT/"data"), а не в
        # Application Support — так задумано в paths.py, чтобы было проще
        # проверить содержимое. Имя "SCVPN" гарантировано только в собранном
        # виде, поэтому здесь проверяем сам факт: путь под корнем проекта.
        assert paths.DATA_DIR == paths.ROOT / "data", paths.DATA_DIR


@check
def test_paths_binaries_have_no_exe_suffix():
    from native import paths

    assert paths.xray_exe().name == "xray", paths.xray_exe()
    assert paths.singbox_exe().name == "sing-box", paths.singbox_exe()


@check
def test_singbox_lives_in_root_owned_dir():
    """sing-box запускает root — значит он обязан лежать вне досягаемости пользователя."""
    from native import paths

    assert paths.singbox_exe().is_relative_to(paths.HELPER_BIN_DIR), paths.singbox_exe()
    assert str(paths.HELPER_BIN_DIR).startswith("/Library/"), paths.HELPER_BIN_DIR


@check
def test_hwid_reads_platform_uuid():
    from native.hwid import _machine_source

    src = _machine_source()
    # На настоящем Маке ioreg отдаёт UUID вида 1E1F5E06-F88C-5595-A6C0-54BB55683BE4.
    # Если ioreg не ответил, модуль откатывается к MAC-адресу — это тоже валидно,
    # но тогда проверка должна об этом сказать вслух, а не молча пройти.
    assert src, "источник идентификатора пуст"
    assert not src.startswith("mac-"), f"ioreg не отдал IOPlatformUUID, откат на {src}"
    assert len(src.split("-")) == 5, src


@check
def test_hwid_is_stable_and_uuid_shaped():
    from native.hwid import device_id

    first = device_id()
    assert len(first.split("-")) == 5, first
    assert device_id() == first, "идентификатор должен считаться один раз"


@check
def test_device_headers_report_macos():
    from native.hwid import device_headers

    h = device_headers()
    assert h["x-device-os"] == "Darwin", h
    assert h["x-hwid"], h
    assert h["x-device-model"], h


@check
def test_hardware_services_skips_vpn_configs():
    """Нас интересуют сервисы за реальным устройством: Wi-Fi, Ethernet.

    Записей VPN-конфигов в системе бывают десятки, у них нет Hardware Port,
    и прокси им настраивать нечего.
    """
    from native.sysproxy import hardware_services

    services = hardware_services()
    assert services, "не нашлось ни одного сетевого сервиса с устройством"
    assert all(s.strip() == s for s in services), services
    assert not any(s.startswith("*") for s in services), services


@check
def test_snapshot_round_trip_restores_state():
    """enable -> disable обязан вернуть ровно то, что было. Иначе — без интернета.

    Отдельно проверяем список обхода прокси: на одном сервисе заранее ставим
    пользовательский домен. Если раунд-трип его стирает (а не восстанавливает),
    before != after поймает это — раньше не ловил, т.к. baseline был и так пуст.
    """
    from native import sysproxy

    services = sysproxy.hardware_services()
    assert services
    probe = services[0]
    sysproxy._run(["-setproxybypassdomains", probe, "example.com", "*.internal"])
    try:
        before = {s: sysproxy._read_state(s) for s in services}
        assert before[probe]["bypass"] == ["example.com", "*.internal"], before[probe]
        sysproxy.enable("127.0.0.1", 10809)
        try:
            assert sysproxy.is_enabled(), "прокси не включился"
        finally:
            sysproxy.disable()
        after = {s: sysproxy._read_state(s) for s in services}
        assert before == after, f"состояние не восстановилось:\n{before}\n{after}"
        assert not sysproxy.is_enabled()
    finally:
        sysproxy._run(["-setproxybypassdomains", probe, "Empty"])


@check
def test_xray_asset_is_arm64():
    from native.downloader import ASSET_NAME

    assert ASSET_NAME == "Xray-macos-arm64-v8a.zip", ASSET_NAME


@check
def test_latest_asset_url_resolves():
    """Живой запрос к GitHub: имя ассета в релизе не должно молча уехать."""
    from native.downloader import latest_asset_url

    tag, url = latest_asset_url()
    assert tag and tag != "?", tag
    assert url.endswith("Xray-macos-arm64-v8a.zip"), url


@check
def test_config_has_no_windows_only_fields():
    from helper.config import build, validate

    cfg = build(validate({"socks_port": 10808}), "/Users/x/bin/xray")
    tun_in = cfg["inbounds"][0]
    assert "strict_route" not in tun_in, "strict_route — только Linux и Windows"
    assert "interface_name" not in tun_in, "имя utun-устройства задаёт ядро"
    assert tun_in["auto_route"] is True
    assert cfg["route"]["auto_detect_interface"] is True


@check
def test_xray_process_rule_comes_first():
    """Без этого правила прямое соединение xray к серверу возвращается в TUN."""
    from helper.config import build, validate

    cfg = build(validate({"socks_port": 10808}), "/Users/x/bin/xray")
    first = cfg["route"]["rules"][0]
    assert first == {"process_path": ["/Users/x/bin/xray"], "outbound": "direct"}, first


@check
def test_split_include_sends_only_listed_apps_to_tunnel():
    from helper.config import build, validate

    cfg = build(validate({
        "socks_port": 10808, "split_mode": "include", "split_apps": ["Telegram"],
    }), "/x/xray")
    assert cfg["route"]["final"] == "direct", cfg["route"]["final"]
    assert {"process_name": ["Telegram"], "outbound": "to-xray"} in cfg["route"]["rules"]


@check
def test_split_exclude_keeps_listed_apps_out_of_tunnel():
    from helper.config import build, validate

    cfg = build(validate({
        "socks_port": 10808, "split_mode": "exclude", "split_apps": ["Telegram"],
    }), "/x/xray")
    assert cfg["route"]["final"] == "to-xray", cfg["route"]["final"]
    assert {"process_name": ["Telegram"], "outbound": "direct"} in cfg["route"]["rules"]


@check
def test_validate_rejects_junk():
    """Демон работает от root — сюда приходит недоверенный ввод."""
    from helper.config import ValidationError, validate

    bad = [
        {"socks_port": 0},
        {"socks_port": 70000},
        {"socks_port": "10808; rm -rf /"},
        {"socks_port": 10808, "split_mode": "всё через дядю"},
        {"socks_port": 10808, "split_apps": ["../../../bin/sh"]},
        {"socks_port": 10808, "split_apps": ["a/b"]},
        {"socks_port": 10808, "split_apps": ["x" * 65]},
        {"socks_port": 10808, "stack": "магия"},
        # params — не объект: json.loads() из сокета законно отдаёт список,
        # строку, число — validate() не должен упасть с AttributeError.
        [],
        "10808",
        # split_apps — не список.
        {"socks_port": 10808, "split_apps": "Telegram"},
        # имя приложения — не строка.
        {"socks_port": 10808, "split_apps": [123]},
        # имя приложения — пустое после strip.
        {"socks_port": 10808, "split_apps": ["   "]},
        # exclude_ips — не список.
        {"socks_port": 10808, "exclude_ips": 5},
        # одиночный суррогат: json.loads пропускает, а json.dumps(...).encode("utf-8")
        # в демоне падает — отбить нужно на входе.
        {"socks_port": 10808, "split_apps": ["\ud800X"]},
    ]
    for params in bad:
        try:
            validate(params)
        except ValidationError:
            continue
        raise AssertionError(f"пропустил мусор: {params}")


@check
def test_validate_drops_bad_ips_but_keeps_good():
    from helper.config import validate

    clean = validate({
        "socks_port": 10808,
        # "не ip" — мусорная строка; 16909060 и True — типы, для которых
        # ipaddress.ip_address() молча построил бы правдоподобный IPv4-адрес
        # (16909060 -> 1.2.3.4, True -> 0.0.0.1), если не проверять тип элемента.
        "exclude_ips": ["1.2.3.4", "не ip", "2001:db8::1", 16909060, True],
    })
    assert clean["exclude_ips"] == ["1.2.3.4", "2001:db8::1"], clean["exclude_ips"]


@check
def test_build_places_validated_values_not_hardcoded_ones():
    """Мутационный прогон: захардкоженные server_port/stack/log_level 17/17 не ловили.

    Значения нарочно не совпадают ни с одним умолчанием (socks_port != 1080,
    stack != "gvisor", log_level != "warn"), чтобы мутация на дефолт тоже
    была поймана, а не только мутация на произвольную константу.
    """
    from helper.config import build, validate

    cfg = build(validate({
        "socks_port": 12345, "stack": "system", "log_level": "debug",
    }), "/x/xray")
    assert cfg["outbounds"][0]["server_port"] == 12345, cfg["outbounds"][0]
    assert cfg["inbounds"][0]["stack"] == "system", cfg["inbounds"][0]
    assert cfg["log"]["level"] == "debug", cfg["log"]


@check
def test_exclude_ips_become_host_routes():
    from helper.config import build, validate

    cfg = build(validate({"socks_port": 10808, "exclude_ips": ["1.2.3.4", "2001:db8::1"]}), "/x/xray")
    excludes = cfg["inbounds"][0]["route_exclude_address"]
    assert "1.2.3.4/32" in excludes, excludes
    assert "2001:db8::1/128" in excludes, excludes


@check
def test_daemon_refuses_binary_outside_its_dir():
    """Иначе любой процесс пользователя подменит sing-box и получит root."""
    from pathlib import Path

    from helper.daemon import check_binary

    for bad in (Path("/tmp/sing-box"), Path.home() / "sing-box", Path("/usr/local/bin/sing-box")):
        try:
            check_binary(bad)
        except PermissionError:
            continue
        raise AssertionError(f"пропустил бинарник вне своей папки: {bad}")


@check
def test_daemon_refuses_user_writable_binary():
    """Файл в своей папке, но с правом записи для всех — тоже отказ."""
    import os
    import tempfile
    from pathlib import Path
    from unittest import mock

    from helper import daemon

    with tempfile.TemporaryDirectory() as d:
        fake_dir = Path(d)
        fake = fake_dir / "sing-box"
        fake.write_bytes(b"")
        fake.chmod(0o777)
        with mock.patch.object(daemon, "BIN_DIR", fake_dir):
            try:
                daemon.check_binary(fake)
            except PermissionError:
                pass
            else:
                raise AssertionError("пропустил бинарник, доступный на запись всем")
            fake.chmod(0o755)
            if os.geteuid() == 0:
                daemon.check_binary(fake)   # root:wheel 0755 — годится


@check
def test_daemon_singbox_asset_is_darwin_arm64():
    from helper.daemon import pick_singbox_asset

    assets = [
        {"name": "sing-box-1.13.18-linux-amd64.tar.gz", "browser_download_url": "u1"},
        {"name": "sing-box-1.13.18-darwin-amd64.tar.gz", "browser_download_url": "u2"},
        {"name": "sing-box-1.13.18-darwin-arm64.tar.gz", "browser_download_url": "u3"},
    ]
    assert pick_singbox_asset(assets) == "u3"


@check
def test_daemon_rejects_bad_request_without_dying():
    from helper.daemon import handle_line

    state = {}
    reply = handle_line('{"cmd": "start", "socks_port": 99999}', state)
    assert reply["ok"] is False, reply
    assert "порт" in reply["error"], reply

    reply = handle_line("это не json", state)
    assert reply["ok"] is False, reply

    reply = handle_line('{"cmd": "плясать"}', state)
    assert reply["ok"] is False, reply

    # Длина каждого имени ограничена в config.validate(), а число имён — нет:
    # список на 200 000 записей даёт конфиг в мегабайты, который root запишет
    # на диск. Потолок стоит на стороне демона.
    huge = json.dumps({"cmd": "start", "socks_port": 10808, "split_apps": ["a"] * 200_000})
    reply = handle_line(huge, state)
    assert reply["ok"] is False, reply
    assert "split_apps" in reply["error"], reply


@check
def test_daemon_rejects_foreign_xray_path():
    from helper.daemon import handle_line

    for bad in (None, "relative/xray", "/bin/sh", "/tmp/не-существует/xray"):
        reply = handle_line(json.dumps({"cmd": "start", "socks_port": 10808, "xray_path": bad}), {})
        assert reply["ok"] is False, (bad, reply)


def main() -> int:
    failed = 0
    for fn in CHECKS:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  FAIL {fn.__name__}: {e}")
    print(f"\n{len(CHECKS) - failed}/{len(CHECKS)} проверок пройдено.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
