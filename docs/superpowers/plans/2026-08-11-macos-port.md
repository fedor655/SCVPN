# Порт SCVPN на macOS — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Портировать десктопный SCVPN на macOS (Apple Silicon), разложив `desktop/` на общий `shared/` и платформенные `Windows/` и `MacOS/`, с TUN через привилегированный LaunchDaemon.

**Architecture:** Общий код (парсеры, модели, конфиг Xray, хранилище, UI) переезжает в `desktop/shared/` без обёртки-пакета. Каждая платформа держит пакет `native/` с одним и тем же набором имён — `paths`, `sysproxy`, `hwid`, `downloader`, `tun`, `apps` — и подставляется тот, из чьей папки запущено приложение. TUN на macOS поднимает root-демон, слушающий unix-сокет; открытое соединение GUI служит dead-man's switch.

**Tech Stack:** Python 3.11+, PySide6, PyInstaller, стандартная библиотека для демона (`socket`, `json`, `subprocess`, `ipaddress`, `tarfile`), системные утилиты macOS (`networksetup`, `ioreg`, `ps`, `launchctl`, `iconutil`, `codesign`).

Спека: `docs/superpowers/specs/2026-08-11-macos-port-design.md`.

## Global Constraints

- Целевая платформа — только macOS на Apple Silicon (arm64). Ассет Xray — `Xray-macos-arm64-v8a.zip`, ассет sing-box — `sing-box-<ver>-darwin-arm64.tar.gz`.
- Пакет платформенного слоя называется `native`, **никогда** `platform`: каталог запускаемого скрипта попадает в `sys.path`, и пакет `platform` перекрыл бы одноимённый стандартный модуль.
- Демон никогда не принимает готовый конфиг sing-box — только валидируемые параметры, конфиг собирает сам.
- Демон запускает только бинарники из `/Library/Application Support/SCVPN/bin`, принадлежащие `root:wheel` и недоступные на запись группе и остальным.
- Сокет демона: `/var/run/scvpn-helper.sock`, владелец `root:admin`, права `0660`.
- В конфиге sing-box для macOS нет `strict_route` и нет `interface_name`.
- Комментарии и текст интерфейса — на русском, в тон существующему коду. Никаких эмодзи в коде.
- Осознанные упрощения помечаются комментарием `# ponytail:` с указанием потолка и пути доработки.
- Зависимости не добавляются: демон — только стандартная библиотека, приложение — существующий `requirements.txt`.

## Ограничение проверки

Работа ведётся на macOS. Windows-половину **невозможно запустить** для проверки. Поэтому:

- Для `desktop/Windows/` гарантируется только синтаксическая целостность (`compileall`) и сохранность содержимого при переносе (сверка по `git log --follow` и по diff).
- Задача 1 фиксирует, что ни одна строка Windows-логики не переписывается — только пути импорта.
- В финальном отчёте это указывается явно: Windows-сборку нужно прогнать на Windows-машине.

## File Structure

```
desktop/
├── shared/                    общий код, один экземпляр
│   ├── __init__.py            версия, APP_NAME (из бывшего scvpn/__init__.py)
│   ├── models.py              без изменений
│   ├── subscription.py        без изменений
│   ├── xray_config.py         без изменений
│   ├── subinfo.py             без изменений
│   ├── ping.py                без изменений
│   ├── connect.py             импорты
│   ├── core_runner.py         импорты
│   ├── storage.py             импорты
│   └── ui/                    add_dialog brandmark main_window qr_scanner
│                              split_dialog subscription_dialog theme widgets workers
├── Windows/
│   ├── native/                __init__ paths sysproxy hwid downloader tun apps
│   ├── run.py SCVPN.bat build.bat build_installer.bat test.bat SCVPN.spec smoke_test.py
│   ├── requirements.txt
│   ├── setup/                 brand.py make_icon.py installer.iss scvpn.ico scvpn_256.png
│   └── README.md
└── MacOS/
    ├── native/                __init__ paths sysproxy hwid downloader tun apps
    ├── helper/                __init__ config.py daemon.py install.py com.scvpn.helper.plist
    ├── run.py build.sh test.sh SCVPN.spec smoke_test.py test_native.py
    ├── requirements.txt
    ├── setup/                 scvpn.icns
    └── README.md
```

### Контракт пакета `native`

Обе платформы обязаны предоставить ровно это. `shared/` не имеет права знать ничего сверх.

```python
# native.paths
ROOT: Path;  FROZEN: bool;  BIN_DIR: Path;  DATA_DIR: Path;  LOG_DIR: Path
PROFILES_FILE: Path;  SETTINGS_FILE: Path;  XRAY_CONFIG_FILE: Path
def xray_exe() -> Path
def geoip_dat() -> Path
def geosite_dat() -> Path
def resource_path(rel: str) -> Path
def icon_file() -> Path
def ensure_dirs() -> None

# native.sysproxy
def enable(host: str = "127.0.0.1", port: int = 10809) -> None
def disable() -> None
def is_enabled() -> bool

# native.hwid
def device_id() -> str
def device_headers() -> dict[str, str]

# native.downloader
def core_present() -> bool
def download_core(progress: Callable[[str], None] | None = None) -> str
def tun_present() -> bool
def download_tun(progress: Callable[[str], None] | None = None) -> str

# native.tun
SPLIT_OFF = "off";  SPLIT_EXCLUDE = "exclude";  SPLIT_INCLUDE = "include"
PRIVILEGE_QUESTION: str          # текст вопроса в диалоге перед повышением прав
def privileged() -> bool         # можно ли прямо сейчас поднять TUN
def acquire_privilege() -> str   # "ok" | "restart" | "failed"
def cleanup_stray(log: Callable[[str], None] | None = None) -> bool
class Tun:
    def __init__(self, on_log=None, on_state=None) -> None
    running: bool                # property
    def start(self, server: Server, socks_port: int,
              split_mode: str = SPLIT_OFF, split_apps: list[str] | None = None) -> None
    def stop(self) -> None

# native.apps
MANUAL_HINT: str                 # подпись в диалоге ручного добавления
def running_apps() -> list[str]  # имена процессов для правил сплит-туннеля
def normalize(name: str) -> str  # привести введённое руками имя к виду правила
```

Отличия от нынешнего кода: `SingBoxTun` → `Tun`, `download_singbox` → `download_tun`, пара `is_admin`/`relaunch_as_admin` → пара `privileged`/`acquire_privilege`, `running_processes` уезжает из `ui/split_dialog.py` в `native/apps.py`. `wintun_dll()` остаётся приватной деталью Windows и в контракт не входит.

---

### Task 1: Реструктуризация desktop/ на shared/ + Windows/

Чистый перенос. Ни одной строки логики не меняется — только расположение файлов и пути импорта. Задача заканчивается тем, что Windows-половина синтаксически цела и `shared/` импортируется.

**Files:**
- Move: `desktop/scvpn/{models,subscription,xray_config,subinfo,ping,connect,core_runner,storage,__init__}.py` → `desktop/shared/`
- Move: `desktop/scvpn/ui/` → `desktop/shared/ui/`
- Move: `desktop/scvpn/{paths,sysproxy,hwid,downloader,tun}.py` → `desktop/Windows/native/`
- Move: `desktop/{run.py,SCVPN.bat,build.bat,build_installer.bat,test.bat,SCVPN.spec,smoke_test.py,requirements.txt,README.md}` → `desktop/Windows/`
- Move: `desktop/setup/` → `desktop/Windows/setup/`
- Create: `desktop/Windows/native/__init__.py`, `desktop/Windows/native/apps.py`
- Modify: `desktop/shared/ui/split_dialog.py` — убрать `running_processes()` и Windows-текст
- Modify: `.gitignore` — пути `desktop/data/`, `desktop/bin/`, `desktop/.venv/` и прочие

**Interfaces:**
- Consumes: ничего.
- Produces: пакет `shared` (импортируется как `from shared.models import Server`) и пакет `native` внутри платформенной папки (импортируется как `from native import paths`). Контракт `native` — как в разделе выше.

- [ ] **Step 1: Перенести файлы через git mv, сохранив историю**

```bash
cd desktop
mkdir -p shared Windows/native
git mv scvpn/ui shared/ui
for f in __init__ models subscription xray_config subinfo ping connect core_runner storage; do
  git mv "scvpn/$f.py" "shared/$f.py"
done
for f in paths sysproxy hwid downloader tun; do
  git mv "scvpn/$f.py" "Windows/native/$f.py"
done
rmdir scvpn
for f in run.py SCVPN.bat build.bat build_installer.bat test.bat SCVPN.spec smoke_test.py requirements.txt README.md; do
  git mv "$f" "Windows/$f"
done
git mv setup Windows/setup
```

- [ ] **Step 2: Проверить, что перенос ничего не потерял**

```bash
git status --short
git diff --cached --stat | tail -1
```

Ожидается: только строки `R` (renamed), ни одной `A`/`D` по .py-файлам, ни одного изменения содержимого.

- [ ] **Step 3: Создать `desktop/Windows/native/__init__.py`**

```python
"""Платформенный слой Windows.

Пакет называется `native`, а не `platform`, потому что каталог запускаемого
скрипта попадает в sys.path — пакет с именем `platform` перекрыл бы
одноимённый стандартный модуль, которым пользуется hwid.py.

Набор имён здесь тот же, что в MacOS/native/ — общий код в shared/ знает
только его и не догадывается, на какой системе работает.
"""
```

- [ ] **Step 4: Переписать импорты в `shared/`**

В `shared/connect.py`, `shared/core_runner.py`, `shared/storage.py` заменить обращения к платформенному слою:

```python
# было
from . import paths
# стало
from native import paths
```

Внутриобщие импорты остаются относительными (`from .models import Server`) — они не пересекают границу слоёв.

В `shared/ui/main_window.py` заменить блок импортов:

```python
from shared import __version__
from shared.connect import find_working_fingerprint
from shared.core_runner import XrayRunner, find_free_port
from shared.models import Server
from shared.storage import (
    Profiles,
    Subscription,
    load_profiles,
    load_settings,
    now_iso,
    save_profiles,
    save_settings,
)
from shared.subscription import SubscriptionError, fetch_subscription_full, parse_link
from shared.xray_config import ROUTE_BYPASS_RU, ROUTE_GLOBAL, build_config
from native import sysproxy
from native.downloader import core_present, download_core, download_tun, tun_present
from native.tun import PRIVILEGE_QUESTION, SPLIT_OFF, Tun, acquire_privilege, cleanup_stray
```

Прочие модули `shared/ui/` (`add_dialog`, `brandmark`, `qr_scanner`, `subscription_dialog`, `theme`, `widgets`, `workers`) обращаются к соседям относительно (`from . import theme`) — их править не нужно, кроме тех, что импортируют из `..`:

```bash
grep -rn "^from \.\.\|^from scvpn\|import scvpn" shared/
```

Каждое найденное `from ..X import Y` заменить на `from shared.X import Y`.

- [ ] **Step 5: Переименовать в Windows-слое имена под контракт**

В `Windows/native/tun.py`:
- `class SingBoxTun` → `class Tun`;
- добавить в конец файла обёртки контракта, оставив существующие функции на месте:

```python
PRIVILEGE_QUESTION = (
    "TUN-режим (весь трафик) требует прав администратора.\n"
    "Перезапустить приложение от имени администратора?"
)


def privileged() -> bool:
    """Можно ли прямо сейчас поднять TUN. На Windows это права администратора."""
    return is_admin()


def acquire_privilege() -> str:
    """Запросить права. "restart" — процесс надо закрыть, поднимется новый."""
    return "restart" if relaunch_as_admin() else "failed"
```

В `Windows/native/downloader.py` добавить псевдонимы под контракт:

```python
# Имена контракта native: на Windows компоненты TUN — это sing-box плюс wintun.
download_tun = download_singbox
```

- [ ] **Step 6: Вынести перечисление процессов в `Windows/native/apps.py`**

Перенести сюда `_SYSTEM` и `running_processes()` из `shared/ui/split_dialog.py` (строки 42–72 исходного файла), переименовав функцию:

```python
"""Список запущенных приложений для правил раздельного туннелирования.

sing-box сопоставляет соединение с процессом-владельцем по имени
исполняемого файла, поэтому здесь нужны именно имена .exe, а не заголовки окон.
"""
from __future__ import annotations

import subprocess

MANUAL_HINT = "Имя исполняемого файла (например, Telegram.exe):"

# Системная мелочь: показывать её в списке бессмысленно, а промахнуться легко.
_SYSTEM = {
    "system", "system idle process", "registry", "memory compression", "svchost.exe",
    "csrss.exe", "wininit.exe", "winlogon.exe", "services.exe", "lsass.exe",
    "smss.exe", "fontdrvhost.exe", "dwm.exe", "ctfmon.exe", "sihost.exe",
    "taskhostw.exe", "runtimebroker.exe", "searchhost.exe", "conhost.exe",
    "dllhost.exe", "spoolsv.exe", "audiodg.exe", "wudfhost.exe",
}


def running_apps() -> list[str]:
    """Имена запущенных .exe, без системной мелочи и дубликатов."""
    try:
        out = subprocess.run(
            ["tasklist", "/fo", "csv", "/nh"],
            capture_output=True, text=True, encoding="cp866", errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
    except Exception:  # noqa: BLE001
        return []
    names: set[str] = set()
    for line in out.splitlines():
        if not line.startswith('"'):
            continue
        name = line.split('","', 1)[0].strip('"')
        if name and name.lower() not in _SYSTEM:
            names.add(name)
    return sorted(names, key=str.lower)


def normalize(name: str) -> str:
    """Привести введённое руками имя к виду, который поймёт правило sing-box."""
    name = name.strip()
    if name and not name.lower().endswith(".exe"):
        name += ".exe"
    return name
```

Сверить тело `running_apps` с оригиналом `running_processes` из `split_dialog.py` и перенести дословно, если оно отличается от приведённого.

- [ ] **Step 7: Убрать платформенное из `shared/ui/split_dialog.py`**

Удалить `_SYSTEM`, `running_processes()` и импорт `subprocess`. Добавить:

```python
from native.apps import MANUAL_HINT, normalize, running_apps
```

Заменить вызов `running_processes()` на `running_apps()`. В обработчике ручного добавления заменить дописывание `.exe`:

```python
# было
if not name.lower().endswith(".exe"):
    name += ".exe"
# стало
name = normalize(name)
```

В строке подписи диалога заменить литерал `"Имя исполняемого файла (например, Telegram.exe):"` на `MANUAL_HINT`.

- [ ] **Step 8: Поправить `Windows/run.py` под новую раскладку**

```python
"""Точка входа SCVPN для Windows.

Запуск:  .venv\\Scripts\\python.exe run.py
"""
import sys
from pathlib import Path

# Общий код лежит на уровень выше, в desktop/shared. Каталог самого скрипта
# (desktop/Windows) Python добавляет в sys.path сам — оттуда берётся native.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Консоль Windows бывает в cp1251 — переключаем потоки на UTF-8, чтобы русский
# текст и любые символы в логах не роняли программу. В режиме без консоли
# (pythonw) потоки могут быть None — тогда просто пропускаем.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except Exception:
        pass

from native import paths  # noqa: E402
from shared.ui.main_window import run_app  # noqa: E402


def main() -> int:
    paths.ensure_dirs()
    return run_app()


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 9: Поправить пути в `Windows/smoke_test.py` и `Windows/SCVPN.spec`**

В `smoke_test.py` — тот же блок `sys.path.insert` в начале, что и в `run.py`, и импорты `from shared.…` / `from native.…` вместо `from scvpn.…`.

В `SCVPN.spec` — добавить `pathex=['..']`, чтобы PyInstaller нашёл пакет `shared`.

- [ ] **Step 10: Обновить `.gitignore` под новые пути**

```
desktop/Windows/.venv/
desktop/Windows/build/
desktop/Windows/dist/
desktop/Windows/dist_installer/
desktop/Windows/data/
desktop/Windows/bin/
desktop/MacOS/.venv/
desktop/MacOS/build/
desktop/MacOS/dist/
desktop/MacOS/data/
desktop/MacOS/bin/
```

Старые строки `desktop/.venv/`, `desktop/build/`, `desktop/dist/`, `desktop/dist_installer/`, `desktop/data/`, `desktop/bin/` удалить.

- [ ] **Step 11: Проверить, что всё компилируется**

Run: `cd desktop && python3 -m compileall -q shared Windows`
Expected: пусто (код возврата 0). Ошибка синтаксиса напечатала бы файл и строку.

- [ ] **Step 12: Проверить, что не осталось ссылок на старый пакет**

Run: `cd desktop && grep -rn "scvpn\." --include=*.py --include=*.spec --include=*.bat --include=*.iss . | grep -v "scvpn\.ico\|scvpn\.icns\|scvpn_256\|scvpn-hwid"`
Expected: пусто.

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "Разделил desktop на общий shared и платформенный Windows/native"
```

---

### Task 2: Скелет macOS — paths, точка входа, приложение запускается

**Files:**
- Create: `desktop/MacOS/native/__init__.py`, `desktop/MacOS/native/paths.py`
- Create: `desktop/MacOS/run.py`, `desktop/MacOS/requirements.txt`
- Create: `desktop/MacOS/test_native.py`, `desktop/MacOS/test.sh`

**Interfaces:**
- Consumes: пакет `shared` из Task 1.
- Produces: `native.paths` по контракту; `HELPER_BIN_DIR: Path` — root-овая папка `/Library/Application Support/SCVPN/bin`, откуда демон запускает sing-box (используется в Task 6, 7, 9); `native.paths.singbox_exe() -> Path` внутри неё.

- [ ] **Step 1: Написать падающие проверки**

Create `desktop/MacOS/test_native.py`:

```python
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

    assert paths.DATA_DIR.name == "SCVPN", paths.DATA_DIR
    if paths.FROZEN:
        assert "Application Support" in str(paths.DATA_DIR), paths.DATA_DIR


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
```

Create `desktop/MacOS/test.sh`:

```bash
#!/bin/bash
# Проверки SCVPN для macOS.
#   ./test.sh            -> модульные проверки платформенного слоя
#   ./test.sh smoke      -> живая проверка (smoke_test.py): парсинг, конфиги, туннель
#   ./test.sh файл.py    -> запустить свой скрипт в окружении проекта
set -u
cd "$(dirname "$0")"
PY=.venv/bin/python

if [ ! -x "$PY" ]; then
  echo "[!] Нет .venv. Создай: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  exit 1
fi

case "${1:-}" in
  "")      "$PY" test_native.py ;;
  smoke)   "$PY" smoke_test.py ;;
  *)       "$PY" "$@" ;;
esac
```

- [ ] **Step 2: Запустить и убедиться, что падает**

```bash
cd desktop/MacOS && chmod +x test.sh
python3 -m venv .venv && .venv/bin/pip install -q -r ../Windows/requirements.txt
./test.sh
```

Expected: три строки `FAIL` с `ModuleNotFoundError: No module named 'native'`.

- [ ] **Step 3: Создать `desktop/MacOS/requirements.txt`**

```
PySide6>=6.6
requests>=2.31
# QR-код ссылки подписки. Чистый Python, картинку рисуем сами через QPainter.
qrcode>=7.4
# Сканирование QR веб-камерой: захват и детектор QR в одной зависимости.
# headless — потому что окна рисует Qt, оконная часть OpenCV не нужна.
opencv-python-headless>=4.9
# Сборка .app.
pyinstaller>=6.3
```

Pillow здесь не нужен: иконка уже нарисована и лежит готовым файлом.

- [ ] **Step 4: Создать `desktop/MacOS/native/__init__.py`**

```python
"""Платформенный слой macOS.

Пакет называется `native`, а не `platform`, потому что каталог запускаемого
скрипта попадает в sys.path — пакет с именем `platform` перекрыл бы
одноимённый стандартный модуль, которым пользуется hwid.py.

Набор имён здесь тот же, что в Windows/native/ — общий код в shared/ знает
только его и не догадывается, на какой системе работает.
"""
```

- [ ] **Step 5: Создать `desktop/MacOS/native/paths.py`**

```python
"""Все пути приложения в одном месте — чтобы было видно, где что лежит.

Во время разработки храним всё рядом с проектом (папки bin/ и data/),
а не в скрытых системных каталогах. Так проще проверить, что внутри.

Отличие от Windows: в собранном виде bin/ тоже уезжает в пользовательскую
папку, а не остаётся рядом с приложением — внутрь .app писать нельзя, а ядро
приложение скачивает само.
"""
from __future__ import annotations

import sys
from pathlib import Path


def project_root() -> Path:
    """Корень проекта (папка, где лежит run.py).

    Работает и при запуске из исходников, и в собранном .app: там sys.executable
    указывает на SCVPN.app/Contents/MacOS/SCVPN.
    """
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


ROOT = project_root()

FROZEN = bool(getattr(sys, "frozen", False))

# Пользовательская папка macOS для данных приложения.
_APP_SUPPORT = Path.home() / "Library" / "Application Support" / "SCVPN"

# Папка с ядром и гео-базами (xray, geoip.dat, geosite.dat).
# В собранном виде — в Application Support: внутрь .app писать нельзя, а ядро
# приложение скачивает само. В разработке — рядом с проектом.
BIN_DIR = _APP_SUPPORT / "bin" if FROZEN else ROOT / "bin"

# Папка для пользовательских данных (профили, настройки, логи).
DATA_DIR = _APP_SUPPORT if FROZEN else ROOT / "data"
LOG_DIR = DATA_DIR / "logs"

# Конкретные файлы.
PROFILES_FILE = DATA_DIR / "profiles.json"          # серверы + подписки
SETTINGS_FILE = DATA_DIR / "settings.json"          # настройки приложения
XRAY_CONFIG_FILE = DATA_DIR / "xray_running.json"   # активный конфиг ядра (для отладки)

# ----------------------------------------------------------------------
# Хозяйство привилегированного демона
# ----------------------------------------------------------------------
# sing-box запускает root, поэтому он обязан лежать там, куда пользователь не
# может писать: иначе любой процесс подменил бы бинарник и получил root.
# Эту папку заводит и наполняет сам демон (root:wheel, 0755).
HELPER_DIR = Path("/Library/Application Support/SCVPN")
HELPER_BIN_DIR = HELPER_DIR / "bin"
HELPER_SOCKET = Path("/var/run/scvpn-helper.sock")
HELPER_PLIST = Path("/Library/LaunchDaemons/com.scvpn.helper.plist")
HELPER_LABEL = "com.scvpn.helper"


def xray_exe() -> Path:
    return BIN_DIR / "xray"


def singbox_exe() -> Path:
    """sing-box используется только для TUN-режима и живёт в root-овой папке."""
    return HELPER_BIN_DIR / "sing-box"


def geoip_dat() -> Path:
    return BIN_DIR / "geoip.dat"


def geosite_dat() -> Path:
    return BIN_DIR / "geosite.dat"


def resource_path(rel: str) -> Path:
    """Путь к упакованному ресурсу (иконка и т.п.)."""
    if FROZEN:
        base = Path(getattr(sys, "_MEIPASS", ROOT))
        return base / rel
    return ROOT / rel


def icon_file() -> Path:
    return resource_path("scvpn.icns") if FROZEN else (ROOT / "setup" / "scvpn.icns")


def ensure_dirs() -> None:
    """Создать рабочие папки, если их ещё нет."""
    for d in (BIN_DIR, DATA_DIR, LOG_DIR):
        d.mkdir(parents=True, exist_ok=True)
```

- [ ] **Step 6: Запустить проверки — должны пройти**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `3/3 проверок пройдено.`

- [ ] **Step 7: Создать `desktop/MacOS/run.py`**

```python
"""Точка входа SCVPN для macOS.

Запуск:      .venv/bin/python run.py
Демон:       .venv/bin/python run.py --helper   (запускает launchd от root)
"""
import sys
from pathlib import Path

# Общий код лежит на уровень выше, в desktop/shared. Каталог самого скрипта
# (desktop/MacOS) Python добавляет в sys.path сам — оттуда берётся native.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def main() -> int:
    # Тот же исполняемый файл работает и приложением, и привилегированным
    # демоном: так в бандле не нужен второй интерпретатор Python.
    if "--helper" in sys.argv[1:]:
        from helper.daemon import main as helper_main

        return helper_main()

    from native import paths
    from shared.ui.main_window import run_app

    paths.ensure_dirs()
    return run_app()


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 8: Commit**

```bash
git add desktop/MacOS
git commit -m "macOS: пути, точка входа, каркас проверок"
```

---

### Task 3: Идентификатор устройства (hwid)

**Files:**
- Create: `desktop/MacOS/native/hwid.py`
- Modify: `desktop/MacOS/test_native.py`

**Interfaces:**
- Consumes: `native.paths` (через `shared.storage`).
- Produces: `native.hwid.device_id() -> str`, `native.hwid.device_headers() -> dict[str, str]`.

- [ ] **Step 1: Написать падающие проверки**

Добавить в `test_native.py` перед `def main()`:

```python
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
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: три `FAIL` с `ModuleNotFoundError: No module named 'native.hwid'`.

- [ ] **Step 3: Создать `desktop/MacOS/native/hwid.py`**

Это копия Windows-версии с заменой одной функции. Шапку-комментарий взять из `Windows/native/hwid.py` дословно, поправив упоминание Windows на macOS. Тело:

```python
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
    """Заголовки, которых ждут панели с учётом устройств."""
    return {
        "x-hwid": device_id(),
        "x-device-os": platform.system() or "Darwin",
        "x-ver-os": platform.release() or "",
        "x-device-model": platform.node() or "Mac",
    }
```

- [ ] **Step 4: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `6/6 проверок пройдено.`

Проверка `test_hwid_is_stable_and_uuid_shaped` пишет `hwid` в `data/settings.json` — это ожидаемо, файл в .gitignore.

- [ ] **Step 5: Commit**

```bash
git add desktop/MacOS/native/hwid.py desktop/MacOS/test_native.py
git commit -m "macOS: идентификатор устройства из IOPlatformUUID"
```

---

### Task 4: Системный прокси через networksetup

Самая опасная часть после демона: неверный откат оставляет пользователя без интернета. Поэтому снимок прежнего состояния пишется на диск и переживает падение приложения.

**Files:**
- Create: `desktop/MacOS/native/sysproxy.py`
- Modify: `desktop/MacOS/test_native.py`

**Interfaces:**
- Consumes: `native.paths.DATA_DIR`.
- Produces: `native.sysproxy.enable(host, port)`, `.disable()`, `.is_enabled()`; плюс `hardware_services() -> list[str]` — используется в проверках и в README.

- [ ] **Step 1: Написать падающие проверки**

Добавить в `test_native.py`:

```python
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
    """enable -> disable обязан вернуть ровно то, что было. Иначе — без интернета."""
    from native import sysproxy

    services = sysproxy.hardware_services()
    before = {s: sysproxy._read_state(s) for s in services}
    sysproxy.enable("127.0.0.1", 10809)
    try:
        assert sysproxy.is_enabled(), "прокси не включился"
    finally:
        sysproxy.disable()
    after = {s: sysproxy._read_state(s) for s in services}
    assert before == after, f"состояние не восстановилось:\n{before}\n{after}"
    assert not sysproxy.is_enabled()
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: два `FAIL` с `ModuleNotFoundError: No module named 'native.sysproxy'`.

- [ ] **Step 3: Создать `desktop/MacOS/native/sysproxy.py`**

```python
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

# Три вида прокси, которые мы выставляем. Для каждого — своя тройка команд.
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


def _read_state(service: str) -> dict[str, dict[str, str]]:
    """Текущие настройки прокси одного сервиса — в том виде, в каком их вернуть."""
    state: dict[str, dict[str, str]] = {}
    for kind, get, _set, _setstate in _KINDS:
        fields: dict[str, str] = {}
        for line in _run([get, service]).splitlines():
            m = _STATE_RE.match(line.strip())
            if m:
                fields[m.group("key")] = m.group("value").strip()
        state[kind] = fields
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
            if fields.get("Enabled") == "Yes" and fields.get("Server"):
                _run([set_cmd, service, fields["Server"], fields.get("Port", "0"), "off"])
            else:
                _run([setstate_cmd, service, "off"])
        # ponytail: список обхода возвращаем к пустому, а не к прежнему —
        # networksetup не отдаёт его в машиночитаемом виде. Если понадобится
        # точный откат, читать -getproxybypassdomains и хранить в снимке.
        _run(["-setproxybypassdomains", service, "Empty"])

    _SNAPSHOT.unlink(missing_ok=True)


def is_enabled() -> bool:
    """Стоит ли сейчас наш прокси хотя бы на одном сервисе."""
    for service in hardware_services():
        web = _read_state(service).get("web", {})
        if web.get("Enabled") == "Yes" and web.get("Server", "").startswith("127.0.0.1"):
            return True
    return False
```

- [ ] **Step 4: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `8/8 проверок пройдено.`

Проверка реально включает и выключает прокси на этой машине. Если она упала посередине — снимок остался в `data/sysproxy_backup.json`, и повторный `disable()` его применит.

- [ ] **Step 5: Убедиться руками, что состояние вернулось**

Run: `networksetup -getwebproxy Wi-Fi`
Expected: `Enabled: No`.

- [ ] **Step 6: Commit**

```bash
git add desktop/MacOS/native/sysproxy.py desktop/MacOS/test_native.py
git commit -m "macOS: системный прокси через networksetup, со снимком для отката"
```

---

### Task 5: Загрузчик ядра Xray

sing-box сюда не входит — его скачивает демон в свою root-овую папку (Task 7).

**Files:**
- Create: `desktop/MacOS/native/downloader.py`
- Modify: `desktop/MacOS/test_native.py`

**Interfaces:**
- Consumes: `native.paths`, `native.tun.helper_call` появится в Task 9 — до тех пор `download_tun` бросает `NotImplementedError`, и Task 9 её дописывает.
- Produces: `core_present()`, `download_core(progress)`, `tun_present()`, `download_tun(progress)`.

- [ ] **Step 1: Написать падающую проверку**

Добавить в `test_native.py`:

```python
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
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: два `FAIL` с `ModuleNotFoundError: No module named 'native.downloader'`.

- [ ] **Step 3: Создать `desktop/MacOS/native/downloader.py`**

```python
"""Разовое скачивание ядра Xray-core с официального GitHub.

Берём последний релиз из репозитория XTLS/Xray-core, скачиваем архив для
macOS arm64 и распаковываем в bin/ ровно три файла: xray, geoip.dat,
geosite.dat. Это единственный «внешний» источник, и он официальный и открытый.

Подписывать скачанное не нужно: линковщик Go сам проставляет ad-hoc подпись
для darwin/arm64, иначе бинарник не запустился бы вовсе. Достаточно дать
право на исполнение.

sing-box здесь нет намеренно: его запускает root, поэтому качает и кладёт его
к себе привилегированный демон, а не мы (см. helper/daemon.py).
"""
from __future__ import annotations

import io
import stat
import zipfile
from typing import Callable, Optional

import requests

from . import paths

RELEASES_API = "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
ASSET_NAME = "Xray-macos-arm64-v8a.zip"
WANTED = {"xray", "geoip.dat", "geosite.dat"}


def latest_asset_url() -> tuple[str, str]:
    """Вернуть (тег_версии, url_архива) последнего релиза Xray-core."""
    r = requests.get(RELEASES_API, timeout=30, headers={"Accept": "application/vnd.github+json"})
    r.raise_for_status()
    data = r.json()
    tag = data.get("tag_name", "?")
    for asset in data.get("assets", []):
        if asset.get("name") == ASSET_NAME:
            return tag, asset["browser_download_url"]
    raise RuntimeError(f"В релизе {tag} не найден ассет {ASSET_NAME}")


def download_core(progress: Optional[Callable[[str], None]] = None) -> str:
    """Скачать и распаковать ядро. Вернуть строку с версией."""
    log = progress or (lambda s: None)
    paths.ensure_dirs()

    log("Узнаю последнюю версию Xray-core…")
    tag, url = latest_asset_url()
    log(f"Версия {tag}. Скачиваю {ASSET_NAME}…")

    r = requests.get(url, timeout=120, stream=True)
    r.raise_for_status()
    buf = io.BytesIO()
    total = int(r.headers.get("Content-Length", 0))
    got = 0
    for chunk in r.iter_content(chunk_size=64 * 1024):
        buf.write(chunk)
        got += len(chunk)
        if total:
            log(f"Скачано {got // 1024} / {total // 1024} КБ")
    buf.seek(0)

    log("Распаковываю…")
    with zipfile.ZipFile(buf) as z:
        for member in z.namelist():
            base = member.rsplit("/", 1)[-1]
            if base in WANTED:
                with z.open(member) as src:
                    (paths.BIN_DIR / base).write_bytes(src.read())
                log(f"  -> bin/{base}")

    missing = [w for w in WANTED if not (paths.BIN_DIR / w).exists()]
    if missing:
        raise RuntimeError(f"После распаковки не хватает файлов: {missing}")

    # Из zip права не переносятся — бит исполнения ставим сами.
    exe = paths.xray_exe()
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    log(f"Готово. Ядро Xray-core {tag} установлено в bin/")
    return tag


def core_present() -> bool:
    return paths.xray_exe().exists() and paths.geoip_dat().exists() and paths.geosite_dat().exists()


# ----------------------------------------------------------------------
# Компоненты TUN — целиком на стороне демона
# ----------------------------------------------------------------------
def tun_present() -> bool:
    """Установлен ли демон и лежит ли у него sing-box."""
    from . import tun

    return tun.helper_installed() and paths.singbox_exe().exists()


def download_tun(progress: Optional[Callable[[str], None]] = None) -> str:
    """Попросить демона скачать sing-box себе. Вернуть версию.

    Сами не качаем намеренно: sing-box запускает root, и лежать он обязан там,
    куда пользователь писать не может.
    """
    from . import tun

    return tun.install_singbox(progress)
```

- [ ] **Step 4: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `10/10 проверок пройдено.` (`tun_present`/`download_tun` пока не вызываются — модуля `native.tun` ещё нет, но импортируются они лениво, внутри функций.)

- [ ] **Step 5: Проверить, что ядро реально скачивается и запускается**

```bash
cd desktop/MacOS
.venv/bin/python -c "
import sys; sys.path.insert(0, '..')
from native.downloader import download_core, core_present
download_core(print)
print('core_present:', core_present())
"
./bin/xray version
```

Expected: `./bin/xray version` печатает версию Xray. Если вместо этого `killed` или `bad CPU type` — предположение про ad-hoc подпись Go не сработало, и нужен `codesign --force --sign - bin/xray` в конце `download_core`.

- [ ] **Step 6: Commit**

```bash
git add desktop/MacOS/native/downloader.py desktop/MacOS/test_native.py
git commit -m "macOS: загрузчик ядра Xray для arm64"
```

---

### Task 6: Сборка конфига sing-box и валидация параметров

Чистые функции без root и без сети — здесь живёт граница доверия, и проверить её можно целиком.

**Files:**
- Create: `desktop/MacOS/helper/__init__.py`, `desktop/MacOS/helper/config.py`
- Modify: `desktop/MacOS/test_native.py`

**Interfaces:**
- Consumes: ничего (стандартная библиотека).
- Produces:
  - `helper.config.ValidationError(Exception)`
  - `helper.config.validate(params: dict) -> dict` — возвращает очищенные параметры или бросает `ValidationError`
  - `helper.config.build(params: dict, xray_path: str) -> dict` — конфиг sing-box
  - `helper.config.SPLIT_OFF/SPLIT_EXCLUDE/SPLIT_INCLUDE`, `helper.config.STACKS`

- [ ] **Step 1: Написать падающие проверки**

Добавить в `test_native.py`:

```python
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

    clean = validate({"socks_port": 10808, "exclude_ips": ["1.2.3.4", "не ip", "2001:db8::1"]})
    assert clean["exclude_ips"] == ["1.2.3.4", "2001:db8::1"], clean["exclude_ips"]


@check
def test_exclude_ips_become_host_routes():
    from helper.config import build, validate

    cfg = build(validate({"socks_port": 10808, "exclude_ips": ["1.2.3.4", "2001:db8::1"]}), "/x/xray")
    excludes = cfg["inbounds"][0]["route_exclude_address"]
    assert "1.2.3.4/32" in excludes, excludes
    assert "2001:db8::1/128" in excludes, excludes
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: семь `FAIL` с `ModuleNotFoundError: No module named 'helper'`.

- [ ] **Step 3: Создать `desktop/MacOS/helper/__init__.py`**

```python
"""Привилегированный компонент SCVPN для macOS.

TUN на macOS требует root. Вместо того чтобы спрашивать пароль на каждое
подключение, ставим один раз LaunchDaemon и дальше говорим с ним по
unix-сокету. Главная причина именно такая: если приложение упадёт, спросить
пароль на уборку будет уже некому, а sing-box останется держать маршруты —
и весь трафик системы уйдёт в мёртвый туннель. Демон видит обрыв соединения
с приложением и убирает за собой сам.

  config.py  — сборка конфига sing-box и валидация недоверенного ввода
  daemon.py  — сам демон: сокет, надзор за sing-box, установка sing-box
  install.py — постановка и снятие демона (единственное место с osascript)
"""
```

- [ ] **Step 4: Создать `desktop/MacOS/helper/config.py`**

```python
"""Конфиг sing-box для TUN на macOS плюс валидация того, что прислал клиент.

Почему валидация именно здесь. Демон работает от root и слушает сокет,
доступный группе admin. Всё, что приходит в сокет, — недоверенный ввод, даже
если прислало его наше же приложение. Поэтому демон не принимает готовый
конфиг: он принимает горстку параметров, проверяет каждый и собирает JSON сам.
Путь к xray сюда тоже не приходит извне — его подставляет демон.

Отличия от windows-варианта конфига:
  - нет strict_route: поле поддержано только на Linux и Windows;
  - нет interface_name: utun-устройства именует ядро, своё имя не задать;
  - wintun не нужен, TUN на macOS штатный.
"""
from __future__ import annotations

import ipaddress

# Режимы раздельного туннелирования (split tunneling).
SPLIT_OFF = "off"           # все приложения через VPN
SPLIT_EXCLUDE = "exclude"   # все через VPN, кроме выбранных
SPLIT_INCLUDE = "include"   # только выбранные через VPN
SPLIT_MODES = (SPLIT_OFF, SPLIT_EXCLUDE, SPLIT_INCLUDE)

# Сетевой стек sing-box. gvisor — свой стек в пространстве пользователя, самый
# предсказуемый на darwin; system быстрее, но опирается на хостовый стек;
# mixed — system для TCP и gvisor для UDP.
STACKS = ("gvisor", "system", "mixed")

_MAX_APP_NAME = 64


class ValidationError(ValueError):
    """Клиент прислал то, что демон не станет исполнять."""


def _port(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"порт должен быть целым числом, пришло {value!r}")
    if not 1 <= value <= 65535:
        raise ValidationError(f"порт вне диапазона: {value}")
    return value


def _app_name(value: object) -> str:
    """Имя процесса для правила sing-box. Только имя — никаких путей."""
    if not isinstance(value, str):
        raise ValidationError(f"имя приложения должно быть строкой, пришло {value!r}")
    name = value.strip()
    if not name:
        raise ValidationError("пустое имя приложения")
    if len(name) > _MAX_APP_NAME:
        raise ValidationError(f"слишком длинное имя приложения: {name[:20]}…")
    if "/" in name or "\\" in name or name in (".", ".."):
        raise ValidationError(f"имя приложения не может быть путём: {name!r}")
    return name


def validate(params: dict) -> dict:
    """Проверить параметры от клиента и вернуть очищенный набор.

    Невалидные IP молча отбрасываем — список исключений это лишь запасной
    пояс от петли, главный пояс это правило process_path для xray. А вот
    испорченный порт или режим — уже ошибка: молча подставлять умолчание
    значит поднять туннель не тем, чем просили.
    """
    clean: dict = {"socks_port": _port(params.get("socks_port"))}

    mode = params.get("split_mode", SPLIT_OFF)
    if mode not in SPLIT_MODES:
        raise ValidationError(f"неизвестный режим раздельного туннеля: {mode!r}")
    clean["split_mode"] = mode

    apps = params.get("split_apps") or []
    if not isinstance(apps, list):
        raise ValidationError("split_apps должен быть списком")
    clean["split_apps"] = [_app_name(a) for a in apps]

    stack = params.get("stack", "gvisor")
    if stack not in STACKS:
        raise ValidationError(f"неизвестный сетевой стек: {stack!r}")
    clean["stack"] = stack

    ips: list[str] = []
    for raw in params.get("exclude_ips") or []:
        try:
            ips.append(str(ipaddress.ip_address(raw)))
        except (ValueError, TypeError):
            continue
    clean["exclude_ips"] = ips

    level = params.get("log_level", "warn")
    clean["log_level"] = level if level in ("trace", "debug", "info", "warn", "error") else "warn"

    return clean


def build(params: dict, xray_path: str) -> dict:
    """Конфиг sing-box: TUN -> SOCKS Xray, плюс правила раздельного туннеля.

    Раздельное туннелирование делает сам sing-box: он умеет сопоставлять
    соединение с процессом-владельцем (`process_name`) и отправлять его либо
    в туннель, либо напрямую. Поэтому это работает только в TUN-режиме —
    системный прокси про приложения ничего не знает.

    `params` обязан быть результатом validate(): здесь проверок уже нет.
    """
    excludes = [
        f"{ip}/32" if ipaddress.ip_address(ip).version == 4 else f"{ip}/128"
        for ip in params["exclude_ips"]
    ]
    apps = params["split_apps"]
    mode = params["split_mode"]

    rules: list[dict] = []

    # Первым делом выводим из туннеля сам Xray. Без этого соединение ядра к
    # серверу снова попадает в TUN, оттуда обратно в ядро — и так по кругу.
    # Это правило переживает смену IP сервера, в отличие от списка исключений
    # ниже, поэтому оно главный пояс, а route_exclude_address — запасной.
    rules.append({"process_path": [xray_path], "outbound": "direct"})

    if apps and mode == SPLIT_EXCLUDE:
        # Выбранные — мимо VPN, всё остальное (final) — в туннель.
        rules.append({"process_name": apps, "outbound": "direct"})
    elif apps and mode == SPLIT_INCLUDE:
        # Выбранные — в туннель, всё остальное — напрямую (см. final ниже).
        rules.append({"process_name": apps, "outbound": "to-xray"})

    final = "direct" if (apps and mode == SPLIT_INCLUDE) else "to-xray"

    return {
        "log": {"level": params["log_level"]},
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.18.0.1/30"],
                "mtu": 1500,
                "auto_route": True,
                "stack": params["stack"],
                "route_exclude_address": excludes,
            }
        ],
        "outbounds": [
            {
                "type": "socks",
                "tag": "to-xray",
                "server": "127.0.0.1",
                "server_port": params["socks_port"],
                "version": "5",
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "auto_detect_interface": True,
            "final": final,
            "rules": rules,
        },
    }
```

- [ ] **Step 5: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `17/17 проверок пройдено.`

- [ ] **Step 6: Commit**

```bash
git add desktop/MacOS/helper desktop/MacOS/test_native.py
git commit -m "macOS: конфиг sing-box и валидация ввода демона"
```

---

### Task 7: Демон — сокет, надзор за sing-box, dead-man's switch

**Files:**
- Create: `desktop/MacOS/helper/daemon.py`
- Modify: `desktop/MacOS/test_native.py`

**Interfaces:**
- Consumes: `helper.config.validate/build/ValidationError`.
- Produces:
  - `helper.daemon.main() -> int` — точка входа под launchd
  - `helper.daemon.SOCKET_PATH: str`, `helper.daemon.BIN_DIR: Path`
  - `helper.daemon.check_binary(path: Path) -> None` — бросает `PermissionError`, если бинарник не root-овый
  - протокол: построчный JSON, команды `start` / `stop` / `status` / `install_singbox`

- [ ] **Step 1: Написать падающие проверки**

Добавить в `test_native.py`:

```python
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
def test_daemon_refuses_user_writable_binary(tmp=None):
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
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: четыре `FAIL` с `ModuleNotFoundError: No module named 'helper.daemon'`.

- [ ] **Step 3: Создать `desktop/MacOS/helper/daemon.py`**

```python
"""Привилегированный демон SCVPN: поднимает и стережёт sing-box.

Зачем он есть. TUN на macOS требует root. Можно было бы спрашивать пароль на
каждое подключение через osascript, но тогда остаётся дыра, из-за которой
такие клиенты и славятся нестабильностью: приложение упало или его сняли, а
sing-box работает от root и держит маршруты. Весь трафик системы уходит в
мёртвый туннель, и выглядит это как «интернет пропал». Прибить sing-box может
только root, то есть нужен ещё один диалог пароля — а показать его уже некому.

Поэтому: приложение держит открытое соединение с этим демоном всё время
работы. Оборвалось соединение — значит приложение мертво — демон сам сносит
sing-box и возвращает маршруты. Не при следующем запуске, а сразу.

Демон запускает только бинарники из своей папки, принадлежащие root и
недоступные на запись остальным: сокет открыт группе admin, а всё, что
оттуда приходит, — недоверенный ввод (см. config.validate).

Только стандартная библиотека: демон должен подниматься даже когда с
приложением что-то не так.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.request
from pathlib import Path
from typing import Any, Callable

from .config import ValidationError, build, validate

SOCKET_PATH = "/var/run/scvpn-helper.sock"
HELPER_DIR = Path("/Library/Application Support/SCVPN")
BIN_DIR = HELPER_DIR / "bin"
RUN_DIR = HELPER_DIR / "run"

SINGBOX_RELEASES_API = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# Группа, которой открыт сокет. Обычные пользователи в неё не входят.
_ADMIN_GROUP = "admin"


def log(msg: str) -> None:
    """В stderr — launchd сложит его в StandardErrorPath."""
    print(f"[helper] {msg}", file=sys.stderr, flush=True)


# ----------------------------------------------------------------------
# Проверка бинарника перед запуском
# ----------------------------------------------------------------------
def check_binary(path: Path) -> None:
    """Убедиться, что это наш бинарник и подменить его пользователь не мог.

    Демон работает от root. Запустить файл, в который может писать обычный
    пользователь, значит отдать ему root — поэтому три проверки: файл лежит в
    нашей папке, принадлежит root, и не доступен на запись группе и остальным.
    """
    try:
        resolved = path.resolve(strict=True)
    except OSError as e:
        raise PermissionError(f"нет такого бинарника: {path} ({e})") from e

    if not resolved.is_relative_to(BIN_DIR.resolve()):
        raise PermissionError(f"бинарник вне {BIN_DIR}: {resolved}")

    st = resolved.stat()
    if st.st_uid != 0:
        raise PermissionError(f"бинарник не принадлежит root: {resolved}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise PermissionError(f"бинарник доступен на запись не только root: {resolved}")
    if not st.st_mode & stat.S_IXUSR:
        raise PermissionError(f"бинарник не исполняемый: {resolved}")


# ----------------------------------------------------------------------
# Установка sing-box (демон качает его себе сам)
# ----------------------------------------------------------------------
def pick_singbox_asset(assets: list[dict]) -> str:
    """URL архива sing-box для darwin/arm64 из списка ассетов релиза."""
    for asset in assets:
        name = asset.get("name", "")
        if name.endswith("darwin-arm64.tar.gz"):
            return asset["browser_download_url"]
    raise RuntimeError("в релизе sing-box не найден архив darwin-arm64.tar.gz")


def install_singbox(say: Callable[[str], None]) -> str:
    """Скачать sing-box в свою папку. Вернуть версию."""
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    os.chown(HELPER_DIR, 0, 0)
    os.chown(BIN_DIR, 0, 0)
    BIN_DIR.chmod(0o755)

    say("Узнаю последнюю версию sing-box…")
    req = urllib.request.Request(
        SINGBOX_RELEASES_API, headers={"Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310
        data = json.loads(r.read().decode())
    tag = data.get("tag_name", "?")
    url = pick_singbox_asset(data.get("assets", []))

    say(f"Версия sing-box {tag}. Скачиваю…")
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "sing-box.tar.gz"
        with urllib.request.urlopen(url, timeout=180) as r, archive.open("wb") as f:  # noqa: S310
            shutil.copyfileobj(r, f)

        say("Распаковываю…")
        found = None
        with tarfile.open(archive) as t:
            for member in t.getmembers():
                if member.isfile() and Path(member.name).name == "sing-box":
                    extracted = t.extractfile(member)
                    if extracted is None:
                        continue
                    found = Path(tmp) / "sing-box"
                    found.write_bytes(extracted.read())
                    break
        if found is None:
            raise RuntimeError("sing-box не найден в архиве")

        target = BIN_DIR / "sing-box"
        shutil.move(str(found), str(target))

    # root:wheel 0755 — иначе check_binary откажется его запускать, и правильно.
    os.chown(target, 0, 0)
    target.chmod(0o755)
    say(f"Готово. sing-box {tag} установлен.")
    return tag


# ----------------------------------------------------------------------
# Надзор за sing-box
# ----------------------------------------------------------------------
class Supervisor:
    """Один живой sing-box и его конфиг. Останавливается при обрыве клиента."""

    def __init__(self) -> None:
        self.proc: subprocess.Popen | None = None
        self._reader: threading.Thread | None = None
        self._on_log: Callable[[str], None] = lambda s: None

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, params: dict, xray_path: str, on_log: Callable[[str], None]) -> None:
        if self.running:
            self.stop()

        exe = BIN_DIR / "sing-box"
        check_binary(exe)

        RUN_DIR.mkdir(parents=True, exist_ok=True)
        RUN_DIR.chmod(0o700)
        cfg_path = RUN_DIR / "singbox.json"
        cfg_path.write_text(
            json.dumps(build(params, xray_path), ensure_ascii=False, indent=2), encoding="utf-8"
        )
        cfg_path.chmod(0o600)

        self._on_log = on_log
        self.proc = subprocess.Popen(
            [str(exe), "run", "-c", str(cfg_path)],
            cwd=str(BIN_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        log(f"sing-box запущен, PID {self.proc.pid}")
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()

    def _pump(self) -> None:
        proc = self.proc
        if proc is None or proc.stdout is None:
            return
        for line in proc.stdout:
            line = line.rstrip("\n")
            if line:
                self._on_log(line)
        code = proc.poll()
        self._on_log(f"sing-box завершился (код {code})")
        log(f"sing-box завершился (код {code})")

    def stop(self) -> None:
        proc = self.proc
        self.proc = None
        if proc is None or proc.poll() is not None:
            return
        log("останавливаю sing-box (маршруты вернутся сами)")
        try:
            proc.terminate()
            try:
                proc.wait(timeout=7)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
        except Exception as e:  # noqa: BLE001
            log(f"ошибка остановки: {e}")


SUPERVISOR = Supervisor()


# ----------------------------------------------------------------------
# Протокол
# ----------------------------------------------------------------------
def handle_line(line: str, state: dict[str, Any]) -> dict:
    """Разобрать одну строку запроса и выполнить её. Всегда возвращает ответ.

    Демон не имеет права падать от кривого ввода: клиент — недоверенный, а
    падение демона означает, что sing-box останется без надзора.
    """
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError("ожидался объект")
    except ValueError as e:
        return {"ok": False, "error": f"не разобрал запрос: {e}"}

    cmd = req.get("cmd")
    say: Callable[[str], None] = state.get("say") or (lambda s: None)

    try:
        if cmd == "start":
            params = validate(req)
            xray_path = str(BIN_DIR / "xray-placeholder")
            # Путь к xray не берём у клиента: правило process_path даёт
            # процессу прямой выход мимо туннеля, и подставить туда чужой
            # бинарник значило бы раздать обход VPN кому попало.
            xray_path = state.get("xray_path") or xray_path
            SUPERVISOR.start(params, xray_path, say)
            return {"ok": True, "running": True}

        if cmd == "stop":
            SUPERVISOR.stop()
            return {"ok": True, "running": False}

        if cmd == "status":
            return {"ok": True, "running": SUPERVISOR.running,
                    "singbox": (BIN_DIR / "sing-box").exists()}

        if cmd == "install_singbox":
            tag = install_singbox(say)
            return {"ok": True, "version": tag}

        return {"ok": False, "error": f"неизвестная команда: {cmd!r}"}

    except ValidationError as e:
        return {"ok": False, "error": str(e)}
    except PermissionError as e:
        return {"ok": False, "error": f"отказано: {e}"}
    except Exception as e:  # noqa: BLE001
        log(f"ошибка при обработке {cmd!r}: {e}")
        return {"ok": False, "error": str(e)}


def serve_client(conn: socket.socket) -> None:
    """Обслужить одного клиента и прибрать за ним, когда он отвалится.

    Обрыв соединения — это и есть dead-man's switch: приложение мертво,
    значит туннель надо снять, иначе система останется без интернета.
    """
    lock = threading.Lock()

    def send(obj: dict) -> None:
        with lock:
            try:
                conn.sendall((json.dumps(obj, ensure_ascii=False) + "\n").encode())
            except OSError:
                pass

    state: dict[str, Any] = {"say": lambda s: send({"log": s})}

    try:
        with conn.makefile("r", encoding="utf-8") as reader:
            for line in reader:
                line = line.strip()
                if not line:
                    continue
                if line.startswith("{") and '"xray_path"' in line:
                    # Клиент сообщает, где лежит его ядро, при первом запросе.
                    try:
                        candidate = json.loads(line).get("xray_path")
                        if isinstance(candidate, str) and candidate.startswith("/"):
                            state["xray_path"] = candidate
                    except ValueError:
                        pass
                send(handle_line(line, state))
    except OSError as e:
        log(f"соединение оборвалось: {e}")
    finally:
        if SUPERVISOR.running:
            log("клиент отключился, а туннель поднят — снимаю его")
            SUPERVISOR.stop()
        try:
            conn.close()
        except OSError:
            pass


def main() -> int:
    if os.geteuid() != 0:
        log("демон обязан работать от root")
        return 1

    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCKET_PATH)

    # Открываем сокет группе admin и только ей: обычный пользователь не должен
    # уметь поднять туннель и подсунуть свои правила маршрутизации.
    import grp

    os.chown(SOCKET_PATH, 0, grp.getgrnam(_ADMIN_GROUP).gr_gid)
    os.chmod(SOCKET_PATH, 0o660)

    srv.listen(4)
    log(f"слушаю {SOCKET_PATH}")

    # ponytail: клиентов обслуживаем по одному в потоке, без ограничения их
    # числа. Приложение открывает ровно одно соединение; если понадобится
    # защита от заваливания, ставить семафор на число живых потоков.
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=serve_client, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        SUPERVISOR.stop()
        srv.close()
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
    return 0
```

- [ ] **Step 4: Упростить передачу пути к xray**

Приведённый выше `handle_line` разбирает `xray_path` в двух местах — это остаток черновика. Заменить блок в `serve_client`, который парсит строку повторно, и вместо него принять путь как поле команды `start`, провалидировав его в `handle_line`:

В `handle_line`, ветка `start`, заменить три строки про `xray_path` на:

```python
        if cmd == "start":
            params = validate(req)
            # Путь к ядру приходит от клиента, но правило process_path даёт
            # процессу выход мимо туннеля — значит путь надо проверить, а не
            # принять на слово. Разрешаем только существующий файл с именем
            # xray внутри домашней папки того, кто нас позвал.
            xray_path = _checked_xray_path(req.get("xray_path"))
            SUPERVISOR.start(params, xray_path, say)
            return {"ok": True, "running": True}
```

И добавить функцию рядом с `check_binary`:

```python
def _checked_xray_path(raw: object) -> str:
    """Проверить путь к ядру Xray, присланный клиентом.

    Этот путь попадает в правило process_path, которое выпускает процесс мимо
    туннеля. Подставив туда чужой бинарник, злоумышленник раздал бы себе обход
    VPN — поэтому проверяем и имя, и что файл существует.
    """
    if not isinstance(raw, str) or not raw.startswith("/"):
        raise ValidationError(f"путь к ядру должен быть абсолютным, пришло {raw!r}")
    path = Path(raw)
    if path.name != "xray":
        raise ValidationError(f"ожидался бинарник с именем xray, пришло {path.name!r}")
    if not path.is_file():
        raise ValidationError(f"нет такого файла: {path}")
    return str(path.resolve())
```

Из `serve_client` удалить весь блок `if line.startswith("{") and '"xray_path"' in line:` вместе с телом, оставив цикл таким:

```python
        with conn.makefile("r", encoding="utf-8") as reader:
            for line in reader:
                line = line.strip()
                if not line:
                    continue
                send(handle_line(line, state))
```

Добавить в `test_native.py`:

```python
@check
def test_daemon_rejects_foreign_xray_path():
    from helper.daemon import handle_line

    for bad in (None, "relative/xray", "/bin/sh", "/tmp/не-существует/xray"):
        reply = handle_line(json.dumps({"cmd": "start", "socks_port": 10808, "xray_path": bad}), {})
        assert reply["ok"] is False, (bad, reply)
```

и `import json` в шапку `test_native.py`.

- [ ] **Step 5: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `22/22 проверок пройдено.`

- [ ] **Step 6: Commit**

```bash
git add desktop/MacOS/helper/daemon.py desktop/MacOS/test_native.py
git commit -m "macOS: демон TUN с надзором за sing-box и снятием по обрыву клиента"
```

---

### Task 8: Постановка и снятие демона

**Files:**
- Create: `desktop/MacOS/helper/install.py`, `desktop/MacOS/helper/com.scvpn.helper.plist`

**Interfaces:**
- Consumes: `native.paths.HELPER_PLIST`, `.HELPER_LABEL`, `.HELPER_DIR`, `.FROZEN`, `.ROOT`.
- Produces: `helper.install.installed() -> bool`, `helper.install.install() -> None` (бросает `RuntimeError` с понятным текстом), `helper.install.uninstall() -> None`, `helper.install.plist_text() -> str`.

- [ ] **Step 1: Написать падающие проверки**

Добавить в `test_native.py`:

```python
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
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: два `FAIL` с `ModuleNotFoundError: No module named 'helper.install'`.

- [ ] **Step 3: Создать `desktop/MacOS/helper/install.py`**

```python
"""Постановка и снятие привилегированного демона SCVPN.

Единственное место во всём приложении, где спрашивается пароль администратора,
и спрашивается он один раз за установку. Дальше приложение говорит с демоном
по сокету и никаких повышений прав не просит.

Скрипт установки собирается здесь и целиком отдаётся osascript одной строкой:
так пользователь видит один системный диалог, а не череду.
"""
from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path

from native import paths


def program_arguments() -> list[str]:
    """Чем launchd будет запускать демона.

    В собранном .app это сам исполняемый файл бандла с флагом --helper —
    отдельный интерпретатор Python в системе поэтому не нужен. При запуске из
    исходников это python из venv и тот же run.py.
    """
    if paths.FROZEN:
        return [sys.executable, "--helper"]
    return [sys.executable, str(paths.ROOT / "run.py"), "--helper"]


def plist_text() -> str:
    """Содержимое com.scvpn.helper.plist для текущей сборки."""
    data = {
        "Label": paths.HELPER_LABEL,
        "ProgramArguments": program_arguments(),
        "RunAtLoad": True,
        # Демон должен пережить собственное падение: пока он мёртв, sing-box
        # остался бы без надзора.
        "KeepAlive": True,
        "StandardErrorPath": "/var/log/scvpn-helper.log",
        "StandardOutPath": "/var/log/scvpn-helper.log",
    }
    return plistlib.dumps(data).decode()


def installed() -> bool:
    return paths.HELPER_PLIST.exists()


def _osascript(script: str, prompt: str) -> None:
    """Выполнить shell-скрипт от администратора одним системным диалогом."""
    r = subprocess.run(
        ["osascript", "-e",
         f'do shell script {json.dumps(script)} with prompt {json.dumps(prompt)} '
         f'with administrator privileges'],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        err = (r.stderr or "").strip()
        if "User canceled" in err or "-128" in err:
            raise RuntimeError("Установка отменена.")
        raise RuntimeError(err or "не удалось выполнить установку")


def install() -> None:
    """Поставить демона. Спросит пароль администратора — один раз."""
    tmp = paths.DATA_DIR / "com.scvpn.helper.plist"
    paths.ensure_dirs()
    tmp.write_text(plist_text(), encoding="utf-8")

    script = "; ".join([
        f"mkdir -p {shlex.quote(str(paths.HELPER_DIR))}",
        f"chown root:wheel {shlex.quote(str(paths.HELPER_DIR))}",
        f"chmod 755 {shlex.quote(str(paths.HELPER_DIR))}",
        f"cp {shlex.quote(str(tmp))} {shlex.quote(str(paths.HELPER_PLIST))}",
        f"chown root:wheel {shlex.quote(str(paths.HELPER_PLIST))}",
        f"chmod 644 {shlex.quote(str(paths.HELPER_PLIST))}",
        # bootout молча падает, если демона ещё нет — отсюда || true.
        f"launchctl bootout system/{paths.HELPER_LABEL} 2>/dev/null || true",
        f"launchctl bootstrap system {shlex.quote(str(paths.HELPER_PLIST))}",
    ])
    _osascript(script, "SCVPN устанавливает системный компонент для TUN-режима")
    tmp.unlink(missing_ok=True)


def uninstall() -> None:
    """Снять демона и убрать всё, что он у себя положил."""
    script = "; ".join([
        f"launchctl bootout system/{paths.HELPER_LABEL} 2>/dev/null || true",
        f"rm -f {shlex.quote(str(paths.HELPER_PLIST))}",
        f"rm -rf {shlex.quote(str(paths.HELPER_DIR))}",
        f"rm -f {shlex.quote(str(paths.HELPER_SOCKET))}",
    ])
    _osascript(script, "SCVPN удаляет системный компонент")
```

Добавить в шапку импорты `json` и `shlex`:

```python
import json
import plistlib
import shlex
import subprocess
import sys
```

- [ ] **Step 4: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `25/25 проверок пройдено.`

- [ ] **Step 5: Поставить демона руками и убедиться, что он живой**

```bash
cd desktop/MacOS
.venv/bin/python -c "
import sys; sys.path.insert(0, '..')
from helper.install import install, installed
install(); print('installed:', installed())
"
sudo launchctl print system/com.scvpn.helper | head -20
ls -l /var/run/scvpn-helper.sock
```

Expected: `launchctl print` показывает `state = running`, сокет существует с правами `srw-rw----` и группой `admin`.

- [ ] **Step 6: Проверить dead-man's switch вручную**

```bash
# Открыть соединение, спросить статус, оборвать — демон должен пережить обрыв.
python3 - <<'PY'
import json, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/var/run/scvpn-helper.sock")
s.sendall(b'{"cmd":"status"}\n')
print(s.recv(4096).decode().strip())
s.close()
PY
sudo launchctl print system/com.scvpn.helper | grep -E "state|pid"
```

Expected: приходит `{"ok": true, "running": false, "singbox": false}`, и демон после обрыва по-прежнему `running`.

- [ ] **Step 7: Commit**

```bash
git add desktop/MacOS/helper/install.py
git commit -m "macOS: постановка и снятие демона одним диалогом пароля"
```

---

### Task 9: Клиент демона — native/tun.py

**Files:**
- Create: `desktop/MacOS/native/tun.py`
- Modify: `desktop/MacOS/test_native.py`

**Interfaces:**
- Consumes: `helper.install`, `native.paths`, `shared.models.Server`.
- Produces: полный контракт `native.tun` (`SPLIT_*`, `PRIVILEGE_QUESTION`, `privileged`, `acquire_privilege`, `cleanup_stray`, `Tun`) плюс `helper_installed()` и `install_singbox(progress)` для `native.downloader`.

- [ ] **Step 1: Написать падающие проверки**

Добавить в `test_native.py`:

```python
@check
def test_tun_contract_matches_windows():
    """shared/ знает только контракт — обе платформы обязаны его закрывать."""
    from native import tun

    for name in ("SPLIT_OFF", "SPLIT_EXCLUDE", "SPLIT_INCLUDE", "PRIVILEGE_QUESTION",
                 "privileged", "acquire_privilege", "cleanup_stray", "Tun"):
        assert hasattr(tun, name), f"в native.tun нет {name}"
    t = tun.Tun()
    assert t.running is False


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
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: три `FAIL` с `ModuleNotFoundError: No module named 'native.tun'`.

- [ ] **Step 3: Создать `desktop/MacOS/native/tun.py`**

```python
"""TUN-режим для macOS: весь трафик устройства идёт через VPN.

Как устроено:
  - Xray уже работает от имени пользователя и слушает локальный SOCKS (как в
    режиме прокси) — именно он делает TLS/Reality-рукопожатие с сервером. Этот
    путь одинаков в обоих режимах, поэтому автоподбор отпечатка остаётся в силе.
  - sing-box поднимает utun-адаптер, забирает ВЕСЬ трафик системы и заворачивает
    его в этот локальный SOCKS Xray. Он требует root, поэтому запускает его не
    приложение, а привилегированный демон (см. helper/).
  - Чтобы не было петли, у sing-box есть правило process_path для бинарника
    Xray — его соединения идут напрямую. Запасной пояс — route_exclude_address
    с IP сервера.

Этот модуль — тонкий клиент демона. Соединение держится открытым всё время
работы приложения: его обрыв демон читает как «приложение мертво» и снимает
туннель сам. Это главное отличие от windows-версии, где ядро живёт под нами.
"""
from __future__ import annotations

import json
import os
import signal
import socket
import threading
from typing import Callable, Optional

from helper.config import SPLIT_EXCLUDE, SPLIT_INCLUDE, SPLIT_OFF  # noqa: F401
from helper.install import install as _install_helper
from helper.install import installed as helper_installed
from shared.models import Server

from . import paths

PRIVILEGE_QUESTION = (
    "TUN-режим (весь трафик) работает через системный компонент,\n"
    "который нужно установить один раз. Понадобится пароль администратора.\n\n"
    "Установить сейчас?"
)


def privileged() -> bool:
    """Можно ли прямо сейчас поднять TUN. На macOS это установленный демон."""
    return helper_installed()


def acquire_privilege() -> str:
    """Поставить демона. "ok" — можно продолжать в этом же процессе."""
    try:
        _install_helper()
    except RuntimeError:
        return "failed"
    return "ok" if helper_installed() else "failed"


# ----------------------------------------------------------------------
# Резолв IP сервера (для обходного маршрута)
# ----------------------------------------------------------------------
def resolve_ips(host: str) -> list[str]:
    """Список IPv4-адресов хоста. Если host уже IP — вернуть его."""
    try:
        socket.inet_aton(host)
        return [host]  # уже IPv4
    except OSError:
        pass
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET)
        return sorted({i[4][0] for i in infos})
    except Exception:  # noqa: BLE001
        return []


# ----------------------------------------------------------------------
# Уборка за прошлым запуском
# ----------------------------------------------------------------------
def cleanup_stray(log: Optional[Callable[[str], None]] = None) -> bool:
    """Прибить ядро Xray, пережившее прошлый запуск приложения.

    Про sing-box здесь заботиться не нужно: он под надзором демона, и демон
    снимает его сам, как только обрывается соединение с приложением. Остаётся
    Xray — он живёт от пользователя, и его мы можем снять сами.
    """
    say = log or (lambda s: None)
    f = paths.DATA_DIR / "xray.pid"
    if not f.exists():
        return False
    try:
        pid = int(f.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        f.unlink(missing_ok=True)
        return False

    # Имя образа сверяем обязательно: номера процессов переиспользуются, и без
    # этой сверки мы могли бы прибить чужой процесс, случайно получивший тот же.
    if not _process_is_xray(pid):
        f.unlink(missing_ok=True)
        return False

    say(f"[*] С прошлого запуска остался xray (PID {pid}) — убираю.")
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        say(f"[!] Не удалось: {e}")
        return False
    f.unlink(missing_ok=True)
    return True


def _process_is_xray(pid: int) -> bool:
    import subprocess

    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return out.rsplit("/", 1)[-1] == "xray"


# ----------------------------------------------------------------------
# Соединение с демоном
# ----------------------------------------------------------------------
class HelperError(RuntimeError):
    pass


class _Connection:
    """Одно соединение с демоном. Живёт, пока живёт туннель."""

    def __init__(self, on_log: Callable[[str], None]) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(str(paths.HELPER_SOCKET))
        except OSError as e:
            raise HelperError(
                f"Системный компонент не отвечает ({e}).\n"
                "Меню «⋯» → «Переустановить системный компонент»."
            ) from e
        self._file = self.sock.makefile("r", encoding="utf-8")
        self._on_log = on_log

    def request(self, payload: dict, timeout: float = 240.0) -> dict:
        """Отправить команду и дождаться ответа. Строки log по пути отдаём наружу."""
        self.sock.settimeout(timeout)
        self.sock.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode())
        for line in self._file:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "log" in msg:
                self._on_log(msg["log"])
                continue
            return msg
        raise HelperError("Системный компонент закрыл соединение.")

    def close(self) -> None:
        try:
            self._file.close()
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def install_singbox(progress: Optional[Callable[[str], None]] = None) -> str:
    """Попросить демона скачать sing-box себе. Вернуть версию."""
    say = progress or (lambda s: None)
    if not helper_installed():
        raise HelperError("Сначала установи системный компонент (включи TUN-режим).")
    conn = _Connection(say)
    try:
        reply = conn.request({"cmd": "install_singbox"})
    finally:
        conn.close()
    if not reply.get("ok"):
        raise HelperError(reply.get("error", "не удалось установить sing-box"))
    return reply.get("version", "?")


# ----------------------------------------------------------------------
# Туннель
# ----------------------------------------------------------------------
class Tun:
    def __init__(
        self,
        on_log: Optional[Callable[[str], None]] = None,
        on_state: Optional[Callable[[bool], None]] = None,
    ) -> None:
        self._conn: Optional[_Connection] = None
        self._pump: Optional[threading.Thread] = None
        self._running = False
        self.on_log = on_log or (lambda s: None)
        self.on_state = on_state or (lambda running: None)

    @property
    def running(self) -> bool:
        return self._running

    def start(
        self,
        server: Server,
        socks_port: int,
        split_mode: str = SPLIT_OFF,
        split_apps: list[str] | None = None,
    ) -> None:
        if not helper_installed():
            raise HelperError("Системный компонент не установлен.")

        ips = resolve_ips(server.address)
        if not ips:
            self.on_log(f"[tun] не удалось определить IP сервера {server.address}, маршрут-исключение пуст")
        else:
            self.on_log(f"[tun] обход для IP сервера: {', '.join(ips)}")

        apps = split_apps or []
        if split_mode != SPLIT_OFF and apps:
            what = "мимо VPN" if split_mode == SPLIT_EXCLUDE else "через VPN"
            self.on_log(f"[tun] раздельный туннель: {what} — {', '.join(apps)}")

        conn = _Connection(lambda s: self.on_log("[tun] " + s))
        reply = conn.request({
            "cmd": "start",
            "socks_port": socks_port,
            "exclude_ips": ips,
            "split_mode": split_mode,
            "split_apps": apps,
            "xray_path": str(paths.xray_exe().resolve()),
        }, timeout=60.0)
        if not reply.get("ok"):
            conn.close()
            raise HelperError(reply.get("error", "не удалось поднять TUN"))

        self._conn = conn
        self._running = True
        self.on_log("[tun] sing-box запущен (поднимаю utun-адаптер)…")
        self.on_state(True)

        # Соединение остаётся открытым: демон читает его обрыв как «приложение
        # мертво» и снимает туннель сам. Поток дочитывает лог sing-box.
        self._pump = threading.Thread(target=self._read_logs, daemon=True)
        self._pump.start()

    def _read_logs(self) -> None:
        conn = self._conn
        if conn is None:
            return
        try:
            conn.sock.settimeout(None)
            for line in conn._file:  # noqa: SLF001
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if "log" in msg:
                    self.on_log("[tun] " + msg["log"])
        except OSError:
            pass
        if self._running:
            self._running = False
            self.on_log("[tun] системный компонент закрыл соединение")
            self.on_state(False)

    def stop(self) -> None:
        conn = self._conn
        self._conn = None
        if conn is None:
            if self._running:
                self._running = False
                self.on_state(False)
            return
        self.on_log("[tun] останавливаю туннель (маршруты вернутся сами)…")
        self._running = False
        try:
            conn.request({"cmd": "stop"}, timeout=15.0)
        except (HelperError, OSError) as e:
            self.on_log(f"[tun] ошибка остановки: {e}")
        finally:
            # Закрытие соединения — второй, независимый способ снять туннель:
            # даже если команда stop не дошла, демон увидит обрыв и уберёт всё.
            conn.close()
        self.on_state(False)
```

- [ ] **Step 4: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `28/28 проверок пройдено.`

- [ ] **Step 5: Проверить установку sing-box через демона**

```bash
cd desktop/MacOS
.venv/bin/python -c "
import sys; sys.path.insert(0, '..')
from native.tun import install_singbox
print('версия:', install_singbox(print))
"
ls -l@ "/Library/Application Support/SCVPN/bin/sing-box"
```

Expected: файл существует, владелец `root  wheel`, права `-rwxr-xr-x`.

- [ ] **Step 6: Commit**

```bash
git add desktop/MacOS/native/tun.py desktop/MacOS/test_native.py
git commit -m "macOS: клиент демона TUN, соединение как dead-man's switch"
```

---

### Task 10: Список приложений для раздельного туннелирования

**Files:**
- Create: `desktop/MacOS/native/apps.py`
- Modify: `desktop/MacOS/test_native.py`

**Interfaces:**
- Consumes: ничего.
- Produces: `native.apps.MANUAL_HINT: str`, `.running_apps() -> list[str]`, `.normalize(name) -> str`.

- [ ] **Step 1: Написать падающие проверки**

Добавить в `test_native.py`:

```python
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
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `cd desktop/MacOS && ./test.sh`
Expected: два `FAIL` с `ModuleNotFoundError: No module named 'native.apps'`.

- [ ] **Step 3: Создать `desktop/MacOS/native/apps.py`**

```python
"""Список запущенных приложений для правил раздельного туннелирования.

sing-box сопоставляет соединение с процессом-владельцем по имени
исполняемого файла — для macOS это файл внутри бандла, то есть Telegram.app
даёт имя «Telegram», а не «Telegram.app».

Берём только процессы из /Applications: в системе их под тысячу, и показывать
пользователю системные демоны бессмысленно. Расширения (.appex — виджеты,
шаринг и прочее) тоже отбрасываем: это не то, что человек хочет выбрать в
списке приложений.
"""
from __future__ import annotations

import subprocess

MANUAL_HINT = "Имя приложения (например, Telegram):"


def running_apps() -> list[str]:
    """Имена запущенных приложений из /Applications, без дубликатов."""
    try:
        out = subprocess.run(
            ["ps", "-axo", "comm="], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    names: set[str] = set()
    for line in out.splitlines():
        path = line.strip()
        if not path.startswith("/Applications/") or ".appex/" in path:
            continue
        name = path.rsplit("/", 1)[-1]
        if name:
            names.add(name)
    return sorted(names, key=str.lower)


def normalize(name: str) -> str:
    """Привести введённое руками имя к виду, который поймёт правило sing-box."""
    name = name.strip().rstrip("/")
    name = name.rsplit("/", 1)[-1]
    if name.endswith(".app"):
        name = name[: -len(".app")]
    return name
```

- [ ] **Step 4: Запустить проверки**

Run: `cd desktop/MacOS && ./test.sh`
Expected: `30/30 проверок пройдено.`

- [ ] **Step 5: Commit**

```bash
git add desktop/MacOS/native/apps.py desktop/MacOS/test_native.py
git commit -m "macOS: перечисление приложений для раздельного туннелирования"
```

---

### Task 11: Подключить macOS к интерфейсу

**Files:**
- Modify: `desktop/shared/ui/main_window.py`
- Modify: `desktop/shared/ui/theme.py`
- Modify: `desktop/shared/ui/split_dialog.py`
- Modify: `desktop/shared/storage.py`

**Interfaces:**
- Consumes: контракт `native` целиком.
- Produces: рабочее приложение на macOS; новая настройка `tun_stack` (`"gvisor"` по умолчанию).

- [ ] **Step 1: Заменить проверку прав в `connect_vpn()`**

В `shared/ui/main_window.py` заменить блок префлайта TUN (в исходнике строки 389–412) на:

```python
        # Префлайт для TUN: нужны компоненты и повышенные права.
        mode = self.settings.get("vpn_mode", "proxy")
        if mode == "tun":
            if not privileged():
                r = QMessageBox.question(self, "Нужны права администратора", PRIVILEGE_QUESTION)
                if r != QMessageBox.Yes:
                    return
                outcome = acquire_privilege()
                if outcome == "restart":
                    QApplication.quit()
                    return
                if outcome != "ok":
                    QMessageBox.warning(self, "Не вышло", "Не удалось получить права администратора.")
                    return
            if not tun_present():
                QMessageBox.warning(
                    self, "Нет компонентов TUN",
                    "Меню «⋯» → «Скачать компоненты TUN».",
                )
                return
```

Порядок поменялся намеренно: на macOS `tun_present()` спрашивает у демона, поэтому сначала демон, потом компоненты. На Windows порядок безразличен.

- [ ] **Step 2: Передать выбранный сетевой стек в туннель**

В `shared/ui/main_window.py`, в `_start_with_fingerprint`, в вызове `self.tun.start(...)` ничего не меняется — стек не входит в контракт `Tun.start`. Вместо этого macOS-клиент читает настройку сам. Добавить в `desktop/MacOS/native/tun.py`, в `Tun.start`, перед `conn.request`:

```python
        from shared.storage import load_settings

        stack = load_settings().get("tun_stack", "gvisor")
```

и передать `"stack": stack` в словарь запроса.

- [ ] **Step 3: Добавить настройку стека в меню и умолчания**

В `shared/storage.py`, в `DEFAULT_SETTINGS`, после `"split_apps": []` добавить:

```python
    "tun_stack": "gvisor",     # сетевой стек sing-box в TUN (только macOS)
```

В `shared/ui/main_window.py`, в сборке меню, после группы «Отпечаток TLS» добавить:

```python
        if sys.platform == "darwin":
            # Сетевой стек TUN — тот самый винт, который приходится крутить,
            # когда туннель ведёт себя странно на конкретной сети.
            self._radio_group(
                menu.addMenu("Сетевой стек TUN"),
                [("gvisor — самый предсказуемый", "gvisor"),
                 ("system — быстрее", "system"),
                 ("mixed — TCP системный, UDP gvisor", "mixed")],
                "tun_stack", "gvisor",
            )
```

и `import sys` в шапку модуля.

- [ ] **Step 4: Добавить пункт удаления системного компонента**

В `shared/ui/main_window.py`, рядом с «Скачать компоненты TUN», добавить:

```python
        if sys.platform == "darwin":
            menu.addAction("Удалить системный компонент…", self._remove_helper)
```

и метод рядом с `_download_tun`:

```python
    def _remove_helper(self) -> None:
        """Снять привилегированный демон TUN (только macOS)."""
        r = QMessageBox.question(
            self, "Удалить системный компонент",
            "TUN-режим перестанет работать, пока компонент не установят заново.\n"
            "Удалить? Понадобится пароль администратора.",
        )
        if r != QMessageBox.Yes:
            return
        self.disconnect_vpn()
        from helper.install import uninstall

        try:
            uninstall()
        except RuntimeError as e:
            QMessageBox.warning(self, "Не вышло", str(e))
            return
        self._append_log("[*] Системный компонент удалён.")
```

- [ ] **Step 5: Поправить шрифты в `shared/ui/theme.py`**

Заменить `font-family: "Segoe UI", sans-serif;` на подстановку по платформе. В начало модуля:

```python
import sys

# Системный шрифт интерфейса: на macOS это SF, на Windows — Segoe UI.
UI_FONT = '-apple-system, "SF Pro Text"' if sys.platform == "darwin" else '"Segoe UI"'
MONO_FONT = "Menlo" if sys.platform == "darwin" else "Consolas"
```

Далее в шаблоне стилей заменить `font-family: "Segoe UI", sans-serif;` на `font-family: {UI_FONT}, sans-serif;` и `font-family: Consolas, monospace;` на `font-family: {MONO_FONT}, monospace;`. Проверить, что шаблон — f-строка; если нет, обернуть места подстановки так же, как это сделано для цветов.

Те же две замены `Consolas` есть в `shared/ui/subscription_dialog.py` (строка 208) и `shared/ui/add_dialog.py` (строка 51) — там заменить на `theme.MONO_FONT`.

- [ ] **Step 6: Поправить текст в `shared/ui/split_dialog.py`**

Строка про системный прокси упоминает Windows. Заменить на нейтральное:

```python
            "системный прокси приложения не различает."
```

Шапку модуля (строки 13–17) поправить так, чтобы `.exe` не фигурировал как единственный вариант — заменить упоминание `.exe` на «исполняемый файл».

- [ ] **Step 7: Запустить приложение и проверить руками**

```bash
cd desktop/MacOS && .venv/bin/python run.py
```

Проверить: окно открывается, меню «⋯» показывает «Сетевой стек TUN» и «Удалить системный компонент…», добавление ссылки работает, скачивание ядра работает, подключение в режиме прокси поднимается и `networksetup -getwebproxy Wi-Fi` показывает `127.0.0.1`, отключение возвращает `Enabled: No`.

- [ ] **Step 8: Проверить TUN целиком**

Подключиться в режиме TUN. Проверить:

```bash
ifconfig | grep -A3 utun          # появился адаптер
curl -s https://api.ipify.org      # адрес сервера, а не свой
```

Затем проверить главное — dead-man's switch:

```bash
pkill -9 -f "run.py"               # приложение снято жёстко
sleep 3
pgrep -fl sing-box                 # должно быть пусто
curl -s -m 10 https://api.ipify.org  # интернет на месте, адрес свой
```

Expected: sing-box снят демоном, интернет работает. Это тот самый сценарий, ради которого выбран демон, — если он не отработал, дальше идти нельзя.

- [ ] **Step 9: Проверить раздельное туннелирование**

Включить режим «только выбранные через VPN», выбрать один браузер, подключиться. В браузере адрес должен быть серверный, в `curl` из терминала — свой. Если правила `process_name` на darwin не срабатывают, пометить это в `MacOS/README.md` как неподдерживаемое и отключить пункт меню на macOS, а не оставлять молча неработающим.

- [ ] **Step 10: Commit**

```bash
git add desktop/shared desktop/MacOS
git commit -m "macOS: подключил платформенный слой к интерфейсу"
```

---

### Task 12: Иконка

**Files:**
- Create: `desktop/MacOS/setup/scvpn.icns`
- Create: `desktop/MacOS/setup/README.md`

**Interfaces:**
- Consumes: `desktop/Windows/setup/brand.py`.
- Produces: готовый `scvpn.icns` в git.

- [ ] **Step 1: Отрисовать iconset и свернуть в icns**

Иконка делается **один раз** и кладётся в git готовой. Скрипт ниже не сохраняется в репозиторий — он выполняется разово.

```bash
cd desktop
python3 -m venv /tmp/icon-venv && /tmp/icon-venv/bin/pip install -q Pillow
/tmp/icon-venv/bin/python - <<'PY'
import sys
from pathlib import Path
from PIL import Image

sys.path.insert(0, "Windows/setup")
import brand

# У macOS-иконок знак занимает около 80 % холста, вокруг прозрачное поле.
# Без него иконка в доке смотрится крупнее соседних.
CANVAS, PLATE = 1024, 824
base = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
art = brand.icon(PLATE)
off = (CANVAS - PLATE) // 2
base.alpha_composite(art, (off, off))

out = Path("MacOS/setup/scvpn.iconset")
out.mkdir(parents=True, exist_ok=True)
for size in (16, 32, 128, 256, 512):
    base.resize((size, size), Image.LANCZOS).save(out / f"icon_{size}x{size}.png")
    base.resize((size * 2, size * 2), Image.LANCZOS).save(out / f"icon_{size}x{size}@2x.png")
print("iconset готов")
PY
iconutil -c icns MacOS/setup/scvpn.iconset -o MacOS/setup/scvpn.icns
rm -rf MacOS/setup/scvpn.iconset /tmp/icon-venv
```

- [ ] **Step 2: Проверить результат**

```bash
file desktop/MacOS/setup/scvpn.icns
sips -g pixelWidth -g pixelHeight desktop/MacOS/setup/scvpn.icns
qlmanage -t -s 512 -o /tmp desktop/MacOS/setup/scvpn.icns && open /tmp/scvpn.icns.png
```

Expected: `Mac OS X icon`, 1024×1024, превью показывает знак «S» на тёмной плашке с полем вокруг.

- [ ] **Step 3: Записать, откуда взялся файл**

Create `desktop/MacOS/setup/README.md`:

```markdown
# Иконка

`scvpn.icns` нарисован один раз и лежит в git готовым — при сборке он не
пересоздаётся. Геометрия знака та же, что у Windows-иконки и у Android:
`../../Windows/setup/brand.py`, одна траектория из двух касающихся дуг.

Отличие от Windows-варианта: плашка занимает 824 px на холсте 1024, остальное —
прозрачное поле. Так требуют правила macOS, иначе иконка в доке выглядит
крупнее соседних.

Перерисовать (нужен Pillow и `iconutil`):

    python3 -m venv /tmp/icon-venv && /tmp/icon-venv/bin/pip install Pillow

Дальше — отрисовать `brand.icon(824)` по центру прозрачного холста 1024,
сохранить размеры 16/32/128/256/512 и те же @2x в `scvpn.iconset/`, затем
`iconutil -c icns scvpn.iconset -o scvpn.icns`.
```

- [ ] **Step 4: Commit**

```bash
git add desktop/MacOS/setup
git commit -m "macOS: иконка приложения, нарисована один раз"
```

---

### Task 13: Сборка .app

**Files:**
- Create: `desktop/MacOS/SCVPN.spec`, `desktop/MacOS/build.sh`

**Interfaces:**
- Consumes: всё предыдущее.
- Produces: `dist/SCVPN.app`.

- [ ] **Step 1: Создать `desktop/MacOS/SCVPN.spec`**

```python
# -*- mode: python ; coding: utf-8 -*-
# Сборка SCVPN.app для macOS на Apple Silicon.
# Бинарники ядра (xray, гео-базы, sing-box) сюда НЕ упаковываются: приложение
# качает их само, а sing-box вдобавок обязан лежать в root-овой папке демона.

a = Analysis(
    ['run.py'],
    pathex=['..'],          # чтобы нашёлся пакет shared
    binaries=[],
    datas=[('setup/scvpn.icns', '.')],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'PySide6.QtWebEngineCore', 'PySide6.QtWebEngineWidgets',
              'PySide6.Qt3DCore', 'PySide6.QtQuick', 'PySide6.QtQml',
              'PySide6.QtCharts', 'PySide6.QtDataVisualization', 'PySide6.QtPdf'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='SCVPN',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,              # upx ломает подпись бинарников на macOS
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch='arm64',
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='SCVPN',
)
app = BUNDLE(
    coll,
    name='SCVPN.app',
    icon='setup/scvpn.icns',
    bundle_identifier='com.scvpn.client',
    info_plist={
        'CFBundleName': 'SCVPN',
        'CFBundleDisplayName': 'SCVPN',
        'CFBundleShortVersionString': '1.0',
        'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True,
        # Без этого ключа система молча не отдаст камеру сканеру QR.
        'NSCameraUsageDescription':
            'Камера нужна только чтобы считать QR-код ссылки подписки.',
        # Приложение живёт в окне, а не в строке меню.
        'LSUIElement': False,
    },
)
```

- [ ] **Step 2: Создать `desktop/MacOS/build.sh`**

```bash
#!/bin/bash
# ====================================================================
#  Сборка SCVPN.app через PyInstaller (папка dist/).
#  Бинарники ядра (xray, гео-базы, sing-box) НЕ упаковываются — их
#  качает само приложение, а sing-box ещё и обязан лежать в root-овой
#  папке демона, куда сборщику писать нечего.
#  Иконка не генерируется: setup/scvpn.icns нарисован один раз и лежит в git.
# ====================================================================
set -euo pipefail
cd "$(dirname "$0")"
PY=.venv/bin/python

if [ ! -x "$PY" ]; then
  echo "[!] Нет .venv. Создай: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "[!] Сборка рассчитана на Apple Silicon, здесь $(uname -m)."
  exit 1
fi

echo "=== PyInstaller ==="
"$PY" -m PyInstaller --noconfirm --clean SCVPN.spec

echo "=== Подпись (ad-hoc) ==="
# Без Apple Developer ID подписываем сами собой: этого хватает, чтобы система
# запустила приложение, но при первом запуске потребуется ПКМ -> «Открыть».
codesign --force --deep --sign - dist/SCVPN.app
codesign --verify --verbose dist/SCVPN.app

echo
echo "Готово: dist/SCVPN.app"
echo "Перенеси в /Applications и запусти первый раз через ПКМ -> «Открыть»."
```

- [ ] **Step 3: Собрать**

```bash
cd desktop/MacOS && chmod +x build.sh && ./build.sh
```

Expected: `dist/SCVPN.app` создан, `codesign --verify` молчит.

- [ ] **Step 4: Проверить собранное приложение**

```bash
cp -R desktop/MacOS/dist/SCVPN.app /Applications/
open /Applications/SCVPN.app
```

Проверить: окно открывается, ядро скачивается в `~/Library/Application Support/SCVPN/bin`, подключение в режиме прокси работает.

- [ ] **Step 5: Проверить демона от собранного приложения**

Демон, поставленный в Task 8, указывает на venv-запуск из исходников. Переустановить его из собранного приложения (меню «⋯» → «Удалить системный компонент…», затем включить TUN), и убедиться, что `ProgramArguments` теперь ведут в бандл:

```bash
plutil -p /Library/LaunchDaemons/com.scvpn.helper.plist | grep -A4 ProgramArguments
```

Expected: путь вида `/Applications/SCVPN.app/Contents/MacOS/SCVPN` и `--helper`.

- [ ] **Step 6: Повторить проверку dead-man's switch на собранном приложении**

```bash
# при поднятом TUN
pkill -9 SCVPN
sleep 3
pgrep -fl sing-box            # пусто
curl -s -m 10 https://api.ipify.org   # свой адрес, интернет жив
```

- [ ] **Step 7: Commit**

```bash
git add desktop/MacOS/SCVPN.spec desktop/MacOS/build.sh
git commit -m "macOS: сборка .app для arm64"
```

---

### Task 14: Живая проверка (smoke_test.py)

**Files:**
- Create: `desktop/MacOS/smoke_test.py`

**Interfaces:**
- Consumes: весь `native` и `shared`.
- Produces: скрипт, повторяющий `Windows/smoke_test.py` для macOS.

- [ ] **Step 1: Создать `desktop/MacOS/smoke_test.py`**

Взять `desktop/Windows/smoke_test.py` за основу и заменить платформенное. Ключевые отличия от windows-версии:

```python
"""Живая проверка SCVPN на macOS: парсинг, сборка конфигов, туннель.

Запуск:  ./test.sh smoke

В отличие от test_native.py, этот скрипт ходит в сеть и требует, чтобы в
приложении уже была добавлена подписка.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

OK, FAIL, SKIP = "  ok  ", " FAIL ", " skip "
results: list[tuple[str, bool]] = []
```

Далее — та же последовательность блоков, что в windows-версии, с заменами:

- `from native.tun import is_admin` → `from native.tun import privileged`;
- строка состояния:

```python
from helper.install import installed as helper_installed
from native.downloader import core_present, tun_present

print(f"  ядро Xray установлено: {core_present()};  sing-box: {tun_present()};  "
      f"демон: {helper_installed()}")
```

- сборка конфига sing-box строится через демонский модуль, а не через `native.tun`:

```python
from helper.config import build as build_singbox
from helper.config import validate as validate_singbox

scfg = build_singbox(
    validate_singbox({"socks_port": 10808, "exclude_ips": [target.address]}),
    str(paths.xray_exe()),
)
spath = paths.DATA_DIR / "singbox_check.json"
spath.write_text(json.dumps(scfg, ensure_ascii=False, indent=2), encoding="utf-8")
```

- проверка конфига реальным бинарником делается только если sing-box установлен, и запускать его нужно от root:

```python
if not tun_present():
    print(f"{SKIP} sing-box не установлен — пропускаю проверку конфига TUN")
else:
    print(f"{SKIP} проверка конфига sing-box требует root — запусти:")
    print(f"       sudo '{paths.singbox_exe()}' check -c '{spath}'")
```

Остальные блоки (парсинг ссылок, сборка конфига Xray, автоподбор отпечатка, запуск ядра) переносятся дословно с заменой `from scvpn.X` на `from shared.X` / `from native.X`.

- [ ] **Step 2: Запустить**

Run: `cd desktop/MacOS && ./test.sh smoke`
Expected: все блоки, кроме требующих root, проходят; итоговая строка `N/N проверок пройдено`.

- [ ] **Step 3: Commit**

```bash
git add desktop/MacOS/smoke_test.py
git commit -m "macOS: живая проверка"
```

---

### Task 15: README

**Files:**
- Modify: `README.md`
- Modify: `desktop/Windows/README.md`
- Create: `desktop/MacOS/README.md`

**Interfaces:**
- Consumes: всё построенное.
- Produces: документация, соответствующая коду.

- [ ] **Step 1: Обновить таблицу платформ в корневом `README.md`**

```markdown
| | |
|---|---|
| **Windows** | `desktop/Windows/` — Python + PySide6, ядро `xray.exe` рядом |
| **macOS** | `desktop/MacOS/` — тот же код, TUN через привилегированный демон (Apple Silicon) |
| **Android** | `android/` — Kotlin, то же ядро внутри процесса (`libv2ray.aar`) |
| **iOS** | пока нет, в планах |
```

- [ ] **Step 2: Обновить раздел «Что приложение отправляет в сеть»**

Пункт 3 сейчас говорит «только Windows». Заменить на:

```markdown
3. **Скачивание ядра** (Windows и macOS) — один раз тянет `xray` + гео-базы с
   официального GitHub (XTLS/Xray-core), а для TUN — `sing-box` (SagerNet) и,
   только на Windows, `wintun.dll` (wintun.net).
```

Пункт 4 упоминает проверку соединения «на Windows» — заменить на «на десктопе».

Пути в конце раздела: `desktop/scvpn/subscription.py` → `desktop/shared/subscription.py`, `downloader.py` и `connect.py` — соответственно `desktop/Windows/native/downloader.py` и `desktop/shared/connect.py`.

- [ ] **Step 3: Переписать раздел «Общие слои»**

```markdown
### Общие слои

Десктопные версии делят один и тот же код: он лежит в `desktop/shared/`, а в
`desktop/Windows/native/` и `desktop/MacOS/native/` — только то, чем платформы
действительно отличаются. Набор имён в обеих папках одинаков, поэтому общий код
не догадывается, на чём работает.

| Слой | Десктоп | Android |
|---|---|---|
| Разбор ссылок и подписок | `shared/subscription.py` | `SubscriptionParser.kt` |
| Идентификатор устройства | `native/hwid.py` | `Hwid.kt` |
| Модель сервера | `shared/models.py` | `Model.kt` |
| Сборка конфига Xray | `shared/xray_config.py` | `XrayConfig.kt` |
| Хранение профилей | `shared/storage.py` (JSON в `data/`) | `Prefs.kt` (SharedPreferences) |
```

- [ ] **Step 4: Добавить блок про macOS в раздел «Чем платформы отличаются»**

После windows-блока, перед android-блоком:

```markdown
**macOS** (`desktop/MacOS/`) — тот же Xray отдельным процессом, те же два способа:

```
                    ┌── режим «прокси» ──────────────────────────┐
приложения ─────────┤ networksetup на активных сервисах          │
                    │        ↓ 127.0.0.1:HTTP                    │
                    │   xray ── inbound socks+http               │──→ сервер
                    └────────────────────────────────────────────┘

                    ┌── режим «TUN» (нужен root) ────────────────┐
весь трафик ОС ─────┤ utun-адаптер ← sing-box (от root)          │
                    │        ↑ поднимает демон по unix-сокету    │
                    │        ↓ 127.0.0.1:SOCKS                   │
                    │   xray (от пользователя)                   │──→ сервер
                    └────────────────────────────────────────────┘
```

Отличие от Windows одно, и оно про надёжность. TUN требует root, а если
приложение упадёт, снять root-овый sing-box будет некому: он останется держать
маршруты, и весь трафик системы уйдёт в мёртвый туннель. Поэтому вместо запроса
пароля на каждое подключение здесь стоит LaunchDaemon: приложение держит с ним
открытый unix-сокет, и обрыв этого соединения демон читает как «приложение
мертво» — и снимает туннель сам, через секунду, а не при следующем запуске.

Демон не принимает готовый конфиг: только параметры, каждый проверяет, конфиг
собирает сам, и запускает лишь бинарники из своей root-овой папки. Сокет открыт
группе `admin`, и всё, что оттуда приходит, считается недоверенным — см.
`helper/config.py` и `helper/daemon.py`.

Режим прокси root не требует: `networksetup` доступен администратору без пароля.
Прежние настройки прокси пишутся на диск перед включением, поэтому откат
переживает падение приложения.
```

- [ ] **Step 5: Обновить раздел «Сборка»**

```markdown
```powershell
# Windows: exe + установщик
cd desktop\Windows
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
build.bat            # dist\SCVPN\SCVPN.exe
build_installer.bat  # dist_installer\SCVPN-Setup-*.exe
```

```bash
# macOS (Apple Silicon): SCVPN.app
cd desktop/MacOS
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
./build.sh           # dist/SCVPN.app
```

```powershell
# Android: APK
cd android
build_apk.bat        # app\build\outputs\apk\debug\app-debug.apk
```
```

- [ ] **Step 6: Переписать раздел «Фирменный знак»**

Утверждение «иконка рисуется кодом, а не хранится картинкой» перестало быть верным для macOS. Заменить раздел на:

```markdown
## Фирменный знак

Геометрия знака описана кодом в одном месте — `desktop/Windows/setup/brand.py`:
одна траектория из двух касающихся дуг, обведённая штрихом с круглыми концами.
Из неё сделаны `scvpn.ico` (Windows), `scvpn.icns` (macOS) и запасные
`ic_launcher.png` (Android). На Android основная иконка векторная адаптивная
(`android/app/src/main/res/drawable/ic_launcher_foreground.xml`), а в интерфейсе
тот же знак рисуется Qt (`desktop/shared/ui/brandmark.py`).

`.icns` для macOS нарисован один раз и лежит в git готовым — при сборке он не
пересоздаётся; как его перерисовать, написано в `desktop/MacOS/setup/README.md`.
Отличие от Windows-иконки одно: плашка занимает 80 % холста, вокруг прозрачное
поле — иначе иконка в доке выглядит крупнее соседних.

Геометрия во всех местах одна и та же, поэтому знак нигде не разъезжается.
```

- [ ] **Step 7: Обновить `desktop/Windows/README.md`**

Заменить пути в таблице «Структура»: `scvpn/subscription.py` → `../shared/subscription.py` и так далее для общих модулей; `scvpn/sysproxy.py` → `native/sysproxy.py` и так далее для платформенных. Добавить строку `native/apps.py` — список запущенных `.exe` для раздельного туннелирования. Заголовок оставить «SCVPN для Windows», ссылку на корневой README поправить на `../../README.md`.

- [ ] **Step 8: Создать `desktop/MacOS/README.md`**

```markdown
# SCVPN для macOS

Клиент-обёртка вокруг открытого ядра [Xray-core](https://github.com/XTLS/Xray-core).
Общее описание проекта и разбор архитектуры — в [README репозитория](../../README.md).

Только Apple Silicon. Общий код лежит в `../shared/`, здесь — то, чем macOS
отличается.

## Запуск из исходников

```bash
# зависимости (один раз)
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# запуск
.venv/bin/python run.py
```

При первом запуске: меню **«⋯» → «Скачать ядро Xray»**, затем кнопка **+** —
вставь `vless://…` ссылку или URL подписки, выбери сервер и жми большую кнопку.

## Интерфейс

Экран — кнопка подключения, статус и список серверов. Всё остальное в меню «⋯»:

| Пункт | Что делает |
|---|---|
| Способ подключения | системный прокси или TUN (весь трафик) |
| Отпечаток TLS | авто-подбор или конкретный |
| Сетевой стек TUN | gvisor / system / mixed — крутить, если туннель странно себя ведёт |
| Включать системный прокси | только для режима «прокси» |
| Блокировать рекламу | правило в конфиге Xray |
| Раздельное туннелирование | какие приложения идут в туннель (только TUN) |
| Измерить пинг | TCP-пинг всех серверов |
| Скачать ядро / компоненты TUN | разовая загрузка бинарников |
| Удалить системный компонент | снять привилегированный демон |
| Показывать лог ядра | панель с выводом Xray внизу окна |

Удалить сервер — правой кнопкой по строке или `Delete`.

## Режимы

- ✅ **Системный прокси** — без пароля: `networksetup` доступен администратору
  напрямую. Покрывает браузеры и приложения с интерфейсом; консольные утилиты
  про эту настройку не знают.
- ✅ **TUN — весь трафик**: Xray делает соединение с сервером, а `sing-box`
  заворачивает в него весь трафик системы через utun-адаптер.

## Как устроен TUN и почему так

TUN требует root. Пароль спрашивается **один раз** — при установке системного
компонента; дальше приложение говорит с ним по `/var/run/scvpn-helper.sock`.

Компонент — это LaunchDaemon `com.scvpn.helper`. Он поднимает sing-box, следит
за ним и, главное, следит за соединением с приложением: обрыв соединения
означает, что приложение мертво, и демон снимает туннель сам. Без этого
падение приложения оставило бы root-овый sing-box держать маршруты, а весь
трафик системы — уходить в мёртвый туннель; снять его было бы некому.

Границы, которые компонент держит:

- сокет открыт только группе `admin`, права `0660`;
- готовый конфиг он не принимает — только параметры, каждый проверяется
  (`helper/config.py`), конфиг собирает сам;
- запускает только бинарники из `/Library/Application Support/SCVPN/bin`,
  принадлежащие root и недоступные на запись остальным. Поэтому `sing-box`
  скачивает туда сам демон, а не приложение.

Снять компонент: меню «⋯» → «Удалить системный компонент…». Руками:

```bash
sudo launchctl bootout system/com.scvpn.helper
sudo rm -f /Library/LaunchDaemons/com.scvpn.helper.plist
sudo rm -rf "/Library/Application Support/SCVPN"
```

Лог демона — `/var/log/scvpn-helper.log`.

## Структура

| Файл | За что отвечает |
|------|-----------------|
| `../shared/` | общий с Windows код: парсеры, модели, конфиг Xray, хранилище, интерфейс |
| `native/paths.py` | все пути приложения в одном месте |
| `native/sysproxy.py` | системный прокси через `networksetup`, со снимком для отката |
| `native/hwid.py` | идентификатор устройства из `IOPlatformUUID` |
| `native/downloader.py` | скачивание ядра Xray для arm64 |
| `native/tun.py` | клиент демона: поднять и снять туннель |
| `native/apps.py` | список запущенных приложений для раздельного туннелирования |
| `helper/config.py` | конфиг sing-box и валидация недоверенного ввода |
| `helper/daemon.py` | сам демон: сокет, надзор за sing-box, установка sing-box |
| `helper/install.py` | постановка и снятие демона |
| `setup/scvpn.icns` | иконка, нарисована один раз (см. `setup/README.md`) |

## Проверка

```bash
./test.sh            # модульные проверки платформенного слоя
./test.sh smoke      # живая проверка: парсинг, конфиги, туннель
./test.sh мой.py     # свой скрипт в окружении проекта
```

Проверка `test_snapshot_round_trip_restores_state` реально включает и выключает
системный прокси на этой машине — так и задумано: молча сломанный откат
оставляет без интернета, и ловить это надо здесь.

## Сборка

```bash
./build.sh           # dist/SCVPN.app
```

Приложение подписано ad-hoc, без Apple Developer ID, поэтому первый запуск —
через ПКМ → «Открыть». Иконка при сборке не генерируется: `setup/scvpn.icns`
лежит в git готовым.

## Где лежат данные

В режиме разработки всё открыто в папках `data/` и `bin/` рядом с проектом;
в собранном приложении — в `~/Library/Application Support/SCVPN`:

- `profiles.json` — подписки и серверы;
- `settings.json` — настройки;
- `xray_running.json` — конфиг, реально отданный ядру;
- `sysproxy_backup.json` — что стояло в системном прокси до нас;
- `bin/` — ядро Xray и гео-базы.

`sing-box` лежит отдельно, в `/Library/Application Support/SCVPN/bin`: его
запускает root, и писать туда пользователь не должен.
```

- [ ] **Step 9: Проверить, что README не расходится с кодом**

```bash
cd /Users/chasonick/Documents/SCVPN
grep -o 'desktop/[a-zA-Z/._]*' README.md desktop/*/README.md | sort -u | while IFS=: read -r _ p; do
  [ -e "$p" ] || echo "нет такого пути: $p"
done
```

Expected: пусто.

- [ ] **Step 10: Commit**

```bash
git add README.md desktop/Windows/README.md desktop/MacOS/README.md
git commit -m "README под новую структуру и macOS"
```

---

## Self-Review

**Покрытие спеки.** Пройдено по разделам: привилегии TUN → Task 7, 8, 9; граница доверия → Task 6 (валидация), Task 7 (`check_binary`, `_checked_xray_path`); протокол → Task 7; установка → Task 8; структура папок → Task 1, 2; таблица «что переписывается» → Task 3, 4, 5, 9, 10, 11; конфиг sing-box → Task 6; иконка → Task 12; сборка → Task 13; README → Task 15; проверки → распределены по задачам плюс Task 14.

**Расхождения, поправленные по ходу.** Спека говорила «`native.downloader` качает sing-box через `tarfile`» — в плане это уехало в демона (Task 7), потому что писать в root-овую папку из-под пользователя нельзя; `native.downloader.download_tun` стал тонкой обёрткой. Спека не называла настройку `tun_stack` — она добавлена в Task 11 и в `DEFAULT_SETTINGS`.

**Согласованность имён.** Контракт `native` объявлен один раз в разделе File Structure; `Tun`, `download_tun`, `privileged`, `acquire_privilege`, `running_apps`, `normalize`, `MANUAL_HINT` используются в Task 1 (Windows) и Task 9, 10 (macOS) одинаково. `HELPER_BIN_DIR` объявлен в Task 2 и используется в Task 6, 7. `check_binary`, `pick_singbox_asset`, `handle_line`, `_checked_xray_path` объявлены и проверяются в Task 7.

**Чего в плане намеренно нет.** Проверки Windows-половины запуском — на macOS это невозможно, ограничение вынесено в отдельный раздел вверху.

**Одна незакрытая неизвестность.** Работоспособность правил `process_name` на darwin проверяется руками в Task 11 Step 9; если не подтвердится, там же предписано пометить сплит-туннель неподдерживаемым, а не оставить молча неработающим.
