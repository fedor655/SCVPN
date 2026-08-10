"""Проверки платформенного слоя macOS.

Без фреймворков: обычные assert и печать результата — так же, как smoke_test.py.
Запуск:  ./test.sh
"""
from __future__ import annotations

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
