"""Проверки платформенного слоя macOS.

Без фреймворков: обычные assert и печать результата — так же, как smoke_test.py.
Запуск:  ./test.sh
"""
from __future__ import annotations

import contextlib
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


# ----------------------------------------------------------------------
# Стенд для проверок демона
# ----------------------------------------------------------------------
# Главное свойство демона — снимать sing-box, когда клиент умер, — нельзя
# проверить, разглядывая чистые функции. Поэтому стенд поднимает настоящий
# сокет, настоящие потоки и настоящий процесс, но без root: BIN_DIR и RUN_DIR
# подменены на временную папку, check_binary заглушён (его проверяют отдельно),
# а вместо sing-box — скрипт, который спит.
#
# Метка готовности здесь не для красоты. Появление PID в pgrep ещё не значит,
# что оболочка успела выполнить `trap`: если ударить SIGTERM в этот зазор,
# «упрямый» sing-box умрёт как миленький, и проверка позеленеет, ничего не
# проверив. Ждём именно готовности, а в метку кладём PID — так метка от
# прошлого запуска не сойдёт за готовность нового.
#
# Спим не одним `sleep 300`, а короткими: убитая оболочка не должна оставлять
# после себя пятиминутного сироту, которого чистящий pkill не ловит.
_FAKE_SINGBOX = "#!/bin/sh\necho $$ > {ready}\nwhile :; do sleep 1; done\n"

# Упрямый вариант: игнорирует SIGTERM, как повёл бы себя зависший sing-box.
_STUBBORN_SINGBOX = "#!/bin/sh\ntrap '' TERM\necho $$ > {ready}\nwhile :; do sleep 1; done\n"

# Умирает сам сразу после старта — симулирует падение sing-box или снятие его
# другим клиентом. Соединение при этом демон не рвёт (см. Задачу 11, п.3).
_SINGBOX_CRASHES = "#!/bin/sh\necho $$ > {ready}\nexit 7\n"

_DAEMON_SRC = """
import socket, sys
from pathlib import Path
sys.path.insert(0, {root!r})
from helper import daemon
daemon.BIN_DIR = Path({bindir!r})
daemon.RUN_DIR = Path({rundir!r})
daemon.check_binary = lambda p: None
daemon.STOP_GRACE_SEC = 1
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind({sock!r})
srv.listen(4)
daemon.install_signal_handlers()
print("READY", flush=True)
raise SystemExit(daemon.serve_forever(srv))
"""

_CLIENT_SRC = """
import json, socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect({sock!r})
s.sendall(json.dumps({{"cmd": "start", "socks_port": 10808, "xray_path": {xray!r}}}).encode() + b"\\n")
print(s.recv(65536).decode().strip(), flush=True)
time.sleep(300)
"""


class _Stand:
    """Временный «демон» со своими папками и поддельным sing-box."""

    def __init__(self, script: str = _FAKE_SINGBOX) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "bin").mkdir()
        self.ready = self.tmp / "ready"
        exe = self.tmp / "bin" / "sing-box"
        exe.write_text(script.format(ready=self.ready))
        exe.chmod(0o755)
        self.xray = str(self.tmp / "xray")
        Path(self.xray).write_text("")
        Path(self.xray).chmod(0o755)
        self.sock_path = str(self.tmp / "s.sock")
        self._stack = contextlib.ExitStack()
        self._srv: socket.socket | None = None
        self._procs: list[subprocess.Popen] = []
        self._socks: list[socket.socket] = []

    # -- запуск демона --------------------------------------------------
    def serve_here(self) -> _Stand:
        """Поднять обслуживание в этом же процессе."""
        from helper import daemon

        for name, value in (("BIN_DIR", self.tmp / "bin"), ("RUN_DIR", self.tmp / "run"),
                            ("check_binary", lambda p: None), ("STOP_GRACE_SEC", 1),
                            ("SWEEP_GRACE_SEC", 1)):
            self._stack.enter_context(mock.patch.object(daemon, name, value))
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(self.sock_path)
        self._srv.listen(4)
        threading.Thread(target=self._accept, args=(daemon,), daemon=True).start()
        return self

    def _accept(self, daemon) -> None:
        while True:
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
            threading.Thread(target=daemon.serve_client, args=(conn,), daemon=True).start()

    def serve_subprocess(self) -> subprocess.Popen:
        """Поднять демона отдельным процессом — иначе не послать ему сигнал."""
        src = _DAEMON_SRC.format(root=str(Path(__file__).resolve().parent),
                                 bindir=str(self.tmp / "bin"), rundir=str(self.tmp / "run"),
                                 sock=self.sock_path)
        p = subprocess.Popen([sys.executable, "-c", src], stdout=subprocess.PIPE, text=True)
        self._procs.append(p)
        assert p.stdout.readline().strip() == "READY", "демон не поднялся"
        return p

    # -- клиенты ---------------------------------------------------------
    def connect(self, timeout: float = 15.0) -> socket.socket:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.sock_path)
        self._socks.append(s)
        return s

    def ask(self, sock: socket.socket, req: dict) -> dict:
        sock.sendall((json.dumps(req) + "\n").encode())
        return self.reply(sock)

    def reply(self, sock: socket.socket) -> dict:
        """Ближайший кадр с ответом; строки логов пропускаем."""
        buf = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                raise AssertionError("демон закрыл соединение, не ответив")
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                obj = json.loads(line.decode())
                if "ok" in obj:
                    return obj

    def spawn_client(self) -> subprocess.Popen:
        """Клиент отдельным процессом: поднимает туннель и живёт, пока не убьют."""
        p = subprocess.Popen(
            [sys.executable, "-c", _CLIENT_SRC.format(sock=self.sock_path, xray=self.xray)],
            stdout=subprocess.PIPE, text=True,
        )
        self._procs.append(p)
        reply = json.loads(p.stdout.readline())
        assert reply.get("ok") is True, reply
        return p

    def start_tunnel(self) -> None:
        """Поднять «туннель» через сокет и убедиться, что процесс появился."""
        sock = self.connect()
        reply = self.ask(sock, {"cmd": "start", "socks_port": 10808, "xray_path": self.xray})
        assert reply["ok"] is True, reply

    # -- наблюдение ------------------------------------------------------
    def singbox_pids(self) -> list[str]:
        r = subprocess.run(["/usr/bin/pgrep", "-f", f"{self.tmp}/bin/sing-box run -c"],
                           capture_output=True, text=True)
        return [p for p in r.stdout.split() if p]

    def wait_gone(self, timeout: float = 15.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self.singbox_pids():
                return True
            time.sleep(0.05)
        return False

    def wait_up(self, timeout: float = 10.0) -> bool:
        """Поднялся И готов: метку с собственным PID пишет сам поддельный sing-box.

        Сверяем PID из метки с живыми процессами — иначе метка, оставшаяся от
        прошлого sing-box на этом же стенде, сойдёт за готовность нового.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pids = self.singbox_pids()
            if pids and self.ready.exists() and self.ready.read_text().strip() in pids:
                return True
            time.sleep(0.05)
        return False

    def spawn_orphan(self) -> None:
        """Поднять sing-box с той же командной строкой, но без надзора."""
        (self.tmp / "run").mkdir(exist_ok=True)
        (self.tmp / "run" / "singbox.json").write_text("{}")
        self._procs.append(subprocess.Popen(
            f"exec {self.tmp}/bin/sing-box run -c {self.tmp}/run/singbox.json", shell=True))
        assert self.wait_up(), "подложный сирота не поднялся"

    # -- уборка ----------------------------------------------------------
    def __enter__(self) -> _Stand:
        return self

    def __exit__(self, *exc) -> None:
        from helper import daemon

        for p in self._procs:
            p.kill()
            p.wait()
        for s in self._socks:
            with contextlib.suppress(OSError):
                s.close()
        if self._srv is not None:
            self._srv.close()
        daemon.SUPERVISOR.stop()
        self._stack.close()
        subprocess.run(["/usr/bin/pkill", "-9", "-f", f"{self.tmp}/bin/sing-box run -c"],
                       capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)


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


# Опытный сервис для проверок, меняющих настройки НАСТОЯЩЕЙ сети этой машины.
# Thunderbolt Bridge выбран потому, что на ней не используется: кабеля нет,
# трафика через него нет, и порча его настроек никого не оставит без сети.
# Wi-Fi и Ethernet-адаптеры такие проверки не трогают — см. подмену
# hardware_services() в каждой из них.
_PROBE_SERVICE = "Thunderbolt Bridge"


def _reset_probe_proxy(sysproxy, service: str) -> None:
    """Вернуть опытный сервис к пустому состоянию: выключено, пусто, без обхода."""
    for _kind, _get, set_cmd, setstate_cmd in sysproxy._KINDS:
        sysproxy._run([set_cmd, service, "", "0", "off"])
        sysproxy._run([setstate_cmd, service, "off"])
    sysproxy._run(["-setproxybypassdomains", service, "Empty"])


@check
def test_disable_leaves_a_foreign_proxy_alone():
    """Ревью перед слиянием, Important 2: SCVPN стирал чужие настройки прокси
    просто по запуску и закрытию.

    is_enabled() считала нашим ЛЮБОЙ прокси на 127.0.0.1 без сверки порта, а
    disable() при отсутствующем снимке выставляла всем сервисам пусто, off и
    bypass «Empty». main_window зовёт эту пару в четырёх местах, включая
    closeEvent. На машине, где живёт ещё один клиент (Happ, ChatVPN_*,
    Tailscale — все они прописывают 127.0.0.1 на своём порту), достаточно
    было открыть и закрыть SCVPN, ни разу не подключаясь, чтобы уничтожить
    чужую конфигурацию на всех сетевых сервисах.

    Проверка живая, на настоящем networksetup, но строго на одном опытном
    сервисе (см. _PROBE_SERVICE): hardware_services() подменён, снимок уведён
    во временную папку.
    """
    from native import sysproxy

    assert _PROBE_SERVICE in sysproxy.hardware_services(), "нет опытного сервиса"
    tmp = Path(tempfile.mkdtemp())
    try:
        with mock.patch.object(sysproxy, "hardware_services", lambda: [_PROBE_SERVICE]), \
             mock.patch.object(sysproxy, "_SNAPSHOT", tmp / "sysproxy_backup.json"):
            # Чужой клиент выставил свой прокси — тот же 127.0.0.1, свой порт.
            sysproxy._run(["-setwebproxy", _PROBE_SERVICE, "127.0.0.1", "9999", "off"])
            sysproxy._run(["-setsecurewebproxy", _PROBE_SERVICE, "127.0.0.1", "9999", "off"])
            sysproxy._run(["-setproxybypassdomains", _PROBE_SERVICE, "chat.example"])
            foreign = sysproxy._read_state(_PROBE_SERVICE)
            assert foreign["web"]["Port"] == "9999", foreign
            assert foreign["web"]["Enabled"] == "Yes", foreign

            # Запуск и закрытие SCVPN без единого подключения: снимка нет.
            assert not sysproxy._SNAPSHOT.exists()
            assert sysproxy.is_enabled() is False, "чужой прокси принят за свой"
            # И даже прямой вызов disable() без снимка не смеет ничего трогать.
            sysproxy.disable()
            assert sysproxy._read_state(_PROBE_SERVICE) == foreign, (
                f"чужие настройки изменены:\n{foreign}\n{sysproxy._read_state(_PROBE_SERVICE)}"
            )
    finally:
        _reset_probe_proxy(sysproxy, _PROBE_SERVICE)
        shutil.rmtree(tmp, ignore_errors=True)


@check
def test_is_enabled_wants_our_own_port_not_just_localhost():
    """Вторая половина Important 2: одного снимка мало.

    Снимок мог остаться от прошлого падения, а прокси за это время сменил
    хозяина — на 127.0.0.1 сидят и другие клиенты. Порт мы знаем: его пишет
    в снимок тот же enable(), который прокси и поставил.
    """
    from native import sysproxy

    assert _PROBE_SERVICE in sysproxy.hardware_services(), "нет опытного сервиса"
    tmp = Path(tempfile.mkdtemp())
    try:
        with mock.patch.object(sysproxy, "hardware_services", lambda: [_PROBE_SERVICE]), \
             mock.patch.object(sysproxy, "_SNAPSHOT", tmp / "sysproxy_backup.json"):
            before = sysproxy._read_state(_PROBE_SERVICE)
            sysproxy.enable("127.0.0.1", 10809)
            try:
                assert sysproxy.is_enabled() is True, "свой же прокси не опознан"
                # Чужой клиент перебил настройку на свой порт: снимок наш, а
                # прокси уже не наш — откатывать нечего.
                sysproxy._run(["-setwebproxy", _PROBE_SERVICE, "127.0.0.1", "9999", "off"])
                assert sysproxy.is_enabled() is False, "чужой порт принят за свой"
            finally:
                sysproxy.disable()
            assert sysproxy._read_state(_PROBE_SERVICE) == before, (
                f"состояние не восстановилось:\n{before}\n{sysproxy._read_state(_PROBE_SERVICE)}"
            )
            assert not sysproxy._SNAPSHOT.exists(), "снимок должен уйти вместе с откатом"
    finally:
        _reset_probe_proxy(sysproxy, _PROBE_SERVICE)
        shutil.rmtree(tmp, ignore_errors=True)


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


def _refusal(fn, *args) -> str:
    """Текст отказа. Проверять сам факт отказа мало: важна его причина."""
    try:
        fn(*args)
    except Exception as e:  # noqa: BLE001
        return str(e)
    raise AssertionError(f"{fn.__name__} не отказал на {args}")


@check
def test_daemon_refuses_binary_outside_its_dir():
    """Иначе любой процесс пользователя подменит sing-box и получит root.

    Берём именно существующий, root-овый и исполняемый файл: раньше здесь были
    несуществующие пути, и проверка проходила бы даже без сравнения с BIN_DIR —
    отказ приходил от resolve(strict=True), то есть тест мерил не то.
    """
    from pathlib import Path

    from helper.daemon import BIN_DIR, check_binary

    assert "вне" in _refusal(check_binary, Path("/bin/sh")), "/bin/sh пролез"
    assert "вне" in _refusal(check_binary, Path("/usr/bin/true"))
    assert "нет такого" in _refusal(check_binary, BIN_DIR / "не-существует")


@check
def test_daemon_refuses_user_writable_binary():
    """Все четыре причины отказа check_binary, каждая по отдельности.

    Порядок проверок в check_binary выбран так, чтобы каждая была видна: если
    проверка на root стоит первой, она накрывает собой остальные (временный
    файл принадлежит пользователю), и тест зеленеет, что бы ни удалили.
    """
    import os
    import tempfile
    from pathlib import Path
    from unittest import mock

    from helper import daemon

    with tempfile.TemporaryDirectory() as d:
        fake_dir = Path(d)
        fake = fake_dir / "sing-box"
        fake.write_bytes(b"")
        with mock.patch.object(daemon, "BIN_DIR", fake_dir):
            fake.chmod(0o777)
            assert "на запись" in _refusal(daemon.check_binary, fake)
            fake.chmod(0o755)
            fake.chmod(0o644)
            assert "не исполняемый" in _refusal(daemon.check_binary, fake)
            fake.chmod(0o755)
            if os.geteuid() == 0:
                daemon.check_binary(fake)   # root:wheel 0755 — годится
            else:
                assert "не принадлежит root" in _refusal(daemon.check_binary, fake)


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
    """Каждый отказ — по своей причине. Голое ok=False здесь ничего не значит:
    без установленного sing-box любой start вернул бы ok=False."""
    from helper.daemon import handle_line

    state = {}
    cases = [
        ('{"cmd": "start", "socks_port": 99999}', "порт"),
        ("это не json", "не разобрал"),
        ('{"cmd": "плясать"}', "неизвестная команда"),
        ("[1, 2, 3]", "не разобрал"),
        # Длина каждого имени ограничена в config.validate(), а число имён —
        # нет: список на 200 000 записей даёт конфиг в мегабайты, который root
        # запишет на диск. Потолок стоит на стороне демона.
        (json.dumps({"cmd": "start", "socks_port": 10808,
                     "split_apps": ["a"] * 200_000}), "split_apps"),
        (json.dumps({"cmd": "start", "socks_port": 10808,
                     "exclude_ips": ["1.2.3.4"] * 2000}), "exclude_ips"),
        # Глубокая вложенность: json.loads отдаёт RecursionError, а он не
        # ValueError. Наружу это уходило мимо всех веток, то есть рвало
        # соединение — а обрыв соединения у нас снимает туннель.
        ("[" * 260_000 + "]" * 260_000, "не разобрал"),
    ]
    for line, expected in cases:
        reply = handle_line(line, state)
        assert reply["ok"] is False, (line[:40], reply)
        assert expected in reply["error"], (line[:40], reply)


@check
def test_daemon_rejects_foreign_xray_path():
    """Путь к ядру уезжает в process_path — правило выпуска мимо туннеля."""
    import tempfile
    from pathlib import Path

    from helper.daemon import _checked_xray_path

    tmp = Path(tempfile.mkdtemp())
    good = tmp / "xray"
    good.write_text("")
    good.chmod(0o755)
    assert _checked_xray_path(str(good)) == str(good.resolve())   # положительный контроль

    assert "абсолютным" in _refusal(_checked_xray_path, None)
    assert "абсолютным" in _refusal(_checked_xray_path, "relative/xray")
    assert "абсолютным" in _refusal(_checked_xray_path, 42)
    assert "xray" in _refusal(_checked_xray_path, "/bin/sh")
    assert "нет такого файла" in _refusal(_checked_xray_path, str(tmp / "нет" / "xray"))

    # Симлинк с правильным именем на чужой бинарник: имя проверяется до
    # канонизации — и в правило уезжает /bin/sh.
    link = tmp / "link" / "xray"
    link.parent.mkdir()
    link.symlink_to("/bin/sh")
    assert "ведёт на" in _refusal(_checked_xray_path, str(link))

    # Файл, в который может писать кто угодно, — не ядро, а приглашение.
    ww = tmp / "ww" / "xray"
    ww.parent.mkdir()
    ww.write_text("")
    ww.chmod(0o777)
    assert "на запись" in _refusal(_checked_xray_path, str(ww))

    shutil.rmtree(tmp, ignore_errors=True)


@check
def test_daemon_drops_tunnel_when_connection_closes():
    """Главное свойство демона: обрыв соединения снимает туннель.

    Заодно это положительный контроль для всей семьи проверок вокруг start:
    здесь корректный запрос обязан вернуть ok=True, иначе ok=False в соседних
    проверках не значило бы ничего.
    """
    with _Stand().serve_here() as stand:
        sock = stand.connect()
        reply = stand.ask(sock, {"cmd": "start", "socks_port": 10808, "xray_path": stand.xray})
        assert reply["ok"] is True, reply
        assert stand.wait_up(), "поддельный sing-box не поднялся"
        assert stand.ask(sock, {"cmd": "status"})["running"] is True

        sock.close()
        assert stand.wait_gone(), f"sing-box пережил обрыв соединения: {stand.singbox_pids()}"


@check
def test_daemon_sets_owner_before_the_only_fallible_step_after_popen():
    """Ревью Задачи 9, Критикал (Раунд 2).

    Между self.proc = Popen(...) и self.owner = owner раньше стоял ровно
    один оператор — log(). Под launchd stderr — файл (StandardErrorPath), и
    запись в него может отказать (ENOSPC, EIO, сломанная труба). Если бы
    log() падал в этом зазоре, получалось бы состояние, которого быть не
    должно: процесс уже есть, running уже True, а owner ещё None —
    serve_client() не признал бы владельца и не снял бы туннель по обрыву
    его же соединения. Зазор должен быть пуст: owner выставляется вплотную
    к Popen, до log().

    Проверяем настоящим протоколом с настоящим демоном: log() подменён так,
    чтобы бросить OSError именно на сообщении "sing-box запущен" — той самой
    строке, что раньше стояла в зазоре. Даже так owner должен оказаться
    выставлен, а обрыв этого (единственного в тесте) соединения — снять
    туннель.
    """
    from unittest import mock

    from helper import daemon

    real_log = daemon.log

    def flaky_log(msg: str) -> None:
        if "sing-box запущен" in msg:
            raise OSError(32, "Broken pipe")  # имитация отказавшего stderr под launchd
        real_log(msg)

    with _Stand().serve_here() as stand:
        with mock.patch.object(daemon, "log", flaky_log):
            sock = stand.connect()
            # Ответ клиенту тут не главное (log() уронил обработку command —
            # handle_line() поймает исключение и ответит ok=False). Главное —
            # состояние демона ПОСЛЕ: успел ли owner встать до того, как всё
            # посыпалось.
            stand.ask(sock, {"cmd": "start", "socks_port": 10808, "xray_path": stand.xray})
            assert stand.wait_up(), "sing-box должен был реально подняться, несмотря на упавший log()"
            assert daemon.SUPERVISOR.owner is not None, (
                "owner остался None — зазор между Popen и owner не пуст"
            )

            sock.close()
            assert stand.wait_gone(), (
                f"владеющее соединение закрылось, а туннель остался: {stand.singbox_pids()}"
            )


@check
def test_daemon_drops_ownerless_tunnel_on_any_disconnect():
    """Ревью Задачи 9, Критикал (Раунд 2): running=True при owner=None —
    отказ в безопасную сторону.

    Такое состояние в норме недостижимо (зазор в Supervisor.start() пуст —
    см. соседнюю проверку), но если оно всё же возникнет по ещё не найденной
    причине, туннель без хозяина обязан снять первый же отключившийся, а не
    остаться висеть навсегда: root-овый sing-box с системными маршрутами,
    снять который уже некому — тот самый мёртвый туннель без интернета,
    ради ухода от которого написан весь модуль.
    """
    from helper import daemon

    with _Stand().serve_here() as stand:
        sock = stand.connect()
        reply = stand.ask(sock, {"cmd": "start", "socks_port": 10808, "xray_path": stand.xray})
        assert reply["ok"] is True, reply
        assert stand.wait_up(), "поддельный sing-box не поднялся"
        assert daemon.SUPERVISOR.owner is not None

        # Симулируем само состояние (не важно, как оно возникло) —
        # владелец потерян, а туннель жив.
        daemon.SUPERVISOR.owner = None

        sock.close()
        assert stand.wait_gone(), (
            f"туннель без владельца пережил обрыв соединения: {stand.singbox_pids()}"
        )


@check
def test_daemon_drops_tunnel_when_client_is_killed():
    """Ровно сценарий ручной проверки Задачи 11: pkill -9 по приложению."""
    with _Stand().serve_here() as stand:
        client = stand.spawn_client()
        assert stand.wait_up(), "поддельный sing-box не поднялся"
        client.kill()
        client.wait()
        assert stand.wait_gone(), f"sing-box пережил смерть клиента: {stand.singbox_pids()}"


@check
def test_daemon_drops_tunnel_on_repeated_sigterm():
    """launchctl unload и выключение машины. Второй сигнал не должен всё сорвать.

    sing-box здесь упрямый — игнорирует SIGTERM, поэтому демон уходит в
    ожидание, и туда прилетает второй SIGTERM. Раньше он поднимал SystemExit
    прямо из ожидания: демон уходил с кодом 0, а sing-box оставался жив.
    """
    import signal

    with _Stand(_STUBBORN_SINGBOX) as stand:
        d = stand.serve_subprocess()
        stand.spawn_client()
        assert stand.wait_up(), "поддельный sing-box не поднялся"

        d.send_signal(signal.SIGTERM)
        time.sleep(0.3)                 # демон уже внутри ожидания
        d.send_signal(signal.SIGTERM)
        assert d.wait(timeout=30) == 0
        assert stand.wait_gone(), f"sing-box пережил уход демона: {stand.singbox_pids()}"


@check
def test_daemon_drops_tunnel_on_sighup():
    """Демона запускают и руками; закрытое окно терминала — это SIGHUP."""
    import signal

    with _Stand() as stand:
        d = stand.serve_subprocess()
        stand.spawn_client()
        assert stand.wait_up(), "поддельный sing-box не поднялся"

        d.send_signal(signal.SIGHUP)
        assert d.wait(timeout=30) == 0
        assert stand.wait_gone(), f"sing-box пережил SIGHUP демону: {stand.singbox_pids()}"


@check
def test_daemon_closes_socket_even_when_serving_falls_over_on_a_foreign_connection():
    """Обслуживание клиента может свалиться и не на чтении сокета.

    Поток для ответов создаётся не всегда (лимит потоков достижим: accept-цикл
    плодит их без ограничения). Если такое исключение уйдёт мимо finally,
    соединение останется незакрытым — путь в обход самого dead-man's switch.

    Крах случается на ВТОРОМ соединении, которое ничего не поднимало (как
    install_singbox или обычный status) — значит по Supervisor.owner чужой
    активный туннель этот крах трогать не должен (см. Задачу 9, Important 2,
    и test_install_singbox_does_not_drop_a_running_tunnel рядом). Раньше здесь
    проверялось обратное — что любой крах на любом соединении сносит туннель,
    — но это было прямым следствием того самого бага: демон не различал, чьё
    соединение оборвалось, и не имел этого свойства как отдельного намерения.
    Что действительно проверяет этот тест — что finally отрабатывает и
    закрывает СВОЁ (упавшее) соединение, даже когда исключение прилетело не
    с чтения сокета, а из создания Outbox.
    """
    from unittest import mock

    from helper import daemon

    with _Stand().serve_here() as stand:
        sock = stand.connect()
        assert stand.ask(sock, {"cmd": "start", "socks_port": 10808,
                                "xray_path": stand.xray})["ok"] is True
        assert stand.wait_up(), "поддельный sing-box не поднялся"

        with mock.patch.object(daemon.Outbox, "start", autospec=True,
                               side_effect=RuntimeError("can't start new thread")):
            second = stand.connect()
            assert second.recv(1) == b"", "соединение не закрыто, peer не увидит EOF"

        # conn.close() в finally — последняя строчка, ПОСЛЕ проверки
        # SUPERVISOR.owner (см. serve_client в helper/daemon.py): раз EOF уже
        # виден, проверка владельца к этому моменту гарантированно отработала.
        assert stand.singbox_pids(), f"чужое соединение снесло активный туннель: {stand.singbox_pids()}"


@check
def test_install_singbox_does_not_drop_a_running_tunnel():
    """Меж-задачная находка (ревью Задачи 9, Important 2).

    install_singbox() в native/tun.py открывает СВОЁ соединение — отдельное
    от того, что держит активный туннель, — на один запрос, и закрывает его.
    Раньше serve_client() снимал ЛЮБОЙ поднятый туннель по факту обрыва СВОЕГО
    соединения, не спрашивая, чьё оно: воспроизводится вручную — туннель
    поднят, открыть второе соединение, спросить status, закрыть — сносило
    активный sing-box, а Tun.running навсегда оставался True (on_state(False)
    не приходил, потому что с точки зрения владеющего соединения ничего не
    случилось).

    Настоящую скачку sing-box (живой GitHub) не гоняем — запрещено условиями
    задачи. Бьём напрямую тем же протокольным паттерном, каким пользуется
    install_singbox(): открыть соединение, один запрос, закрыть — команда
    не важна, важен факт постороннего открытия-и-закрытия.
    """
    from unittest import mock

    from native import paths, tun
    from shared.models import Server

    with _Stand().serve_here() as stand:
        states: list[bool] = []
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True):
            t = tun.Tun(on_state=states.append)
            t.start(Server(address="127.0.0.1"), 10808)
            assert stand.wait_up(), "поддельный sing-box не поднялся"

            second = stand.connect()
            assert stand.ask(second, {"cmd": "status"})["ok"] is True
            second.close()

            time.sleep(0.5)   # дать демону время среагировать на обрыв, если бы среагировал
            assert stand.singbox_pids(), "постороннее соединение снесло активный туннель"
            assert t.running is True, "Tun решил, что туннель упал, хотя он жив"
            assert states == [True], f"on_state(False) не должен был прийти: {states}"

            t.stop()
            assert stand.wait_gone(), f"Tun.stop() не снял туннель: {stand.singbox_pids()}"
        assert states == [True, False], states


@check
def test_daemon_drops_tunnel_when_owning_connection_crashes_mid_serving():
    """Симметрично test_daemon_closes_socket_even_when_serving_falls_over_on_a_
    foreign_connection: там крах на ЧУЖОМ соединении туннель не трогает,
    здесь крах на СВОЁМ — обязан снять, как и любой другой обрыв владеющего
    соединения. Без этой проверки было бы легко "починить" Important 2 так,
    что заодно перестал бы работать и обычный краш-путь на собственном
    соединении, а мутационный прогон ревьюера такую регрессию не ловил.
    """
    from unittest import mock

    from helper import daemon

    with _Stand().serve_here() as stand:
        sock = stand.connect()
        assert stand.ask(sock, {"cmd": "start", "socks_port": 10808,
                                "xray_path": stand.xray})["ok"] is True
        assert stand.wait_up(), "поддельный sing-box не поднялся"

        with mock.patch.object(daemon, "handle_line", side_effect=RuntimeError("boom")):
            sock.sendall(b'{"cmd": "status"}\n')
            assert sock.recv(1) == b"", "соединение не закрыто после краха на своём же соединении"

        assert stand.wait_gone(), f"туннель пережил крах на владеющем соединении: {stand.singbox_pids()}"


@check
def test_daemon_sweeps_stubborn_orphan_at_start():
    """От SIGKILL по демону защиты нет — есть подметание при следующем старте.

    Сирота упрямая: на SIGTERM не уходит. pkill возвращается сразу после
    отправки сигнала, поэтому «послал и записал успех» здесь недостаточно —
    нужно дождаться смерти и добить SIGKILL.
    """
    from unittest import mock

    from helper import daemon

    with _Stand(_STUBBORN_SINGBOX) as stand:
        stand.spawn_orphan()
        with mock.patch.object(daemon, "BIN_DIR", stand.tmp / "bin"), \
             mock.patch.object(daemon, "RUN_DIR", stand.tmp / "run"), \
             mock.patch.object(daemon, "SWEEP_GRACE_SEC", 1):
            clean = daemon.kill_stale_singbox()
        assert not stand.singbox_pids(), "сирота пережила подметание"
        assert clean is True, "подметание отчиталось об успехе неправдиво"

        # Не смогли посмотреть — значит не знаем, значит не пускаем: гейт в
        # Supervisor.start опирается на этот ответ, и молчаливое «чисто» при
        # сломанном pgrep пустило бы второй sing-box поверх первого.
        with mock.patch.object(daemon, "_proc_tool", lambda args: None):
            assert daemon.kill_stale_singbox() is False, "сломанный pgrep трактуется как «чисто»"


@check
def test_daemon_caps_request_line():
    """Строка без перевода строки не должна расти в памяти root-процесса."""
    with _Stand().serve_here() as stand:
        sock = stand.connect()

        def flood():
            # Льём в отдельном потоке: демон оборвёт разговор на середине,
            # и sendall упрётся в закрытый сокет.
            with contextlib.suppress(OSError):
                sock.sendall(b"[" * (2 << 20))

        threading.Thread(target=flood, daemon=True).start()
        reply = stand.reply(sock)
        assert reply["ok"] is False, reply
        assert "длиннее допустимого" in reply["error"], reply


@check
def test_daemon_drops_logs_instead_of_stalling_singbox():
    """Клиент перестал читать сокет — это не повод останавливать sing-box.

    Логи ядра идут клиенту тем же соединением. Если писать прямо из потока,
    который читает stdout sing-box, встанет сначала он, потом переполнится
    труба, а потом и сам sing-box: поведение клиентского сокета управляло бы
    туннелем.
    """
    from helper.daemon import Outbox

    left, right = socket.socketpair()
    try:
        outbox = Outbox(left, maxsize=2)   # поток не запускаем: очередь никто не разбирает
        started = time.monotonic()
        for i in range(200):
            outbox.send_log({"log": f"строка {i}"})
        spent = time.monotonic() - started
        assert spent < 1.0, f"отправка задержалась на {spent:.1f} с — значит блокирует"
        assert outbox.dropped == 198, outbox.dropped
    finally:
        left.close()
        right.close()


@check
def test_daemon_never_drops_the_reply():
    """Логи выбрасывать можно, ответ на команду — нельзя.

    Потерянный ответ на start оставляет приложение в убеждении, что туннеля
    нет, пока весь трафик идёт в туннель: та же ложь про состояние, ради ухода
    от которой написан модуль. Здесь ответ кладётся в очередь, забитую логами.
    """
    from helper.daemon import Outbox

    left, right = socket.socketpair()
    try:
        outbox = Outbox(left, maxsize=8)
        for i in range(1000):
            outbox.send_log({"log": f"строка {i}"})
        outbox.send({"ok": True, "running": True})
        outbox.start()

        right.settimeout(5)
        buf = b""
        seen = 0
        while True:
            try:
                chunk = right.recv(1 << 16)
            except OSError as e:
                raise AssertionError(f"ответ не дошёл, вычитано кадров: {seen} ({e})") from e
            if not chunk:
                raise AssertionError(f"ответ не дошёл, вычитано кадров: {seen}")
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                seen += 1
                if "ok" in json.loads(line.decode()):
                    return
    finally:
        left.close()
        right.close()


@check
def test_daemon_outbox_has_a_ceiling_even_for_replies():
    """Ответы не выбрасываем — но и расти без границы очередь не должна.

    Прежняя очередь при переполнении просто выбрасывала и не росла никогда.
    Разведя ответы и логи, мы дали ответам право занимать место — а место в
    очереди это память root-процесса. Если клиент не читает, а логов, за счёт
    которых освобождают место, в очереди нет, каждый следующий кадр ещё и
    обходил всю очередь под локом: время на кадр росло линейно, а очередь —
    вместе с потоком запросов.
    """
    from helper.daemon import Outbox

    left, right = socket.socketpair()
    try:
        outbox = Outbox(left, maxsize=8)     # писателя не запускаем: никто не разбирает
        started = time.monotonic()
        for i in range(8000):
            outbox.send({"ok": True, "n": i})
        spent = time.monotonic() - started

        assert outbox.pending() <= 8 * 4, f"очередь выросла до {outbox.pending()} кадров"
        assert spent < 1.0, f"8000 ответов заняли {spent:.2f} с — очередь деградирует"

        # Клиенту, который не читает ответы, разговор закрывают: он завис, и
        # снятие туннеля по обрыву для него — правильный исход.
        right.settimeout(5)
        assert right.recv(64) == b"", "соединение с зависшим клиентом не закрыто"
    finally:
        left.close()
        right.close()


@check
def test_daemon_stop_reply_tells_the_truth():
    """Ответ на stop не смеет говорить «выключено», пока маршруты держатся.

    stop() имеет право вернуться с живым процессом, если тот пережил SIGKILL,
    — значит зашитое {"running": False} в ответе врёт именно в тот момент,
    когда правда важнее всего.
    """
    from unittest import mock

    from helper import daemon

    with _Stand() as stand:
        proc = subprocess.Popen([str(stand.tmp / "bin" / "sing-box")])
        try:
            sup = daemon.Supervisor()
            sup.proc = proc
            with mock.patch.object(daemon, "SUPERVISOR", sup), \
                 mock.patch.object(daemon, "STOP_GRACE_SEC", 1), \
                 mock.patch.object(daemon, "KILL_GRACE_SEC", 1), \
                 mock.patch.object(proc, "terminate", lambda: None), \
                 mock.patch.object(proc, "kill", lambda: None), \
                 mock.patch.object(proc, "wait",
                                   side_effect=subprocess.TimeoutExpired("sing-box", 1)):
                reply = daemon.handle_line('{"cmd": "stop"}', {})
            assert reply["running"] is True, reply
            assert reply["ok"] is False, reply
        finally:
            proc.kill()
            proc.wait()


@check
def test_daemon_refuses_second_singbox_while_first_is_alive():
    """Прежний не снялся — второй поверх него не поднимаем: подерутся за маршрут."""
    from unittest import mock

    from helper import daemon

    with _Stand().serve_here() as stand:
        sock = stand.connect()
        start = {"cmd": "start", "socks_port": 10808, "xray_path": stand.xray}
        assert stand.ask(sock, start)["ok"] is True          # положительный контроль
        assert stand.wait_up(), "поддельный sing-box не поднялся"

        proc = daemon.SUPERVISOR.proc
        assert proc is not None
        with mock.patch.object(proc, "terminate", lambda: None), \
             mock.patch.object(proc, "kill", lambda: None), \
             mock.patch.object(proc, "wait",
                               side_effect=subprocess.TimeoutExpired("sing-box", 1)), \
             mock.patch.object(daemon, "KILL_GRACE_SEC", 1):
            reply = stand.ask(sock, start)
        assert reply["ok"] is False, reply
        assert "не снялся" in reply["error"], reply
        assert len(stand.singbox_pids()) == 1, f"поднял второй: {stand.singbox_pids()}"


@check
def test_daemon_refuses_to_start_over_a_stale_singbox():
    """Осиротевший sing-box не снялся — поднимать туннель поверх него нельзя."""
    from unittest import mock

    from helper import daemon

    with _Stand().serve_here() as stand:
        sock = stand.connect()
        start = {"cmd": "start", "socks_port": 10808, "xray_path": stand.xray}

        with mock.patch.object(daemon, "kill_stale_singbox", lambda: False):
            reply = stand.ask(sock, start)
        assert reply["ok"] is False, reply
        assert "осиротевший" in reply["error"], reply
        assert not stand.singbox_pids(), "поднял туннель поверх чужого sing-box"

        # Положительный контроль: без сироты тот же самый запрос проходит.
        assert stand.ask(sock, start)["ok"] is True


@check
def test_daemon_keeps_handle_on_unkillable_singbox():
    """Не убедился в смерти — не отпускай ручку.

    Раньше self.proc обнулялся первым делом, а неудача wait() глоталась: демон
    терял живой sing-box, running врал False, и следующий start поднял бы
    второй рядом с первым.
    """
    from unittest import mock

    from helper import daemon

    with _Stand() as stand:
        proc = subprocess.Popen([str(stand.tmp / "bin" / "sing-box")])
        try:
            sup = daemon.Supervisor()
            sup.proc = proc
            # Процесс в непрерываемом сне: сигналы уходят, wait не дожидается.
            with mock.patch.object(proc, "terminate", lambda: None), \
                 mock.patch.object(proc, "kill", lambda: None), \
                 mock.patch.object(proc, "wait",
                                   side_effect=subprocess.TimeoutExpired("sing-box", 1)), \
                 mock.patch.object(daemon, "STOP_GRACE_SEC", 1), \
                 mock.patch.object(daemon, "KILL_GRACE_SEC", 1):
                sup.stop()
            assert sup.proc is proc, "ручку на живом sing-box потеряли"
            assert sup.running is True, "running врёт, что туннеля нет"
        finally:
            proc.kill()
            proc.wait()


@check
def test_daemon_refuses_second_instance():
    """flock не даёт второму демону встать поверх первого.

    Второй `sudo python run.py --helper` при живом launchd-демоне без этой
    защиты снёс бы РАБОЧИЙ sing-box первого (kill_stale_singbox бьёт по всей
    командной строке) и перехватил бы его сокет. Замок должен отказать до
    того, как второй экземпляр успеет тронуть то и другое.
    """
    import os

    from helper import daemon

    with tempfile.TemporaryDirectory() as td:
        lock_path = Path(td) / "helper.lock"
        daemon._acquire_singleton_lock(lock_path)
        try:
            try:
                daemon._acquire_singleton_lock(lock_path)
                raise AssertionError("второй экземпляр получил тот же замок")
            except RuntimeError as e:
                assert "другой экземпляр" in str(e), e
        finally:
            if daemon._lock_fd is not None:
                os.close(daemon._lock_fd)
                daemon._lock_fd = None


@check
def test_plist_points_at_this_build():
    """В plist должен попасть путь к тому, что реально запущено, а не заглушка."""
    import plistlib

    from helper.install import plist_text

    data = plistlib.loads(plist_text().encode())
    assert data["Label"] == "com.scvpn.helper", data["Label"]
    assert data["KeepAlive"] is True, data
    assert data["RunAtLoad"] is True, data
    args = data["ProgramArguments"]
    assert args[-1] == "--helper", args
    assert all(a.startswith("/") for a in args[:-1]), args


@check
def test_installed_reflects_reality():
    from pathlib import Path

    from helper.install import installed

    assert installed() == Path("/Library/LaunchDaemons/com.scvpn.helper.plist").exists()


@check
def test_installed_detects_stale_plist_after_move():
    """installed() сравнивает содержимое, а не факт существования файла.

    ProgramArguments внутри plist — абсолютный путь к программе. После
    переезда .app или перехода исходники<->сборка старый plist остаётся на
    диске, но указывает в никуда: launchd с KeepAlive вечно перезапускал бы
    несуществующий путь, а installed() молча врал бы True. Файл существует —
    значит installed() старой версии сказал бы True и на мёртвом plist.
    """
    from unittest import mock

    from helper import install
    from native import paths

    with tempfile.TemporaryDirectory() as td:
        stale = Path(td) / "com.scvpn.helper.plist"
        with mock.patch.object(paths, "HELPER_PLIST", stale):
            # Файла ещё нет вовсе.
            assert install.installed() is False

            # Файл есть, но с чужим/устаревшим содержимым — не тот plist,
            # который выдал бы plist_text() сейчас.
            stale.write_text("не тот plist", encoding="utf-8")
            assert install.installed() is False, "устаревший plist сошёл за поставленный"

            # Содержимое совпадает с тем, что даёт текущая сборка — теперь
            # действительно поставлено.
            stale.write_text(install.plist_text(), encoding="utf-8")
            assert install.installed() is True


@check
def test_program_arguments_use_bundle_exe_when_frozen():
    """В собранном .app демон запускает сам себя, а не системный python."""
    from unittest import mock

    from helper.install import program_arguments
    from native import paths

    with mock.patch.object(paths, "FROZEN", True):
        args = program_arguments()
    assert args == [sys.executable, "--helper"], args


@check
def test_plist_exit_timeout_covers_worst_case_stop():
    """ExitTimeOut обязан реально перекрывать худший случай снятия.

    Расчёт живёт в комментарии install.py, но комментарий никто не гоняет.
    Пересчитываем худший случай по фактическим константам daemon.py: stop()
    уже поднятого sing-box внутри start() (STOP_GRACE_SEC+KILL_GRACE_SEC) +
    kill_stale_singbox под тем же локом (2*SWEEP_GRACE_SEC) + ещё один stop()
    основным потоком уже после освобождения лока (снова
    STOP_GRACE_SEC+KILL_GRACE_SEC). Если кто-то сдвинет grace-константы в
    daemon.py и забудет про ExitTimeOut в install.py, эта проверка упадёт.
    """
    import plistlib

    from helper import daemon, install

    worst_case = (
        (daemon.STOP_GRACE_SEC + daemon.KILL_GRACE_SEC)
        + 2 * daemon.SWEEP_GRACE_SEC
        + (daemon.STOP_GRACE_SEC + daemon.KILL_GRACE_SEC)
    )
    data = plistlib.loads(install.plist_text().encode())
    assert data["ExitTimeOut"] > worst_case, (data["ExitTimeOut"], worst_case)
    assert data["ExitTimeOut"] > 20, "не перекрывает дефолт launchd (20 c)"


@check
def test_daemon_checks_lock_before_sweeping():
    """Замок обязан браться раньше kill_stale_singbox, а не просто существовать.

    Мутанты «убрать вызов _acquire_singleton_lock из main() целиком» и
    «продублировать замок ПОСЛЕ kill_stale_singbox» проходили все прежние
    проверки: свойство порядка нигде не было закреплено явно, только сам факт
    работы замка в вакууме. Если замок не занят до подметания, второй демон
    успевает снести РАБОЧИЙ sing-box первого раньше, чем откажется стартовать.
    """
    from unittest import mock

    from helper import daemon

    calls = []
    with mock.patch.object(daemon.os, "geteuid", lambda: 0), \
         mock.patch.object(daemon, "_acquire_singleton_lock",
                            side_effect=RuntimeError("занято")), \
         mock.patch.object(daemon, "kill_stale_singbox",
                            lambda: calls.append("sweep") or True):
        assert daemon.main() == 1
    assert calls == [], "подметание чужого sing-box случилось до проверки замка"


@check
def test_osascript_literal_survives_non_ascii_and_special_chars():
    """_as_literal, не json.dumps: AppleScript не понимает \\uXXXX.

    json.dumps экранирует не-ASCII в `\\uXXXX` — валидный JSON, но AppleScript
    такую escape-последовательность не компилирует вовсе. Промпт демона на
    русском, поэтому install()/uninstall() падали на КАЖДОЙ машине, ещё не
    дойдя до диалога пароля. Гоняем через настоящий osascript (без
    `with administrator privileges` — только компиляция строкового литерала,
    привилегий не требует) ровно те случаи, что реально встречаются:
    русский промпт и путь с кириллицей, плюс акценты/CJK/эмодзи и кавычки.
    """
    from helper.install import _as_literal

    roundtrip_cases = [
        "SCVPN устанавливает системный компонент для TUN-режима",
        "/Users/оператор/Library/Application Support/SCVPN/com.scvpn.helper.plist",
        "café — 日本語 — emoji 🚀",
        'quo"te and back\\slash',
    ]
    for s in roundtrip_cases:
        r = subprocess.run(["osascript", "-e", f"return {_as_literal(s)}"],
                            capture_output=True, text=True)
        assert r.returncode == 0, (s, r.stderr)
        assert r.stdout.strip("\n") == s, (s, r.stdout, r.stderr)

    # Управляющие символы обязаны хотя бы скомпилироваться и выполниться;
    # байт-в-байт со stdout их не сверяем — newline/tab/CR уходят в вывод как
    # есть, а не как экранированная последовательность.
    for s in ["line1\nline2", "a\tb\tc", "cr\rlf"]:
        r = subprocess.run(["osascript", "-e", f"return {_as_literal(s)}"],
                            capture_output=True, text=True)
        assert r.returncode == 0, (s, r.stderr)


@check
def test_osascript_command_actually_uses_as_literal():
    """_osascript обязан реально пользоваться _as_literal, не просто иметь её рядом.

    Предыдущая проверка гоняет _as_literal саму по себе — этого мало: откат
    _osascript назад на json.dumps (тот самый Critical, из-за которого
    install()/uninstall() не работали ни на одной машине) прошёл бы её,
    ничего не заметив, потому что вызывается не та функция. Проверяем СОБРАННУЮ
    _do_shell_script_command, тем же кодом, которым пользуются install() и
    uninstall(), настоящим osascript. `with administrator privileges` из
    текста вырезаем перед прогоном: `do shell script ... with prompt ...` без
    него компилируется и выполняется как обычный пользователь без всякого
    диалога (проверено отдельно) — значит здесь пароль ни разу не спросится.
    """
    from helper.install import _do_shell_script_command

    prompt = "SCVPN устанавливает системный компонент для TUN-режима"
    cmd = _do_shell_script_command("true", prompt)
    assert "with administrator privileges" in cmd, cmd
    assert "\\u" not in cmd, f"похоже на json.dumps: не-ASCII ушёл в \\uXXXX: {cmd}"

    probe = cmd.replace("with administrator privileges", "")
    r = subprocess.run(["osascript", "-e", probe], capture_output=True, text=True)
    assert r.returncode == 0, (cmd, r.stderr)


@check
def test_installed_handles_corrupted_plist():
    """installed() обязан вернуть False при испорченном plist, не упасть.

    Файл может быть испорчен в середине многобайтовой UTF-8-последовательности
    (atомарность printf, обрыв записи) или быть бинарным plist (результат
    plutil -convert binary1). В обоих случаях read_text(..., encoding="utf-8")
    кинет UnicodeDecodeError — подкласс ValueError, а не OSError. Без правильного
    перехвата обеих исключений installed() упадёт с необработанным исключением
    вместо аккуратного False.
    """
    from unittest import mock

    from helper import install
    from native import paths

    with tempfile.TemporaryDirectory() as td:
        corrupted = Path(td) / "com.scvpn.helper.plist"
        with mock.patch.object(paths, "HELPER_PLIST", corrupted):
            # Невалидные UTF-8 байты — например, вторая половина многобайтовой
            # последовательности без первой (такое может быть при обрыве записи)
            # или header бинарного plist.
            corrupted.write_bytes(b'bplist00\xd1\x01\x02\xff\xfe')
            assert install.installed() is False, "установщик упал на испорченном plist"


@check
def test_tun_contract_matches_windows():
    """Точечная проверка native.tun ЭТОЙ платформы (не Windows, вопреки имени
    — оставлено для обратной совместимости с прежними правками; настоящая
    сверка обеих платформ по фактическому набору имён, которые shared/
    реально импортирует, — test_native_contract_covers_both_platforms ниже).
    """
    from native import tun

    for name in ("SPLIT_OFF", "SPLIT_EXCLUDE", "SPLIT_INCLUDE", "PRIVILEGE_QUESTION",
                 "privileged", "acquire_privilege", "cleanup_stray", "Tun"):
        assert hasattr(tun, name), f"в native.tun нет {name}"
    t = tun.Tun()
    assert t.running is False


def _native_imports_required_by_shared() -> set[tuple[str, str]]:
    """(модуль, имя) — всё, что desktop/shared/ реально берёт из native/.

    Разбираем AST, а не грепаем текст: так подхватывается многострочный
    `from native.tun import (...)`, а любой будущий новый импорт из native/
    попадает в контракт сам, без ручного обновления списка имён.

    Форм обращения к native/ две, и собирать надо обе.

    1) `from native.tun import Tun` — имя названо прямо в импорте.
    2) `from native import paths` и следом `paths.icon_file()` — импорт не
       называет ни одного имени ВНУТРИ модуля, поэтому по одним ImportFrom
       контракт для paths.* и sysproxy.* сводился к «модуль импортируется»,
       а 15 обращений к paths.* и 9 к sysproxy.* не проверялись вовсе.
       Доказано мутацией: удаление icon_file() из Windows/native/paths.py
       оставляло обе контрактные проверки зелёными, хотя run_app() зовёт
       paths.icon_file() и на Windows свалился бы AttributeError до создания
       окна — ровно тот класс отказа, ради которого проверка и писалась.
       Поэтому для имён, связанных такой формой импорта, добираем ещё и
       ast.Attribute: `<имя>.<атрибут>` в том же файле.
    """
    import ast

    shared_dir = Path(__file__).resolve().parent.parent / "shared"
    required: set[tuple[str, str]] = set()
    for py in shared_dir.rglob("*.py"):
        if "__pycache__" in py.parts:
            continue
        tree = ast.parse(py.read_text(encoding="utf-8"), filename=str(py))
        # Локальное имя -> подмодуль native, который за ним стоит.
        bound: dict[str, str] = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module and (
                node.module == "native" or node.module.startswith("native.")
            ):
                for alias in node.names:
                    required.add((node.module, alias.name))
                    if node.module == "native":
                        bound[alias.asname or alias.name] = f"native.{alias.name}"
        if not bound:
            continue
        for node in ast.walk(tree):
            if (
                isinstance(node, ast.Attribute)
                and isinstance(node.value, ast.Name)
                and node.value.id in bound
            ):
                required.add((bound[node.value.id], node.attr))
    return required


def _missing_native_names(platform_dir: Path, required: set[tuple[str, str]]) -> list[str]:
    """"модуль.имя" из required, которых не хватает в native/ этой платформы.

    Обе платформы называют свой пакет одинаково ("native") — импортировать
    оба в одном процессе значит столкнуть их в sys.modules. Гоняем отдельным
    интерпретатором с sys.path, указывающим строго на одну платформу.

    Смотрим на ФАКТИЧЕСКУЮ доступность имени через getattr после настоящего
    import, а не на текст файла: SPLIT_OFF/SPLIT_EXCLUDE/SPLIT_INCLUDE в
    MacOS/native/tun.py не определены, а реэкспортированы из
    helper.config — grep по определению их бы не нашёл.
    """
    pairs = sorted(required)
    # "from native import X" — особый случай: X может быть подмодулем
    # (native/X.py, как paths и sysproxy) ИЛИ именем, определённым прямо в
    # native/__init__.py. Питон на этот синтаксис сперва пробует
    # импортировать native.X как подмодуль — простой hasattr() после голого
    # "import native" этого не воспроизводит (submodule не становится
    # атрибутом пакета сам по себе, пока его явно не импортировали), и
    # ловил бы paths/sysproxy как отсутствующие на обеих платформах.
    script = f"""
import importlib, json, sys
sys.path.insert(0, {str(platform_dir)!r})
sys.path.insert(0, {str(platform_dir.parent)!r})
pairs = {pairs!r}
missing = []
mod_cache = {{}}
for module, name in pairs:
    if module == "native":
        try:
            importlib.import_module(f"native.{{name}}")
            continue
        except ImportError:
            pass
    if module not in mod_cache:
        try:
            mod_cache[module] = importlib.import_module(module)
        except Exception as e:
            mod_cache[module] = e
    m = mod_cache[module]
    if isinstance(m, Exception):
        missing.append(f"{{module}}.{{name}} (модуль не импортировался: {{type(m).__name__}}: {{m}})")
        continue
    if not hasattr(m, name):
        missing.append(f"{{module}}.{{name}}")
print(json.dumps(missing))
"""
    r = subprocess.run(
        [sys.executable, "-c", script], capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        raise AssertionError(
            f"проверка контракта для {platform_dir} упала целиком "
            f"(returncode={r.returncode}): {r.stderr}"
        )
    return json.loads(r.stdout)


@check
def test_native_contract_covers_both_platforms():
    """Ревью Задачи 11, Critical Раунда 2: main_window.py тянул
    last_privilege_error из native.tun на уровне модуля, а в Windows/native/
    tun.py такого имени не было — ImportError при импорте главного окна,
    до создания чего бы то ни было. python3 -m compileall это не ловит
    (импорт разрешается в рантайме), самопроверка тогда прошла.

    Эта проверка разбирает АСТ desktop/shared/ на предмет "from native
    import X" / "from native.<модуль> import X, Y" — то есть строит контракт
    из того, что shared/ реально использует, а не из зашитого вручную
    списка, — и сверяет каждое имя против MacOS/native/ и Windows/native/
    отдельными интерпретаторами (см. _missing_native_names). Следующая
    такая правка упадёт здесь, а не на машине пользователя.

    Ревью перед слиянием, Critical 2: одних импортов мало — модули, взятые
    целиком (`from native import paths` / `sysproxy`), проверялись только на
    «импортируется», а обращения к их атрибутам не проверялись никак. Теперь
    в контракт входят и они, см. _native_imports_required_by_shared.
    """
    required = _native_imports_required_by_shared()
    assert required, "не нашлось ни одного импорта из native/ в shared/ — парсер AST сломан"
    assert ("native.tun", "last_privilege_error") in required, (
        "контроль на контроль: last_privilege_error должен быть виден парсеру"
    )
    # Второй контроль на контроль — уже для атрибутов модуля, взятого целиком:
    # run_app() зовёт paths.icon_file(), disconnect_vpn() — sysproxy.disable().
    for pair in (("native.paths", "icon_file"), ("native.sysproxy", "disable")):
        assert pair in required, (
            f"контроль на контроль: {pair[0]}.{pair[1]} должен быть виден парсеру"
        )

    macos_dir = Path(__file__).resolve().parent
    windows_dir = macos_dir.parent / "Windows"
    assert windows_dir.is_dir(), f"не нашёл {windows_dir}"

    macos_missing = _missing_native_names(macos_dir, required)
    windows_missing = _missing_native_names(windows_dir, required)

    assert not macos_missing, f"MacOS/native не хватает: {macos_missing}"
    assert not windows_missing, f"Windows/native не хватает: {windows_missing}"


@check
def test_tun_stop_returns_bool_on_both_platforms():
    """Возврат Tun.stop() — часть контракта native, а не деталь macOS.

    По нему shared/ui/main_window.py решает, показывать «Отключено» или
    «Туннель не снят» (Important 1). Если бы на Windows stop() остался
    возвращать None, `if not tun_down` срабатывал бы на КАЖДОМ отключении и
    Windows-пользователь получал бы ложную тревогу при каждом штатном
    выключении TUN. Проверка контракта по именам этого не ловит: имя stop
    есть на обеих платформах.
    """
    macos_dir = Path(__file__).resolve().parent
    windows_dir = macos_dir.parent / "Windows"
    for platform_dir in (macos_dir, windows_dir):
        script = f"""
import inspect, sys
sys.path.insert(0, {str(platform_dir)!r})
sys.path.insert(0, {str(platform_dir.parent)!r})
from native import tun
print(inspect.signature(tun.Tun.stop).return_annotation)
"""
        r = subprocess.run(
            [sys.executable, "-c", script], capture_output=True, text=True, timeout=30,
        )
        assert r.returncode == 0, f"{platform_dir}: {r.stderr}"
        got = r.stdout.strip()
        assert got in ("bool", "<class 'bool'>"), f"{platform_dir}: Tun.stop() -> {got}"


# Тело Windows-версии Tun.stop() — не про сокеты и не про UAC, а про
# subprocess: terminate, wait, poll. Всё это работает и здесь, поэтому её
# поведение можно проверить по-настоящему, а не на слово. Отдельным
# интерпретатором — иначе Windows/native столкнулся бы в sys.modules с
# MacOS/native под тем же именем (та же причина, что и в _missing_native_names).
_WINDOWS_STOP_SRC = """
import subprocess, sys, tempfile
from pathlib import Path
from unittest import mock
sys.path.insert(0, {windows!r})
sys.path.insert(0, {root!r})
from native import paths, tun

def make(alive_forever):
    t = tun.Tun(on_log=lambda s: None, on_state=states.append)
    # DEVNULL обязателен: этот процесс — внук проверки, и унаследованную трубу
    # он держал бы открытой, пока жив, а проверка ждала бы по ней EOF.
    t._proc = subprocess.Popen(["/bin/sh", "-c", "while :; do sleep 1; done"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if alive_forever:
        # sing-box, переживший и SIGTERM, и SIGKILL: сигналы не доходят.
        t._proc.terminate = lambda: None
        t._proc.kill = lambda: None
        t._proc.wait = lambda timeout=None: (_ for _ in ()).throw(
            subprocess.TimeoutExpired("sing-box", 1))
    return t

with mock.patch.object(paths, "DATA_DIR", Path(tempfile.mkdtemp())):
    states = []
    t = make(False)
    proc = t._proc
    assert t.stop() is True, "штатная остановка обязана вернуть True"
    assert proc.poll() is not None, "процесс пережил штатную остановку"
    assert states == [False], states

    states = []
    t = make(True)
    proc = t._proc
    assert t.stop() is False, "процесс жив — stop() не смеет рапортовать успех"
    assert t.running is True, "ручку на живом процессе отпускать нельзя"
    assert states == [], f"«отключено» показывать было нельзя: {{states}}"
    # Убираем за собой мимо подменённых на объекте terminate/kill/wait.
    subprocess.Popen.kill(proc)
    subprocess.Popen.wait(proc)
print("OK")
"""


@check
def test_windows_tun_stop_tells_the_truth_too():
    """Возврат Tun.stop() — общий контракт, и Windows-половина обязана его
    соблюдать не только по аннотации: по нему main_window решает, показывать
    «Отключено» или «Туннель не снят». Если бы Windows-версия возвращала
    успех вслепую (или None), пользователь Windows получал бы либо ту же
    ложь о состоянии, либо ложную тревогу на каждом штатном отключении.
    """
    macos_dir = Path(__file__).resolve().parent
    src = _WINDOWS_STOP_SRC.format(
        windows=str(macos_dir.parent / "Windows"), root=str(macos_dir.parent),
    )
    r = subprocess.run([sys.executable, "-c", src], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0 and r.stdout.strip().endswith("OK"), (
        f"Windows-версия Tun.stop() не прошла: {r.stdout}\n{r.stderr}"
    )


@check
def test_connection_close_shuts_down_before_closing_socket():
    """shutdown обязан идти РАНЬШЕ close(): иначе поток, заблокированный в
    recv (Tun._read_logs / stream), не гарантированно проснётся сразу —
    см. комментарий в _Connection.close() и тот же приём в Outbox._overflow
    демона. Порядок проверяем напрямую, без реального сокета: подставляем
    вместо sock/_file объекты, которые просто запоминают порядок вызовов.

    Нарочно поставлена здесь, а не рядом с остальными проверками Tun против
    настоящего демона: она — единственная страховка от мутации «убрали
    shutdown», а без shutdown реальные round-trip-проверки ниже по файлу
    виснут насмерть (внутренний лок io.BufferedReader, который держит
    заблокированный на чтении поток). Если сторож стоит ПОСЛЕ них, раннер
    до него просто не доходит — даже с внешним таймаутом на каждую
    проверку это лишние минуты ожидания вместо мгновенного FAIL по существу.
    """
    from unittest import mock

    from native.tun import _Connection

    calls: list[str] = []
    conn = object.__new__(_Connection)  # без __init__: настоящий connect() тут не нужен
    conn.sock = mock.MagicMock()
    conn.sock.shutdown.side_effect = lambda *a: calls.append("shutdown")
    conn.sock.close.side_effect = lambda *a: calls.append("sock.close")
    conn._file = mock.MagicMock()
    conn._file.close.side_effect = lambda: calls.append("file.close")

    conn.close()

    assert calls and calls[0] == "shutdown", f"shutdown не первым: {calls}"
    assert "sock.close" in calls, calls


@check
def test_resolve_ips_passes_through_literals():
    from native.tun import resolve_ips

    assert resolve_ips("1.2.3.4") == ["1.2.3.4"]
    assert resolve_ips("не-существует.invalid") == []


@check
def test_cleanup_stray_survives_missing_pid_file():
    from native import paths
    from native.tun import cleanup_stray

    (paths.DATA_DIR / "xray.pid").unlink(missing_ok=True)
    assert cleanup_stray(lambda s: None) is False


# ----------------------------------------------------------------------
# native.tun.Tun против настоящего демона (тот же стенд _Stand, что и выше)
# ----------------------------------------------------------------------
_TUN_CLIENT_SRC = """
import sys, time
sys.path.insert(0, {macos!r})
sys.path.insert(0, {root!r})
from pathlib import Path
from unittest import mock
from native import paths, tun
from shared.models import Server

with mock.patch.object(paths, "HELPER_SOCKET", Path({sock!r})), \\
     mock.patch.object(paths, "BIN_DIR", Path({bindir!r})), \\
     mock.patch.object(tun, "helper_installed", lambda: True):
    t = tun.Tun(on_log=lambda s: print("LOG " + s, flush=True))
    t.start(Server(address="127.0.0.1"), 10808)
    print("READY", flush=True)
    time.sleep(300)
"""

# Поддельный sing-box, который вдобавок эхает строку в stdout — так заодно
# проверяется, что лог доходит от процесса до колбэка Tun.on_log.
_SINGBOX_WITH_LOG = "#!/bin/sh\necho $$ > {ready}\necho 'привет из sing-box'\nwhile :; do sleep 1; done\n"


@check
def test_tun_start_stop_round_trip_against_real_daemon():
    """native.tun.Tun целиком: настоящий демон (serve_here), настоящий сокет.

    Это положительный контроль для соседней проверки обрыва: start обязан
    поднять процесс и дать True, stop — снять его и дать False, а лог
    поддельного sing-box обязан дойти до Tun.on_log.
    """
    from unittest import mock

    from native import paths, tun
    from shared.models import Server

    with _Stand(_SINGBOX_WITH_LOG).serve_here() as stand:
        logs: list[str] = []
        states: list[bool] = []
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True):
            t = tun.Tun(on_log=logs.append, on_state=states.append)
            t.start(Server(address="127.0.0.1"), 10808)
            assert t.running is True
            assert stand.wait_up(), "поддельный sing-box не поднялся"

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not any("привет из sing-box" in s for s in logs):
                time.sleep(0.05)
            assert any("привет из sing-box" in s for s in logs), f"лог sing-box не дошёл до Tun: {logs}"

            assert t.stop() is True, "туннель снят — stop() обязан это подтвердить"
            assert t.running is False
            assert stand.wait_gone(), f"sing-box пережил Tun.stop(): {stand.singbox_pids()}"
        assert states == [True, False], states


@check
def test_tun_stop_reports_tunnel_that_survived_the_stop():
    """Ревью перед слиянием, Important 1 — шов между Задачами 7 и 9.

    Задача 7 сделала ответ демона на stop правдивым: {"ok": not running,
    "running": running} — потому что stop() имеет право вернуться с живым
    процессом, если тот пережил SIGKILL (test_daemon_stop_reply_tells_the_
    truth). Задача 9 сделала Tun.stop() fire-and-forget: команду послал,
    сокет закрыл, ответ не прочитал никто, следом безусловный on_state(False).
    Итог: ровно в том случае, ради которого правду добывали — sing-box жив,
    utun поднят, маршруты держатся — интерфейс говорил «Отключено».

    Здесь всё настоящее: демон в этом же процессе, сокет, поток логов, кадр
    ответа. Заглушена только Supervisor.stop — так «sing-box пережил
    остановку» воспроизводится, ничего не убивая по-настоящему и не требуя
    root (тот же приём, что и в проверке правдивости ответа).
    """
    from unittest import mock

    from helper import daemon
    from native import paths, tun
    from shared.models import Server

    with _Stand().serve_here() as stand:
        logs: list[str] = []
        states: list[bool] = []
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True):
            t = tun.Tun(on_log=logs.append, on_state=states.append)
            t.start(Server(address="127.0.0.1"), 10808)
            assert stand.wait_up(), "поддельный sing-box не поднялся"

            with mock.patch.object(daemon.SUPERVISOR, "stop", lambda: None):
                down = t.stop()

            assert down is False, "демон ответил, что sing-box жив, — stop() соврал"
            assert t.running is True, "Tun считает туннель снятым, а он поднят"
            assert states == [True], f"«отключено» показывать было нельзя: {states}"
            assert any("ТРЕВОГА" in s for s in logs), logs


@check
def test_tun_connection_loss_drops_tunnel_without_stop():
    """Главное свойство со стороны клиента: обрыв соединения без команды stop
    всё равно снимает туннель. Симулируем крах приложения: клиент на
    native.tun.Tun поднят в отдельном процессе и убит kill() — stop() он
    позвать не успел, значит туннель обязан снять именно обрыв соединения.
    """
    with _Stand().serve_here() as stand:
        src = _TUN_CLIENT_SRC.format(
            macos=str(Path(__file__).resolve().parent),
            root=str(Path(__file__).resolve().parent.parent),
            sock=stand.sock_path, bindir=str(stand.tmp),
        )
        client = subprocess.Popen([sys.executable, "-c", src], stdout=subprocess.PIPE, text=True)
        stand._procs.append(client)
        # Клиент сперва печатает свои [tun]-логи (through on_log), и только
        # потом READY — поэтому дожидаемся именно её, а не первой строки.
        for _ in range(50):
            line = client.stdout.readline()
            assert line, "клиент не поднял туннель (процесс завершился раньше READY)"
            if line.strip() == "READY":
                break
        else:
            raise AssertionError("клиент не поднял туннель (READY не дождались)")
        assert stand.wait_up(), "поддельный sing-box не поднялся"

        client.kill()          # ни stop(), ни штатное закрытие — чистый крах
        client.wait()
        assert stand.wait_gone(), f"sing-box пережил смерть клиента Tun: {stand.singbox_pids()}"


@check
def test_tun_stop_command_alone_drops_tunnel_when_connection_stays_open():
    """Симметрично test_tun_connection_loss_drops_tunnel_without_stop: два
    независимых способа снять туннель обязаны работать и ПО ОДНОМУ. Здесь —
    команда stop без обрыва соединения: _Connection.close() глушим, чтобы
    закрытие соединения не подмешалось к результату и туннель мог упасть
    только от того, что демон обработал команду.
    """
    from unittest import mock

    from native import paths, tun
    from shared.models import Server

    with _Stand().serve_here() as stand:
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True), \
             mock.patch.object(tun._Connection, "close", lambda self: None):
            t = tun.Tun()
            t.start(Server(address="127.0.0.1"), 10808)
            assert stand.wait_up(), "поддельный sing-box не поднялся"

            # Держим _Connection живым сами. Иначе после stop() поток
            # _read_logs рано или поздно оборвёт свой блокирующий read (см.
            # send(): settimeout трогает общий с ним сокет — отдельный,
            # уже отложенный Minor) и выйдет, роняя последнюю ссылку на
            # _Connection — тогда объект соберёт обычный рефкаунт (не
            # цикличный GC, gc.disable() тут не спасёт) и закроет сокет сам
            # в __del__. Тест тогда проверял бы случайную уборку мусора, а
            # не команду stop. Держим ссылку, чтобы этот путь был отрезан.
            held = t._conn

            t.stop()
            try:
                assert stand.wait_gone(), (
                    "команда stop одна (соединение намеренно не закрыто) не сняла туннель"
                )
            finally:
                del held


@check
def test_tun_stop_closes_connection_even_when_command_cannot_be_sent():
    """Симметрично предыдущей: если отправка команды stop заглушена
    (_Connection.send — no-op), закрытие соединения внутри Tun.stop() обязано
    снять туннель само по себе — это и есть вторая независимая гарантия."""
    from unittest import mock

    from native import paths, tun
    from shared.models import Server

    with _Stand().serve_here() as stand:
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True), \
             mock.patch.object(tun._Connection, "send", lambda self, *a, **k: None), \
             mock.patch.object(tun, "STOP_REPLY_TIMEOUT_SEC", 1.0):
            # Команда заглушена — значит ответа на неё не будет никогда, и
            # stop() честно отстоит своё ожидание целиком. Настоящие 12 секунд
            # тут ничего не проверяют, кроме терпения: укорачиваем.
            t = tun.Tun()
            t.start(Server(address="127.0.0.1"), 10808)
            assert stand.wait_up(), "поддельный sing-box не поднялся"

            assert t.stop() is True, "ответа нет — считаем снятым, снимет обрыв соединения"
            assert stand.wait_gone(), (
                "закрытие соединения одно (команда stop заглушена) не сняло туннель"
            )


@check
def test_tun_reports_disconnect_when_singbox_dies_on_its_own():
    """Задача 11, п.3: sing-box может умереть сам — упасть, или его снимет
    другой клиент, — и демон при этом соединение с ЭТИМ клиентом не рвёт:
    dead-man's switch реагирует на обрыв связи, а тут связь жива, приложение
    не мертво. Единственный сигнал об этом — лог-кадр "sing-box завершился"
    (см. Supervisor._pump в helper/daemon.py). Без разбора этого кадра Tun
    вечно считал бы себя подключённым к мёртвому туннелю — ровно та ложь о
    состоянии, ради ухода от которой писался весь модуль.
    """
    from native import paths, tun
    from shared.models import Server

    with _Stand(_SINGBOX_CRASHES).serve_here() as stand:
        states: list[bool] = []
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True):
            t = tun.Tun(on_state=states.append)
            t.start(Server(address="127.0.0.1"), 10808)
            assert t.running is True

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and t.running:
                time.sleep(0.05)
            assert t.running is False, "Tun не заметил, что sing-box умер сам"
            assert states == [True, False], states
            # Соединение демон не рвал — Tun не должен был закрывать его сам
            # (это не его решение, см. комментарий в Tun._read_logs): значит
            # отправить в него ещё что-то всё ещё можно.
            assert t._conn is not None, "Tun не должен закрывать соединение сам по кадру лога"


@check
def test_tun_start_closes_stale_connection_left_open_by_previous_session():
    """Ревью Задачи 11, minor 4. Соседняя проверка
    (test_tun_reports_disconnect_when_singbox_dies_on_its_own) показывает,
    что после смерти sing-box самого по себе t._conn остаётся не закрытым —
    закрывать его обязана вызывающая сторона (main_window._on_tun_state), но
    та чистит только когда vpn_mode остаётся "tun"; переключение способа
    подключения посреди поднятого TUN этот путь не проходит. Без защёлки в
    Tun.start() второй старт поверх такого «хвоста» завёл бы ещё один сокет
    и поток поверх уже повисшего — соединение утекло бы.
    """
    from native import paths, tun
    from shared.models import Server

    with _Stand(_SINGBOX_CRASHES).serve_here() as stand:
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True):
            t = tun.Tun()
            t.start(Server(address="127.0.0.1"), 10808)

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and t.running:
                time.sleep(0.05)
            assert t.running is False, "Tun не заметил, что sing-box умер сам"
            stale_conn = t._conn
            assert stale_conn is not None, "предпосылка: соединение должно было остаться открытым"
            assert stale_conn.sock.fileno() >= 0, "предпосылка: сокет ещё не закрыт"

            # Второй старт без явного stop() между ними — ровно тот сценарий,
            # который защёлка обязана разрулить сама. _SINGBOX_CRASHES у
            # второй сессии тоже сразу умрёт — тут это не мешает: важно, что
            # request на "start" прошёл (демон принял его, не отказал
            # "прежний sing-box не снялся") и что старое соединение реально
            # ЗАКРЫТО, а не просто заслонено новым — иначе оно продолжало бы
            # держать сокет и поток независимо от того, что t._conn уже
            # указывает на другой объект.
            t.start(Server(address="127.0.0.1"), 10808)
            try:
                assert t._conn is not None and t._conn is not stale_conn, (
                    "должно было завестись новое соединение, а не повиснуть на старом"
                )
                assert t.running is True, "второй start() должен был отрапортовать успех"
                assert stale_conn.sock.fileno() == -1, (
                    "старое соединение должно было закрыться, а не остаться висеть"
                )
            finally:
                t.stop()
                assert stand.wait_gone()


@check
def test_tun_start_forwards_tun_stack_setting_to_daemon():
    """tun_stack из настроек обязан долететь до конфига sing-box, а не
    потеряться по дороге — от Tun.start() через демон до JSON на диске.
    """
    import json
    from unittest import mock

    from native import paths, tun
    from shared import storage
    from shared.models import Server

    with _Stand().serve_here() as stand:
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True), \
             mock.patch.object(storage, "load_settings", lambda: {"tun_stack": "system"}):
            t = tun.Tun()
            t.start(Server(address="127.0.0.1"), 10808)
            try:
                assert stand.wait_up(), "поддельный sing-box не поднялся"
                cfg = json.loads((stand.tmp / "run" / "singbox.json").read_text())
                assert cfg["inbounds"][0]["stack"] == "system", cfg["inbounds"][0]
            finally:
                t.stop()
                assert stand.wait_gone()


@check
def test_tun_stack_default_is_gvisor_and_reaches_daemon_from_real_settings():
    """Половина Шага 3 Задачи 11, которую соседняя проверка не покрывает:
    test_tun_start_forwards_tun_stack_setting_to_daemon подменяет
    storage.load_settings() целиком лямбдой — удали ключ "tun_stack" из
    DEFAULT_SETTINGS в shared/storage.py совсем, та проверка этого не
    заметит. Здесь — настоящий load_settings() без settings.json на диске
    (DEFAULT_SETTINGS единственный источник) прогоняется через настоящий
    Tun.start() до конфига sing-box.
    """
    import json
    from unittest import mock

    from native import paths, tun
    from shared import storage
    from shared.models import Server

    assert storage.DEFAULT_SETTINGS.get("tun_stack") == "gvisor", storage.DEFAULT_SETTINGS.get("tun_stack")

    with _Stand().serve_here() as stand:
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True), \
             mock.patch.object(paths, "SETTINGS_FILE", stand.tmp / "no-such-settings.json"):
            assert storage.load_settings().get("tun_stack") == "gvisor", "умолчание из DEFAULT_SETTINGS не дошло"

            t = tun.Tun()
            t.start(Server(address="127.0.0.1"), 10808)
            try:
                assert stand.wait_up(), "поддельный sing-box не поднялся"
                cfg = json.loads((stand.tmp / "run" / "singbox.json").read_text())
                assert cfg["inbounds"][0]["stack"] == "gvisor", cfg["inbounds"][0]
            finally:
                t.stop()
                assert stand.wait_gone()


@check
def test_tun_start_closes_connection_when_request_fails_after_daemon_already_started():
    """Ревью Задачи 9, Important 3.

    Если conn.request() бросает уже ПОСЛЕ того, как демон обработал start и
    поднял sing-box (таймаут по 60-секундному потолку, обрыв, не-dict в
    ответе, исключение из on_log на кадре лога — не важно, что именно),
    Tun.start() обязан всё равно закрыть conn. В интерфейсе именно этот путь:
    shared/ui/main_window.py ловит исключение в except Exception as e: и
    держит QMessageBox — то есть держит traceback, а вместе с ним и
    незакрытое соединение, если Tun.start() его не закрыл сам.

    Инжектируем ошибку в _Connection.request ПОСЛЕ настоящего успешного
    обмена с настоящим демоном — то есть демон реально стартовал sing-box, а
    клиент об этом успехе так и не узнал (ровно сценарий ревьюера: PID жив,
    t.running is False, t._conn is None, t.stop() — пустышка).
    """
    from unittest import mock

    from helper import daemon
    from native import paths, tun
    from shared.models import Server

    real_request = tun._Connection.request
    # Своим poll'ом stand.wait_up() тут не обойтись: при исправленном коде
    # Tun.start() закрывает conn СРАЗУ в обработчике исключения — демон видит
    # обрыв и валит sing-box за миллисекунды, быстрее первого опроса pgrep.
    # Поэтому предусловие («демон и правда поднял sing-box до инжекции»)
    # проверяем синхронно, в момент, когда реальный request() уже вернул
    # ответ — это и есть момент, после которого демон гарантированно вызвал
    # SUPERVISOR.start().
    precondition: list[bool] = []

    def flaky_request(self, payload, timeout=240.0):
        reply = real_request(self, payload, timeout)
        if payload.get("cmd") == "start":
            precondition.append(daemon.SUPERVISOR.running)
            raise OSError("инъекция: обрыв после того, как демон уже ответил")
        return reply

    with _Stand().serve_here() as stand:
        with mock.patch.object(paths, "HELPER_SOCKET", Path(stand.sock_path)), \
             mock.patch.object(paths, "BIN_DIR", stand.tmp), \
             mock.patch.object(tun, "helper_installed", lambda: True), \
             mock.patch.object(tun._Connection, "request", flaky_request):
            t = tun.Tun()
            held_exc = None
            try:
                t.start(Server(address="127.0.0.1"), 10808)
                raise AssertionError("start() должен был бросить инжектированный OSError")
            except OSError as e:
                # Держим traceback живым — как QMessageBox.critical(...) в
                # main_window.py: именно так, а не сразу, обнаруживается утечка.
                held_exc = e

            assert precondition == [True], "демон должен был реально поднять sing-box до инжекции"
            assert t.running is False, "Tun не должен считать себя запущенным"
            assert t._conn is None, "Tun не должен держать ссылку на оборванное соединение"

            # Главная проверка: соединение закрыто ЯВНО в момент отказа, а не
            # «когда-нибудь через сборщик мусора» — обрыв должен быть виден
            # демону сразу, без ожидания финализатора.
            assert stand.wait_gone(timeout=3), (
                f"демон не увидел закрытие соединения — conn утёк: {stand.singbox_pids()}"
            )
            del held_exc


# Сколько ждём одну проверку, прежде чем считать её зависшей. Самый долгий
# легитимный прогон в файле — test_daemon_drops_tunnel_on_repeated_sigterm
# (d.wait(timeout=30), с большим запасом сверху фактического времени) — так
# что 45 с оставляют этому и любому похожему тесту солидный запас, но всё
# ещё на порядок меньше, чем «висеть вечно».
_CHECK_TIMEOUT_SEC = 45.0


def _run_with_timeout(fn, timeout: float = _CHECK_TIMEOUT_SEC) -> None:
    """Выполнить одну проверку под сторожевым таймаутом.

    Дедлоки сокета (пример — close() без предварительного shutdown(), см.
    Задачу 9) вешают поток НАВСЕГДА, а не бросают исключение: без внешнего
    ограничения такая регрессия не даёт FAIL, а вешает весь прогон целиком,
    и отличить «завис» от «просто небыстрый тест» можно только руками,
    оборвав прогон снаружи. join(timeout) — вот эта граница: сама проверка
    выполняется в отдельном потоке; если она не уложилась, поток остаётся
    висеть сам по себе (не daemon-поток задачу не решит — процесс не выйдет,
    пока он жив, поэтому именно daemon=True), а раннер идёт дальше и честно
    репортует, какая именно проверка не уложилась, вместо того чтобы
    зависнуть вместе с ней.
    """
    outcome: dict[str, BaseException] = {}

    def runner() -> None:
        try:
            fn()
        except Exception as e:  # noqa: BLE001 — донести причину наверх, не проглотить
            outcome["error"] = e

    t = threading.Thread(target=runner, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        raise TimeoutError(
            f"не уложилась в {timeout:.0f} с — похоже на дедлок, а не на медленный код"
        )
    if "error" in outcome:
        raise outcome["error"]


@check
def test_running_apps_lists_bundles_not_daemons():
    from native.apps import running_apps

    apps = running_apps()
    assert apps, "не нашлось ни одного запущенного приложения"
    assert all("/" not in a for a in apps), apps
    assert all(not a.endswith(".app") for a in apps), apps
    # Расширения (виджеты, .appex) — не приложения, в списке им не место.
    assert not any("Extension" in a or "Widget" in a for a in apps), apps


@check
def test_normalize_strips_bundle_suffix_and_path():
    from native.apps import normalize

    assert normalize("  Telegram.app  ") == "Telegram"
    assert normalize("/Applications/Telegram.app") == "Telegram"
    assert normalize("Telegram") == "Telegram"


@check
def test_running_apps_includes_system_applications():
    """running_apps с синтетическим вводом покрывает все три префикса и мутации."""
    from unittest import mock
    from pathlib import Path

    from native import apps

    # Синтетический выход ps, покрывающий все три префикса, вложенность и .appex.
    synthetic_ps = """/Applications/Telegram.app/Contents/MacOS/Telegram
/System/Applications/Mail.app/Contents/MacOS/Mail
/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
{home}/Applications/Steam.app/Contents/MacOS/Steam
/System/Applications/Utilities/Terminal.app/Contents/PlugIns/TerminalLiveActivityWidgetExtension.appex/Contents/MacOS/TerminalLiveActivityWidgetExtension
/Applications/Electron.app/Contents/PlugIns/ElectronExtension.appex/Contents/MacOS/ElectronExtension
/usr/libexec/something
""".format(home=Path.home())

    mock_result = mock.MagicMock()
    mock_result.stdout = synthetic_ps

    with mock.patch.object(apps.subprocess, "run", return_value=mock_result):
        result = apps.running_apps()

    # Ожидаем ровно четыре имени: из трёх префиксов, без .appex и без системной мелочи.
    expected = ["Mail", "Steam", "Telegram", "Terminal"]
    assert result == expected, f"ожидали {expected}, получили {result}"


# ----------------------------------------------------------------------
# Префлайт TUN в shared/ui/main_window.py: три исхода acquire_privilege()
# ----------------------------------------------------------------------
# Настоящий QApplication здесь не поднимаем — не потому, что не умеет (умеет,
# см. отчёт Задачи 11: venv лежал под каталогом со снятым флагом UF_HIDDEN,
# из-за чего Qt/QDir не видел свои же файлы плагинов платформы; переезд на
# venv/ без ведущей точки и chflags -R nohidden это чинит без единой
# переменной окружения), а потому, что раннер гоняет каждую проверку в
# отдельном потоке (см. _run_with_timeout ниже), а конструктор QApplication
# трогает Cocoa (setMainMenu и т.п.), которая требует ГЛАВНЫЙ поток —
# QApplication() не на нём валит процесс целиком SIGABRT'ом
# (NSInternalInconsistencyException), проверено. Поэтому префлайт проверяем
# без реального Qt: MainWindow создаём в обход __init__ через
# MainWindow.__new__(MainWindow) — обычный object.__new__() на QObject-
# наследнике шибокен запрещает явно, — а QMessageBox и QApplication
# подменяем моками прямо в модуле; тело connect_vpn при этом настоящее,
# ничего не эмулируется.
def _bare_window(mode: str) -> "object":
    import shared.ui.main_window as mw

    win = mw.MainWindow.__new__(mw.MainWindow)
    win.settings = {"vpn_mode": mode}
    win._current_server = lambda: mw.Server(address="127.0.0.1", security="none")
    win._render_state = lambda *_: None
    win._append_log = lambda *_: None
    win._start_with_fingerprint = lambda *a, **k: None
    win._want_connected = False
    return win


def _platform(name: str):
    """Подменить sys.platform, который видит main_window, — и только его.

    Патчить настоящий sys.platform на весь процесс нельзя: проверки идут в
    отдельных потоках (_run_with_timeout), и подмена задела бы всё, что в
    этот момент выполняется. Здесь же подменяется только имя `sys` в
    пространстве самого main_window, а весь его интерес к нему — одна
    строчка `sys.platform == "darwin"` в _tun_preflight()/_download_tun().
    """
    import types

    import shared.ui.main_window as mw

    return mock.patch.object(mw, "sys", types.SimpleNamespace(platform=name))


@check
def test_connect_vpn_tun_on_clean_machine_reaches_privilege_question():
    """Ревью перед слиянием, Critical 1: на чистой машине (демона нет,
    sing-box нет) TUN включить было НЕВОЗМОЖНО — замкнутый круг.

    Префлайт требовал компоненты раньше прав, а на macOS компоненты кладёт
    привилегированный демон, которого ставит ровно ветка прав — за уже
    непроходимым гейтом. Второй вход был закрыт симметрично: меню «Скачать
    компоненты TUN» отвечало «сначала установи системный компонент (включи
    TUN-режим)», то есть отправляло туда, откуда пользователь пришёл.

    Сторож именно на круг: путь включения TUN на чистой машине ОБЯЗАН
    дойти до вопроса про права, а не упереться в сообщение про компоненты.
    Отвечаем «нет» — дальше по этому пути на этой машине идти нельзя
    (установка демона запрещена условиями), но сам вопрос обязан прозвучать.
    """
    import shared.ui.main_window as mw

    win = _bare_window("tun")
    with _platform("darwin"), \
         mock.patch.object(mw, "core_present", lambda: True), \
         mock.patch.object(mw, "tun_present", lambda: False), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw.QMessageBox, "question",
                           return_value=mw.QMessageBox.No) as question_mock, \
         mock.patch.object(mw, "acquire_privilege") as acquire_mock, \
         mock.patch.object(mw.QApplication, "quit") as quit_mock, \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.connect_vpn()

    question_mock.assert_called_once()
    shown = question_mock.call_args.args[-1]
    assert shown == mw.PRIVILEGE_QUESTION, shown
    warn_mock.assert_not_called()      # «нет компонентов» вместо вопроса — это и был круг
    acquire_mock.assert_not_called()   # ответили «нет» — ставить демона не пошли
    quit_mock.assert_not_called()
    assert win._want_connected is False


@check
def test_connect_vpn_tun_rechecks_components_after_helper_is_installed():
    """Вторая половина Critical 1: после установки демона компоненты надо
    ПЕРЕПРОВЕРИТЬ — их всё ещё нет, и следующий шаг пользователя (меню
    «Скачать компоненты TUN») теперь проходим, потому что демон уже стоит.
    """
    import shared.ui.main_window as mw

    win = _bare_window("tun")
    with _platform("darwin"), \
         mock.patch.object(mw, "core_present", lambda: True), \
         mock.patch.object(mw, "tun_present", lambda: False), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw, "acquire_privilege", lambda: "ok"), \
         mock.patch.object(mw.QMessageBox, "question",
                           return_value=mw.QMessageBox.Yes) as question_mock, \
         mock.patch.object(mw.QApplication, "quit") as quit_mock, \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.connect_vpn()

    question_mock.assert_called_once()
    warn_mock.assert_called_once()
    shown_title = warn_mock.call_args.args[1]
    assert "компонент" in shown_title.lower(), shown_title
    quit_mock.assert_not_called()
    assert win._want_connected is False


@check
def test_connect_vpn_tun_keeps_windows_order_components_before_privilege():
    """Порядок префлайта разведён по платформам, и вторая половина — тоже
    требование: на Windows компоненты (два файла на диске) и права (UAC)
    независимы, поэтому при отсутствии компонентов круг UAC гонять незачем —
    сперва сообщение «нет компонентов», вопроса про права быть не должно.
    Windows-половину здесь не запустить, но ветка префлайта — в общем
    shared/, и выбрать её можно, подменив то, что видит main_window.
    """
    import shared.ui.main_window as mw

    win = _bare_window("tun")
    with _platform("win32"), \
         mock.patch.object(mw, "core_present", lambda: True), \
         mock.patch.object(mw, "tun_present", lambda: False), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw.QMessageBox, "question") as question_mock, \
         mock.patch.object(mw.QApplication, "quit") as quit_mock, \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.connect_vpn()

    question_mock.assert_not_called()
    quit_mock.assert_not_called()
    warn_mock.assert_called_once()
    shown_title = warn_mock.call_args.args[1]
    assert "компонент" in shown_title.lower(), shown_title
    assert win._want_connected is False


@check
def test_download_tun_installs_helper_first_on_macos():
    """Второй вход в TUN. На macOS sing-box кладёт себе сам демон, и без него
    скачивание отвечало «сначала установи системный компонент» — тот же круг
    с другой стороны. Теперь пункт меню сперва предлагает поставить демона;
    отказ означает, что скачивать никто не побежит.
    """
    import shared.ui.main_window as mw

    win = _bare_window("tun")
    started: list = []
    win._run_download = lambda *a, **k: started.append(a)

    with _platform("darwin"), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw.QMessageBox, "question",
                           return_value=mw.QMessageBox.No) as question_mock:
        win._download_tun()

    question_mock.assert_called_once()
    assert not started, "без демона качать некуда — скачивание не должно было стартовать"

    with _platform("darwin"), \
         mock.patch.object(mw, "privileged", lambda: True), \
         mock.patch.object(mw.QMessageBox, "question") as question_mock:
        win._download_tun()

    question_mock.assert_not_called()   # демон уже стоит — спрашивать не о чем
    assert len(started) == 1, "с установленным демоном скачивание обязано стартовать"


@check
def test_download_tun_log_does_not_promise_wintun_on_macos():
    """Мелочь ревью: строка лога обещала «sing-box + wintun» на обеих
    платформах, а wintun — драйвер адаптера, которого на macOS нет вовсе.
    """
    import shared.ui.main_window as mw

    logs: list[str] = []
    win = _bare_window("tun")
    win._append_log = logs.append
    win._run_download = lambda *a, **k: None

    with _platform("darwin"), mock.patch.object(mw, "privileged", lambda: True):
        win._download_tun()
    assert "wintun" not in logs[-1].lower(), logs[-1]
    assert "sing-box" in logs[-1], logs[-1]

    with _platform("win32"):
        win._download_tun()
    assert "wintun" in logs[-1].lower(), logs[-1]


@check
def test_connect_vpn_tun_ok_outcome_continues_in_process():
    """acquire_privilege() == "ok" — демон уже поставлен, macOS продолжает
    connect_vpn() в этом же процессе: без QApplication.quit() и без диалога
    об ошибке. Раньше (до Задачи 11) код понимал только "restart" и на этой
    ветке показывал бы неверное «Не удалось перезапустить с правами
    администратора» — ровно то, о чём предупреждала брифа Задачи 11."""
    import shared.ui.main_window as mw

    win = _bare_window("tun")
    with mock.patch.object(mw, "core_present", lambda: True), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw, "acquire_privilege", lambda: "ok"), \
         mock.patch.object(mw, "tun_present", lambda: True), \
         mock.patch.object(mw.QMessageBox, "question", staticmethod(lambda *a, **k: mw.QMessageBox.Yes)), \
         mock.patch.object(mw.QApplication, "quit") as quit_mock, \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.connect_vpn()

    quit_mock.assert_not_called()
    warn_mock.assert_not_called()
    assert win._want_connected is True, "префлайт должен был пропустить старт дальше"


@check
def test_connect_vpn_tun_restart_outcome_quits_without_warning():
    """acquire_privilege() == "restart" (путь Windows) — процесс обязан выйти
    через QApplication.quit(), без предупреждения об ошибке: это не отказ, а
    штатный перезапуск с правами."""
    import shared.ui.main_window as mw

    win = _bare_window("tun")
    with mock.patch.object(mw, "core_present", lambda: True), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw, "acquire_privilege", lambda: "restart"), \
         mock.patch.object(mw, "tun_present", lambda: True), \
         mock.patch.object(mw.QMessageBox, "question", staticmethod(lambda *a, **k: mw.QMessageBox.Yes)), \
         mock.patch.object(mw.QApplication, "quit") as quit_mock, \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.connect_vpn()

    quit_mock.assert_called_once()
    warn_mock.assert_not_called()
    assert win._want_connected is False, "на restart-исходе старт не должен был продолжиться"


@check
def test_connect_vpn_tun_failed_outcome_warns_without_quit():
    """Любой прочий исход (например "failed") — предупреждение, без
    QApplication.quit(): пользователь остаётся в работающем приложении."""
    import shared.ui.main_window as mw

    win = _bare_window("tun")
    with mock.patch.object(mw, "core_present", lambda: True), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw, "acquire_privilege", lambda: "failed"), \
         mock.patch.object(mw, "tun_present", lambda: True), \
         mock.patch.object(mw.QMessageBox, "question", staticmethod(lambda *a, **k: mw.QMessageBox.Yes)), \
         mock.patch.object(mw.QApplication, "quit") as quit_mock, \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.connect_vpn()

    quit_mock.assert_not_called()
    warn_mock.assert_called_once()
    assert win._want_connected is False, "на неудачном исходе старт не должен был продолжиться"


@check
def test_connect_vpn_surfaces_real_installer_error_text():
    """Ревью Задачи 11, Important 2. acquire_privilege() глотала настоящий
    RuntimeError от install() (helper/install.py — «Установка отменена.»
    либо живой stderr launchctl) и возвращала голое "failed"; main_window
    показывал зашитую фразу ни о чём — основной путь первого включения TUN
    на macOS оставлял пользователя без единой зацепки. Теперь текст идёт
    через native.tun.last_privilege_error(). Проверяем НАСТОЯЩИЙ
    acquire_privilege() (не мок лямбдой, как в соседних трёх проверках) —
    подменяем только install() (сетевой/системный вызов), а contract
    acquire_privilege() -> str не трогаем.
    """
    import shared.ui.main_window as mw
    from native import tun as tun_module

    win = _bare_window("tun")
    with mock.patch.object(mw, "core_present", lambda: True), \
         mock.patch.object(mw, "privileged", lambda: False), \
         mock.patch.object(mw, "tun_present", lambda: True), \
         mock.patch.object(tun_module, "_install_helper", side_effect=RuntimeError("Установка отменена.")), \
         mock.patch.object(mw.QMessageBox, "question", staticmethod(lambda *a, **k: mw.QMessageBox.Yes)), \
         mock.patch.object(mw.QApplication, "quit") as quit_mock, \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.connect_vpn()

    quit_mock.assert_not_called()
    warn_mock.assert_called_once()
    shown = warn_mock.call_args.args[-1]
    assert "Установка отменена." in shown, shown
    assert shown != "Не удалось получить права администратора.", (
        "должен показываться настоящий текст причины, а не зашитая фраза ни о чём"
    )


@check
def test_disconnect_does_not_report_idle_when_tunnel_survived():
    """Important 1 со стороны интерфейса: правдивый ответ демона обязан
    доехать до экрана. Раньше disconnect_vpn() возврат Tun.stop() не смотрел
    вовсе, и «Отключено» рисовалось в любом случае.

    Заодно сторож на состояние "tun_stuck": рисует его _render_state, а
    кольцо кнопки берёт цвет и стиль из PowerButton._RING по тому же ключу —
    забыть там строчку значит уронить paintEvent по KeyError уже в руках
    пользователя, а не здесь.
    """
    import shared.ui.main_window as mw
    from shared.ui.widgets import PowerButton

    assert set(mw.STATE_TEXTS) == set(mw.STATE_COLORS) == set(PowerButton._RING), (
        "состояния статуса и кольца кнопки разошлись: "
        f"{sorted(mw.STATE_TEXTS)} / {sorted(mw.STATE_COLORS)} / {sorted(PowerButton._RING)}"
    )

    def window(tun_down: bool):
        win = _bare_window("tun")
        rendered: list[str] = []
        win._render_state = rendered.append
        win.tun = mock.MagicMock()
        win.tun.stop.return_value = tun_down
        win.runner = mock.MagicMock()
        return win, rendered

    # Туннель не снялся — «Отключено» показывать нельзя.
    win, rendered = window(False)
    with mock.patch.object(mw.sysproxy, "is_enabled", lambda: False), \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.disconnect_vpn()
    warn_mock.assert_called_once()
    assert rendered[-1:] == ["tun_stuck"], rendered
    assert mw.STATE_TEXTS[rendered[-1]] != mw.STATE_TEXTS["idle"], mw.STATE_TEXTS

    # Положительный контроль: снялся — никакой тревоги и никакого нового
    # состояния поверх обычного «Отключено» (его рисует _on_state от runner).
    win, rendered = window(True)
    with mock.patch.object(mw.sysproxy, "is_enabled", lambda: False), \
         mock.patch.object(mw.QMessageBox, "warning") as warn_mock:
        win.disconnect_vpn()
    warn_mock.assert_not_called()
    assert rendered == [], rendered


@check
def test_run_app_reaches_event_loop():
    """run_app() был сломан целиком (`from .. import paths` резолвился в
    несуществующий shared.paths вместо native.paths) — запуск ронялся
    ImportError'ом до создания окна, и так было десять задач подряд, пока
    баг не всплыл в Задаче 11 при первом же ручном запуске. Ничем не
    закрыт, кроме однократной ручной проверки — вот регрессионная версия.

    Настоящий QApplication здесь не создаём: конструктор трогает Cocoa
    (setMainMenu и т.п.), а Cocoa требует главный поток — раннер же гоняет
    каждую проверку в отдельном потоке (см. _run_with_timeout), и настоящий
    QApplication() с не-главного потока валит процесс целиком (проверено:
    NSInternalInconsistencyException, весь прогон обрывается). Поэтому
    QApplication и MainWindow подменены, а всё остальное в run_app() —
    настоящее: реальный `from native import paths`, реальные вызовы
    setApplicationName/setStyleSheet/setWindowIcon/show и возврат app.exec().

    QIcon тоже подменён, но не был подменён до Задачи 12 — тогда `scvpn.icns`
    ещё не существовал, `paths.icon_file().exists()` был False, и ветка
    `app.setWindowIcon(QIcon(str(ico)))` в run_app() ни разу не исполнялась:
    тест был зелёным, ничего не проверяя. Теперь файл в git, ветка исполняется
    по-настоящему при каждом прогоне — а настоящий QIcon(путь) грузит пиксели
    и без настоящего QGuiApplication в процессе валит его тем же способом,
    каким свалил бы настоящий QApplication (см. абзац выше) — родство ровно
    в одном: оба требуют Cocoa/GuiApplication, которых здесь по конструкции
    нет. Поэтому QIcon подменён так же, как QApplication/MainWindow, а
    ассерты ниже проверяют, что ветка `ico.exists()` реально дошла до
    QIcon(str(ico)) и до setWindowIcon — а не просто не упала.
    """
    from unittest import mock

    import shared.ui.main_window as mw
    from native import paths

    fake_app = mock.MagicMock()
    fake_app.exec.return_value = 0
    fake_win = mock.MagicMock()

    ico = paths.icon_file()
    assert ico.exists(), "scvpn.icns отсутствует — ветка setWindowIcon не будет проверена"

    with mock.patch.object(mw, "QApplication", return_value=fake_app) as app_cls, \
         mock.patch.object(mw, "MainWindow", return_value=fake_win) as win_cls, \
         mock.patch.object(mw, "QIcon") as icon_cls:
        assert mw.run_app() == 0

    app_cls.assert_called_once()
    win_cls.assert_called_once()
    fake_win.show.assert_called_once()
    fake_app.exec.assert_called_once()
    icon_cls.assert_called_once_with(str(ico))
    fake_app.setWindowIcon.assert_called_once_with(icon_cls.return_value)


def main() -> int:
    failed = 0
    for fn in CHECKS:
        try:
            _run_with_timeout(fn)
            print(f"  ok   {fn.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  FAIL {fn.__name__}: {e}")
    print(f"\n{len(CHECKS) - failed}/{len(CHECKS)} проверок пройдено.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
