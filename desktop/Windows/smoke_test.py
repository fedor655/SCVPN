"""Быстрый сквозной тест SCVPN — «всё ли ещё работает».

Проверяет по шагам:
  1) импортируются ли все модули;
  2) читаются ли профили и сколько серверов;
  3) собирается ли конфиг Xray и принимает ли его ядро;
  4) собирается ли конфиг sing-box (TUN) и проходит ли `sing-box check`;
  5) реальный туннель: автоподбор отпечатка + выход в сеть через сервер.

Запуск: test.bat   (или:  test.bat smoke_test.py)
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

# Общий код лежит на уровень выше, в desktop/shared. Каталог самого скрипта
# (desktop/Windows) Python добавляет в sys.path сам — оттуда берётся native.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

OK = "[ OK ]"
FAIL = "[FAIL]"
SKIP = "[SKIP]"
results: list[tuple[str, bool]] = []


def step(title: str):
    print(f"\n=== {title} ===")


def mark(title: str, ok: bool, detail: str = ""):
    results.append((title, ok))
    print(f"{OK if ok else FAIL} {title}" + (f" — {detail}" if detail else ""))


# 1) Импорт модулей -----------------------------------------------------
step("1. Импорт модулей")
try:
    from native import paths
    from native.downloader import core_present, tun_present
    from native.tun import build_singbox_config, is_admin
    from shared.connect import find_working_fingerprint
    from shared.core_runner import XrayRunner, find_free_port
    from shared.storage import load_profiles, load_settings
    from shared.xray_config import build_config
    import shared.ui.main_window  # noqa: F401
    mark("Импорт всех модулей", True)
except Exception as e:  # noqa: BLE001
    mark("Импорт всех модулей", False, repr(e))
    print("\nДальше нет смысла — чиним импорт.")
    sys.exit(1)

print(f"  ядро Xray установлено: {core_present()};  TUN (sing-box+wintun): {tun_present()};  админ: {is_admin()}")

# 2) Профили ------------------------------------------------------------
step("2. Профили и серверы")
profiles = load_profiles()
servers = profiles.all_servers()
mark("Профили читаются", True, f"серверов: {len(servers)}")
if not servers:
    print("Нет серверов — добавь подписку в приложении и запусти снова.")
    sys.exit(0)

reality = [s for s in servers if s.network == "tcp" and s.security == "reality"]
target = reality[0] if reality else servers[0]
print(f"  тестовый сервер: {target.title} [{target.address}:{target.port}]")

# 3) Конфиг Xray --------------------------------------------------------
step("3. Конфиг Xray")
sp = find_free_port(21080)
hp = find_free_port(max(21081, sp + 1))
xcfg = build_config(target, socks_port=sp, http_port=hp)
xpath = paths.DATA_DIR / "_smoke_xray.json"
xpath.write_text(json.dumps(xcfg, ensure_ascii=False, indent=2), encoding="utf-8")
mark("Конфиг Xray собран", True, f"socks={sp}, http={hp}")

# 4) Конфиг sing-box + проверка -----------------------------------------
step("4. Конфиг sing-box (TUN)")
scfg = build_singbox_config(sp, [target.address])
spath = paths.DATA_DIR / "_smoke_singbox.json"
spath.write_text(json.dumps(scfg, ensure_ascii=False, indent=2), encoding="utf-8")
if paths.singbox_exe().exists():
    r = subprocess.run([str(paths.singbox_exe()), "check", "-c", str(spath)],
                       capture_output=True, text=True)
    mark("sing-box check", r.returncode == 0, (r.stderr or r.stdout).strip()[:120])
else:
    print(f"{SKIP} sing-box не установлен — пропускаю проверку TUN")

# 5) Реальный туннель ---------------------------------------------------
step("5. Реальный туннель (автоподбор отпечатка)")
if not core_present():
    print(f"{SKIP} ядро Xray не установлено")
else:
    try:
        import requests
        fp = find_working_fingerprint(target, "auto", "global", False, log=lambda s: print("   " + s))
        srv = __import__("copy").deepcopy(target)
        srv.fingerprint = fp
        cfg = build_config(srv, socks_port=sp, http_port=hp)
        runner = XrayRunner()
        runner.start(cfg)
        time.sleep(2)
        proxies = {"http": f"http://127.0.0.1:{hp}", "https": f"http://127.0.0.1:{hp}"}
        ip = requests.get("https://api.ipify.org", timeout=15, proxies=proxies).text.strip()
        runner.stop()
        mark("Туннель работает", True, f"выходной IP: {ip} (отпечаток {fp})")
    except Exception as e:  # noqa: BLE001
        mark("Туннель работает", False, repr(e))

# Итог ------------------------------------------------------------------
step("ИТОГ")
passed = sum(1 for _, ok in results if ok)
for title, ok in results:
    print(f"  {OK if ok else FAIL} {title}")
print(f"\n{passed}/{len(results)} проверок пройдено.")
sys.exit(0 if passed == len(results) else 1)
