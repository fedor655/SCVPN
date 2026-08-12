"""Живая проверка SCVPN на macOS: парсинг, сборка конфигов, туннель.

Проверяет по шагам:
  1) импортируются ли все модули;
  2) читаются ли профили и сколько серверов;
  3) собирается ли конфиг Xray;
  4) собирается ли конфиг sing-box (TUN) — тем же демонским модулем
     helper/config.py, каким пользуется сам демон (см. его docstring:
     готовый конфиг демон от клиента не принимает, только параметры);
  5) реальный туннель: автоподбор отпечатка + выход в сеть через сервер.

В отличие от test_native.py, этот скрипт ходит в сеть и требует, чтобы в
приложении уже была добавлена подписка. Блок, для которого предпосылка не
выполнена (нет серверов, sing-box не установлен, нужен root — sudo здесь
запрещён условиями машины), помечается "skip" с причиной: он не проходит
молча за успех и не считается пройденной проверкой.

Запуск: ./test.sh smoke
"""
from __future__ import annotations

import copy
import json
import sys
import time
from pathlib import Path

# Общий код лежит на уровень выше, в desktop/shared. Каталог самого скрипта
# (desktop/MacOS) Python добавляет в sys.path сам — оттуда берётся native.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

OK, FAIL, SKIP = "  ok  ", " FAIL ", " skip "
TAGS = {"ok": OK, "fail": FAIL, "skip": SKIP}
results: list[tuple[str, str]] = []   # (title, "ok" | "fail" | "skip")


def step(title: str) -> None:
    print(f"\n=== {title} ===")


def mark(title: str, status: str, detail: str = "") -> None:
    """status: "ok" — проверка прошла, "fail" — провалилась, "skip" — не
    выполнялась из-за отсутствующей предпосылки. skip в счёт пройденных не
    идёт — иначе «пропущено» неотличимо от «пройдено» в итоговой строке."""
    results.append((title, status))
    print(f"{TAGS[status]} {title}" + (f" — {detail}" if detail else ""))


# 1) Импорт модулей -----------------------------------------------------
step("1. Импорт модулей")
try:
    from helper.config import build as build_singbox
    from helper.config import validate as validate_singbox
    from native import paths
    from native.downloader import core_present, tun_present
    from native.tun import privileged
    from shared.connect import find_working_fingerprint
    from shared.core_runner import XrayRunner, find_free_port
    from shared.storage import load_profiles, load_settings  # noqa: F401
    from shared.xray_config import build_config
    import shared.ui.main_window  # noqa: F401
    mark("Импорт всех модулей", "ok")
except Exception as e:  # noqa: BLE001
    mark("Импорт всех модулей", "fail", repr(e))
    print("\nДальше нет смысла — чиним импорт.")
    sys.exit(1)

print(f"  ядро Xray установлено: {core_present()};  sing-box: {tun_present()};  "
      f"TUN доступен (демон установлен): {privileged()}")

# 2) Профили и серверы ----------------------------------------------------
step("2. Профили и серверы")
profiles = load_profiles()
servers = profiles.all_servers()
mark("Профили читаются", "ok", f"серверов: {len(servers)}")

have_server = bool(servers)
NO_SERVER = "нет серверов — добавь подписку в приложении и запусти снова"

if have_server:
    reality = [s for s in servers if s.network == "tcp" and s.security == "reality"]
    target = reality[0] if reality else servers[0]
    print(f"  тестовый сервер: {target.title} [{target.address}:{target.port}]")
else:
    print(f"  {NO_SERVER}.")
    print("  дальнейшие блоки требуют реального сервера — помечаю их skip, а не ok.")

# 3) Конфиг Xray ------------------------------------------------------------
step("3. Конфиг Xray")
sp = hp = None
if not have_server:
    mark("Конфиг Xray собран", "skip", NO_SERVER)
else:
    sp = find_free_port(21080)
    hp = find_free_port(max(21081, sp + 1))
    xcfg = build_config(target, socks_port=sp, http_port=hp)
    xpath = paths.DATA_DIR / "_smoke_xray.json"
    xpath.write_text(json.dumps(xcfg, ensure_ascii=False, indent=2), encoding="utf-8")
    mark("Конфиг Xray собран", "ok", f"socks={sp}, http={hp}")

# 4) Конфиг sing-box (TUN) — тем же модулем, что и демон --------------------
step("4. Конфиг sing-box (TUN)")
spath = None
if not have_server:
    mark("Конфиг sing-box собран", "skip", NO_SERVER)
else:
    scfg = build_singbox(
        validate_singbox({"socks_port": sp, "exclude_ips": [target.address]}),
        str(paths.xray_exe()),
    )
    spath = paths.DATA_DIR / "_smoke_singbox.json"
    spath.write_text(json.dumps(scfg, ensure_ascii=False, indent=2), encoding="utf-8")
    mark("Конфиг sing-box собран", "ok", f"exclude_ips=[{target.address}]")

if not have_server:
    mark("sing-box check (бинарником)", "skip", NO_SERVER)
elif not tun_present():
    mark("sing-box check (бинарником)", "skip",
         "sing-box не установлен — включи TUN-режим в приложении, демон скачает его")
else:
    # sudo здесь запрещён условиями машины, на которой гоняется эта проверка —
    # прогнать реальным бинарником можно только руками, отдельно.
    mark("sing-box check (бинарником)", "skip", "требует root, sudo этой проверке запрещён")
    print(f"       Прогнать вручную: sudo '{paths.singbox_exe()}' check -c '{spath}'")

# 5) Реальный туннель (автоподбор отпечатка) --------------------------------
step("5. Реальный туннель (автоподбор отпечатка)")
if not have_server:
    mark("Туннель работает", "skip", NO_SERVER)
elif not core_present():
    mark("Туннель работает", "skip", "ядро Xray не установлено")
else:
    runner = None
    try:
        import requests
        fp = find_working_fingerprint(target, "auto", "global", False, log=lambda s: print("   " + s))
        srv = copy.deepcopy(target)
        srv.fingerprint = fp
        cfg = build_config(srv, socks_port=sp, http_port=hp)
        runner = XrayRunner()
        runner.start(cfg)
        time.sleep(2)
        proxies = {"http": f"http://127.0.0.1:{hp}", "https": f"http://127.0.0.1:{hp}"}
        ip = requests.get("https://api.ipify.org", timeout=15, proxies=proxies).text.strip()
        mark("Туннель работает", "ok", f"выходной IP: {ip} (отпечаток {fp})")
    except Exception as e:  # noqa: BLE001
        mark("Туннель работает", "fail", repr(e))
    finally:
        # В отличие от windows-версии, глушим ядро и при провале тоже: иначе
        # неудачное подключение оставляет xray висеть до следующего запуска
        # приложения (или до cleanup_stray в native/tun.py).
        if runner is not None:
            runner.stop()

# Итог ------------------------------------------------------------------
step("ИТОГ")
passed = sum(1 for _, s in results if s == "ok")
skipped = sum(1 for _, s in results if s == "skip")
failed = sum(1 for _, s in results if s == "fail")
for title, s in results:
    print(f"  {TAGS[s]} {title}")
print(f"\n{passed} пройдено, {skipped} пропущено, {failed} провалено — всего {len(results)}.")

if failed:
    sys.exit(1)
if passed == 0:
    # Ни одна проверка не была реально выполнена — это не успех, хоть провалов
    # тоже нет. "0 проверок выполнено" не должно выглядеть как "всё хорошо".
    print("Ничего не проверено по-настоящему — не считать успехом.")
    sys.exit(2)
sys.exit(0)
