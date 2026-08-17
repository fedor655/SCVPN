"""Быстрый сквозной тест SCVPN — «всё ли ещё работает».

Проверяет по шагам:
  1) импортируются ли все модули;
  2) AmneziaWG: разбор .conf и ссылки, сборка .conf и outbound (без сети);
  3) читаются ли профили и сколько серверов;
  4) собирается ли конфиг Xray и принимает ли его ядро;
  5) собирается ли конфиг sing-box (TUN) и проходит ли `sing-box check`;
  6) реальный туннель: автоподбор отпечатка + выход в сеть через сервер.

Запуск: test.bat   (или:  test.bat smoke_test.py)
"""
from __future__ import annotations

import json
import subprocess
import sys
import time

# Каталог самого скрипта Python добавляет в sys.path сам — оттуда берутся и
# native, и shared.

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
    from awg_runner import AwgRunner, build_conf
    from connect import find_working_fingerprint
    from core_runner import XrayRunner, find_free_port
    from storage import load_profiles, load_settings
    from subscription import parse_link, parse_wg_conf
    from xray_config import build_config
    import ui.main_window  # noqa: F401
    mark("Импорт всех модулей", True)
except Exception as e:  # noqa: BLE001
    mark("Импорт всех модулей", False, repr(e))
    print("\nДальше нет смысла — чиним импорт.")
    sys.exit(1)

print(f"  ядро Xray установлено: {core_present()};  TUN (sing-box+wintun): {tun_present()};  "
      f"AmneziaWG: {paths.awg_exe().exists()};  админ: {is_admin()}")

# 2) AmneziaWG ----------------------------------------------------------
# Проверка полностью оффлайн и на выдуманном сервере: она про разбор и сборку,
# а не про сеть. Поэтому стоит до профилей — работает и на пустом приложении.
step("2. AmneziaWG: разбор и конфиги")
WG_CONF = """# Name = Проверка AWG
[Interface]
PrivateKey = SLKrJGDbcvyDNPCUlMcRfSnO1nkzMQ2nWQ5PZ2nZlUw=
Address = 10.66.66.4/32, fd42:42:42::4/128
DNS = 1.1.1.1
MTU = 1280
Jc = 10
Jmin = 47
ListenPort = 51820

[Peer]
PublicKey = eDbUqm0e2FzYtQ9nQ5zMRfmZ8lE3PZ0RfBcXpVfvNjQ=
PresharedKey = uMPBmFHrDW7lM/eeIT8H5PLdIYYE1EAyoBBjSNKxnBc=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25
"""
WG_LINK = (
    "wireguard://SLKrJGDbcvyDNPCUlMcRfSnO1nkzMQ2nWQ5PZ2nZlUw%3D@203.0.113.10:51820"
    "?publickey=eDbUqm0e2FzYtQ9nQ5zMRfmZ8lE3PZ0RfBcXpVfvNjQ%3D"
    "&presharedkey=uMPBmFHrDW7lM%2FeeIT8H5PLdIYYE1EAyoBBjSNKxnBc%3D"
    "&address=10.66.66.4%2F32%2Cfd42%3A42%3A42%3A%3A4%2F128&dns=1.1.1.1"
    "&mtu=1280&keepalive=25&jc=10&jmin=47#Проверка AWG"
)
try:
    wg = parse_wg_conf(WG_CONF)
    assert wg is not None and wg.protocol == "wireguard", "conf не разобрался"
    assert wg.name == "Проверка AWG", wg.name
    assert wg.awg == "jc=10,jmin=47", wg.awg
    assert wg.local_address == "10.66.66.4/32,fd42:42:42::4/128", wg.local_address
    assert (wg.address, wg.port, wg.mtu, wg.keepalive) == ("203.0.113.10", 51820, 1280, 25)
    mark("Разбор .conf", True, f"{wg.title}, обфускация: {wg.awg or 'нет'}")

    # Ссылка и .conf обязаны давать один и тот же сервер: иначе одна и та же
    # подписка в QR и в списке ссылок дала бы две разные строки в списке.
    same = parse_link(WG_LINK)
    assert same is not None and same.key() == wg.key(), "ссылка и .conf разошлись"
    mark("Разбор wireguard:// ", True, same.key())

    # .conf для бинарника собирается из тех же полей и разбирается обратно —
    # это и есть стык с awg/conf.go, который читает его на той стороне.
    again = parse_wg_conf(build_conf(wg))
    assert again is not None and again.key() == wg.key(), "сборка .conf не сходится с разбором"
    mark("Сборка .conf для scvpn-awg", True, f"{len(build_conf(wg).splitlines())} строк")

    # Xray не делает WireGuard сам — он ходит в socks поднятого scvpn-awg.
    wout = build_config(wg, awg_port=10810)["outbounds"][0]
    assert wout["protocol"] == "socks", wout
    assert wout["settings"]["servers"][0] == {"address": "127.0.0.1", "port": 10810}, wout
    assert "streamSettings" not in wout, "streamSettings у wireguard быть не должно"
    mark("Outbound Xray -> scvpn-awg", True, "socks 127.0.0.1:10810, без streamSettings")

    # Пропусти это правило — и UDP-сокет туннеля пойдёт в сам туннель.
    rule = build_singbox_config(10808, ["203.0.113.10"])["route"]["rules"][0]
    assert str(paths.awg_exe()) in rule.get("process_path", []), rule
    mark("Анти-петля в TUN знает про scvpn-awg", True, paths.awg_exe().name)
except Exception as e:  # noqa: BLE001
    mark("AmneziaWG", False, repr(e))

# 3) Профили ------------------------------------------------------------
step("3. Профили и серверы")
profiles = load_profiles()
servers = profiles.all_servers()
mark("Профили читаются", True, f"серверов: {len(servers)}")
if not servers:
    print("Нет серверов — добавь подписку в приложении и запусти снова.")
    sys.exit(0)

reality = [s for s in servers if s.network == "tcp" and s.security == "reality"]
target = reality[0] if reality else servers[0]
print(f"  тестовый сервер: {target.title} [{target.address}:{target.port}]")

# 4) Конфиг Xray --------------------------------------------------------
step("4. Конфиг Xray")
sp = find_free_port(21080)
hp = find_free_port(max(21081, sp + 1))
xcfg = build_config(target, socks_port=sp, http_port=hp)
xpath = paths.DATA_DIR / "_smoke_xray.json"
xpath.write_text(json.dumps(xcfg, ensure_ascii=False, indent=2), encoding="utf-8")
mark("Конфиг Xray собран", True, f"socks={sp}, http={hp}")

# 5) Конфиг sing-box + проверка -----------------------------------------
step("5. Конфиг sing-box (TUN)")
scfg = build_singbox_config(sp, [target.address])
spath = paths.DATA_DIR / "_smoke_singbox.json"
spath.write_text(json.dumps(scfg, ensure_ascii=False, indent=2), encoding="utf-8")
if paths.singbox_exe().exists():
    r = subprocess.run([str(paths.singbox_exe()), "check", "-c", str(spath)],
                       capture_output=True, text=True)
    mark("sing-box check", r.returncode == 0, (r.stderr or r.stdout).strip()[:120])
else:
    print(f"{SKIP} sing-box не установлен — пропускаю проверку TUN")

# 6) Реальный туннель ---------------------------------------------------
step("6. Реальный туннель (автоподбор отпечатка)")
if not core_present():
    print(f"{SKIP} ядро Xray не установлено")
else:
    ap = find_free_port(hp + 1)
    awg = AwgRunner(on_log=lambda s: print("   " + s))
    runner = XrayRunner()
    try:
        import requests
        fp = find_working_fingerprint(target, "auto", "global", False, log=lambda s: print("   " + s))
        srv = __import__("copy").deepcopy(target)
        srv.fingerprint = fp
        # У wireguard-сервера туннель держит отдельный процесс, и Xray ходит
        # в него — без этого шага проверка мерила бы закрытый порт.
        if srv.protocol == "wireguard":
            awg.start(srv, ap)
        cfg = build_config(srv, socks_port=sp, http_port=hp, awg_port=ap)
        runner.start(cfg)
        time.sleep(2)
        proxies = {"http": f"http://127.0.0.1:{hp}", "https": f"http://127.0.0.1:{hp}"}
        ip = requests.get("https://api.ipify.org", timeout=15, proxies=proxies).text.strip()
        how = "wireguard" if srv.protocol == "wireguard" else f"отпечаток {fp}"
        mark("Туннель работает", True, f"выходной IP: {ip} ({how})")
    except Exception as e:  # noqa: BLE001
        mark("Туннель работает", False, repr(e))
    finally:
        runner.stop()
        awg.stop()

# Итог ------------------------------------------------------------------
step("ИТОГ")
passed = sum(1 for _, ok in results if ok)
for title, ok in results:
    print(f"  {OK if ok else FAIL} {title}")
print(f"\n{passed}/{len(results)} проверок пройдено.")
sys.exit(0 if passed == len(results) else 1)
