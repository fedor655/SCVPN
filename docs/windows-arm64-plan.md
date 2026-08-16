# План поддержки Windows on ARM (arm64)

Дата составления: 16.08.2026. Все внешние факты ниже проверены в этот день —
имена ассетов релизов и наличие колёс на PyPI меняются, перед началом работ их
стоит перепроверить теми же командами, что приведены в разделе 1.

---

## 1. Проверенные факты

| Что нужно | Есть ли arm64 | Как проверено |
|---|---|---|
| Xray-core | да, ассет `Xray-windows-arm64-v8a.zip` (v26.3.27) | GitHub API релизов XTLS/Xray-core |
| sing-box | да, `sing-box-<ver>-windows-arm64.zip` (v1.13.18) | GitHub API релизов SagerNet/sing-box |
| wintun | да, внутри `wintun-0.14.1.zip` лежит `wintun/bin/arm64/wintun.dll` | скачан и распакован список файлов |
| PySide6 / PySide6-Essentials / PySide6-Addons | да, колесо `win_arm64`, начиная с 6.9.0 | PyPI JSON API |
| PyInstaller | да, `pyinstaller-6.22.1-py3-none-win_arm64.whl` | PyPI JSON API |
| numpy | да, `win_arm64` (2.5.2, cp312+) | PyPI JSON API |
| Pillow | да, `win_arm64` (12.3.0, cp310+) | PyPI JSON API |
| zxing-cpp | да, `win_arm64` (3.1.1, cp310+) | PyPI JSON API |
| **opencv-python(-headless)** | **нет**, только `win32` и `win_amd64` (5.0.0.93) | PyPI JSON API |
| requests, qrcode | чистый Python, архитектура не важна | — |
| Inno Setup | поддерживает идентификаторы `arm64`, `x64compatible`, `x64os`, `x86compatible` | документация ArchitecturesAllowed |
| CI | GitHub-hosted раннер `windows-11-arm` доступен (GA; образ с VS 2026 — `windows-11-vs2026-arm`, пока preview) | GitHub Changelog |

Правило Windows on ARM, из которого следует вся стратегия:

* **Процессы** любой архитектуры запускаются свободно. Эмулируемое x64-приложение
  может запустить нативный arm64 `.exe` как дочерний процесс — это обычный
  `CreateProcess`, ограничений нет.
* **DLL** обязана совпадать по архитектуре с процессом, который её грузит.
* **Драйверы режима ядра эмуляции не имеют вовсе**: на arm64-системе драйвер
  обязан быть arm64.

## 2. Что происходит на ARM-машине сегодня

1. **Установщик просто отказывается ставиться.** В `setup/installer.iss` стоит
   `ArchitecturesAllowed=x64`, а идентификатор `x64` (в новых версиях — синоним
   `x64os`) означает «именно x64-редакция Windows» и arm64 не покрывает. Это
   первый и самый дешёвый в исправлении барьер.
2. Если поставить в обход установщика (распаковать `dist\SCVPN` руками),
   приложение запустится под эмуляцией x64 и будет работать: Python, Qt,
   OpenCV, `tasklist`, реестр — всё это эмулируется штатно.
3. Режим системного прокси (`native/sysproxy.py`) заработает — там только
   реестр и WinINet.
4. `xray.exe` (x64) запустится под эмуляцией. Работать будет, но криптография
   под эмуляцией заметно медленнее нативной — это самое чувствительное место
   по производительности во всём приложении.
5. **TUN-режим, скорее всего, не поднимется.** `sing-box.exe` x64 под
   эмуляцией загрузит x64-`wintun.dll` (архитектуры процесса и DLL совпадают,
   формально всё законно), но wintun ставит драйвер режима ядра, а драйвер
   для arm64-ядра обязан быть arm64. Это единственное утверждение в разделе,
   которое проверено логикой, а не экспериментом — см. шаг 0 плана.
6. `native/hwid.py` продолжит работать (`KEY_WOW64_64KEY` корректен на обеих
   архитектурах), но `x-device-os` уйдёт в панель как «Windows» без указания
   архитектуры — мелочь, но её удобно уточнить заодно.

## 3. Стратегия: два этапа

**Этап 1 — «эмулируемое приложение, нативные ядра».** Приложение остаётся
x64 и работает под эмуляцией, а `xray.exe`, `sing-box.exe` и `wintun.dll`
скачиваются в arm64-варианте. Это законно ровно потому, что ядра — отдельные
процессы, а не DLL внутри нашего. Диф маленький: определение архитектуры,
выбор ассетов, метка архитектуры в `bin/`, две строчки в установщике. Этап
закрывает и работоспособность TUN, и главную часть потерь производительности:
шифрует трафик Xray, а он становится нативным.

**Этап 2 — нативная arm64-сборка приложения.** Отдельный `.exe`, собранный
на arm64-машине, и отдельный установщик. Даёт быстрый и не жрущий батарею
интерфейс, но требует убрать OpenCV (его нет под arm64) и завести сборочную
машину или CI-раннер.

Этап 1 самодостаточен: после него приложение на ARM полностью функционально.
Этап 2 — про качество, а не про работоспособность. Делать его вторым шагом,
не смешивая с первым.

---

## 4. Этап 1 — подробно

### Шаг 0. Проверка гипотезы про wintun (полчаса, до всякого кода)

Нужна машина или виртуалка с Windows 11 on ARM (на Apple Silicon —
Parallels или VMware Fusion, оба ставят Windows 11 ARM официально).

1. Распаковать текущую `dist\SCVPN` руками, положить в `bin\` x64-набор
   (xray, sing-box, wintun x64), запустить от администратора, включить TUN.
2. Записать, что именно скажет sing-box в логе.
3. Повторить с arm64-набором: `Xray-windows-arm64-v8a.zip`,
   `sing-box-...-windows-arm64.zip`, `wintun/bin/arm64/wintun.dll`.

Результат шага 0 определяет тон сообщений об ошибках дальше. Если x64-набор
внезапно заработает — план не меняется (нативные ядра всё равно нужны ради
скорости), но текст ошибки «TUN недоступен» из UI можно не добавлять.

### Шаг 1. Новый модуль `desktop/Windows/native/arch.py`

Определять архитектуру **операционной системы**, а не процесса.
`platform.machine()` в эмулируемом процессе вернёт `AMD64` и соврёт.
Правильный источник — `IsWow64Process2` (есть с Windows 10 1709), запасной —
переменная окружения `PROCESSOR_ARCHITEW6432`, которую эмуляция выставляет
в `ARM64`.

```python
"""Архитектура системы — от неё зависит, какие бинарники ядер скачивать.

Спрашиваем именно систему, а не себя: на Windows on ARM приложение работает
под эмуляцией x64, и platform.machine() честно отвечает "AMD64" про процесс,
хотя ядру нужен arm64-бинарник.
"""
from __future__ import annotations

import ctypes
import os
from ctypes import wintypes

# Константы IMAGE_FILE_MACHINE_* из winnt.h.
_MACHINE = {0xAA64: "arm64", 0x8664: "x64", 0x014C: "x86"}


def host_arch() -> str:
    """"arm64" | "x64" | "x86" — архитектура ОС."""
    if os.name == "nt":
        try:
            k32 = ctypes.windll.kernel32
            k32.GetCurrentProcess.restype = wintypes.HANDLE
            process, native = wintypes.USHORT(), wintypes.USHORT()
            if k32.IsWow64Process2(
                k32.GetCurrentProcess(), ctypes.byref(process), ctypes.byref(native)
            ):
                return _MACHINE.get(native.value, "x64")
        except (AttributeError, OSError):
            pass  # Windows старше 10 1709 — падаем на переменные окружения
    env = os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get(
        "PROCESSOR_ARCHITECTURE", ""
    )
    return {"ARM64": "arm64", "AMD64": "x64", "X86": "x86"}.get(env.upper(), "x64")


def emulated() -> bool:
    """Работаем ли мы под эмуляцией (x64-сборка на arm64-системе)."""
    import platform

    return host_arch() == "arm64" and platform.machine().upper() != "ARM64"
```

### Шаг 2. `native/downloader.py` — выбор ассетов по архитектуре

Три места, все механические:

```python
from . import arch, paths

_XRAY_ASSET = {"x64": "Xray-windows-64.zip", "arm64": "Xray-windows-arm64-v8a.zip"}
_SINGBOX_SUFFIX = {"x64": "windows-amd64.zip", "arm64": "windows-arm64.zip"}
_WINTUN_MEMBER = {"x64": "amd64/wintun.dll", "arm64": "arm64/wintun.dll"}
```

* `latest_asset_url()` — вместо константы `ASSET_NAME` брать
  `_XRAY_ASSET[arch.host_arch()]`, и в тексте ошибки называть ту же строку.
* `_singbox_asset_url()` — условие становится
  `name.endswith(_SINGBOX_SUFFIX[a]) and "legacy" not in name`. Для arm64
  legacy-варианта не существует, но проверку оставить: она не мешает.
* `_download_wintun()` — искать `member.endswith(_WINTUN_MEMBER[a])`.
  Здесь ошибка была бы самой коварной: x64-DLL в arm64-процессе sing-box не
  загрузится вовсе, а сообщение было бы про «не найден wintun».

Все три словаря держать в одном месте файла, рядом, чтобы при появлении
условного `windows-arm64-v9` правка была одна.

### Шаг 3. Метка архитектуры в `bin/`

Сейчас `core_present()` смотрит только на наличие файлов. После правки
пользователь, обновившийся на ARM-машине, останется со старыми x64-ядрами и
получит невнятную ошибку запуска. Нужна метка.

В `native/paths.py`:

```python
def arch_stamp() -> Path:
    """Архитектура бинарников, лежащих сейчас в bin/."""
    return BIN_DIR / "arch.txt"
```

В `native/downloader.py`:

```python
def bin_arch() -> str:
    """Под какую архитектуру скачан текущий bin/.

    Метки нет — значит bin/ достался от сборки, которая умела только x64.
    """
    try:
        return paths.arch_stamp().read_text(encoding="utf-8").strip() or "x64"
    except OSError:
        return "x64"


def _stamp_bin() -> None:
    paths.arch_stamp().write_text(arch.host_arch(), encoding="utf-8")
```

`_stamp_bin()` вызывать в конце `download_core()` и `download_singbox()`
(после проверки, что все файлы на месте — метка не должна пережить неудачную
распаковку). А `core_present()` и `tun_present()` дополнить сверкой:

```python
def core_present() -> bool:
    return (
        bin_arch() == arch.host_arch()
        and paths.xray_exe().exists()
        and paths.geoip_dat().exists()
        and paths.geosite_dat().exists()
    )
```

Такой `core_present()` на ARM-машине со старым `bin/` вернёт False, и UI сам
предложит скачать ядро — тем же путём, каким предлагает при первом запуске.
Ничего дополнительно удалять не нужно: скачивание перезапишет файлы.

### Шаг 4. Установщик

В `setup/installer.iss`:

```ini
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
```

`x64compatible` покрывает и x64-Windows, и arm64-Windows (там наше x64-
приложение выполняется под эмуляцией). Требуется Inno Setup 6.3 или новее —
в `build_installer.bat` стоит добавить проверку версии, иначе на старом
компиляторе получится невнятная ошибка синтаксиса.

`[UninstallDelete]` и остальное не трогаем.

### Шаг 5. Диагностика в интерфейсе

Мелочь, которая экономит часы поддержки:

* `ui/main_window.py` — в стартовые строки лога добавить архитектуру:
  `[*] Windows arm64, приложение x64 (эмуляция)`. Строку собирать из
  `arch.host_arch()` и `arch.emulated()`.
* Там же, где сейчас проверяется `core_present()` (строки 152 и 539) —
  если файлы на месте, но `bin_arch()` не совпал, писать прямо: «ядро
  скачано под x64, системе нужен arm64 — нажми "Скачать ядро Xray"».
* `native/tun.py`, ветка отсутствующего `wintun.dll`: упомянуть архитектуру,
  раз уж мы её теперь знаем.
* `native/hwid.py::device_headers()` — добавить архитектуру в
  `x-device-model` или `x-ver-os`, чтобы в панели было видно ARM-устройство.
  Внимание: сам `device_id()` не трогать ни при каких обстоятельствах —
  он уже сохранён в `settings.json`, и его изменение съело бы новый слот в
  лимите устройств у каждого пользователя.

### Шаг 6. Проверки

Один маленький модульный тест без сети — на выбор ассетов, потому что это
единственное место с ветвлением, где ошибка тихая (скачается не тот файл, а
упадёт всё уже в другом модуле):

`desktop/Windows/test_arch_assets.py`

```python
"""Выбор бинарников по архитектуре. Запуск: test.bat test_arch_assets.py"""
from unittest import mock

import native.downloader as d


def check(host, xray, singbox, wintun):
    with mock.patch.object(d.arch, "host_arch", return_value=host):
        assert d._XRAY_ASSET[host] == xray
        assert d._SINGBOX_SUFFIX[host] == singbox
        assert d._WINTUN_MEMBER[host] == wintun


check("x64", "Xray-windows-64.zip", "windows-amd64.zip", "amd64/wintun.dll")
check("arm64", "Xray-windows-arm64-v8a.zip", "windows-arm64.zip", "arm64/wintun.dll")
print("[ OK ] выбор ассетов по архитектуре")
```

И в `smoke_test.py` — нулевым шагом печатать `arch.host_arch()`,
`platform.machine()` и `bin_arch()`, а в шаге 2 считать несовпадение
архитектур явным FAIL, а не «ядро не установлено».

### Критерии приёмки этапа 1

1. Установщик, собранный на x64-машине, ставится на Windows 11 ARM без
   правок и без ключей.
2. На ARM-машине кнопка «Скачать ядро Xray» кладёт в `bin/` именно
   arm64-бинарник (проверяется `dumpbin /headers xray.exe`, поле machine,
   или просто `file` из Git Bash).
3. Режим системного прокси даёт выход в сеть.
4. TUN-режим поднимается, `ipconfig` показывает адаптер `SCVPNTun`,
   трафик идёт, при отключении маршруты возвращаются.
5. Раздельное туннелирование по `process_name` работает (проверить на
   любом браузере — sing-box сопоставляет процессы независимо от их
   архитектуры).
6. На обычной x64-машине ничего не изменилось: `bin/` без метки считается
   x64, повторного скачивания не происходит.

Оценка: полдня работы плюс полдня проверки на живой машине.

---

## 5. Этап 2 — нативная arm64-сборка

### 5.1. Зависимости

| Пакет | arm64 | Что делать |
|---|---|---|
| Python | официальный установщик для Windows ARM64 с 3.11 | брать 3.12 или новее — под неё есть все нужные колёса |
| PySide6 | с 6.9.0 | поднять нижнюю границу в `requirements.txt` до 6.9 |
| requests, qrcode | чистый Python | ничего |
| PyInstaller | 6.x, колесо `win_arm64` | ничего, но собирать обязательно на arm64-машине |
| opencv-python-headless | **нет и не предвидится** | заменить, см. 5.2 |

### 5.2. Замена OpenCV в сканере QR

OpenCV в проекте делает ровно две вещи: берёт кадры с камеры и распознаёт QR
(`ui/qr_scanner.py`, строки 85–147). Обе закрываются тем, что уже есть или
имеет arm64-колёса:

* захват — `PySide6.QtMultimedia` (`QMediaCaptureSession` + `QVideoSink`),
  это часть PySide6-Addons, колесо `win_arm64` есть;
* распознавание — `zxing-cpp` (`import zxingcpp`), колёса `win_arm64` есть;
  на вход принимает numpy-массив, у numpy колесо `win_arm64` тоже есть.

Схема нового `_open_camera`/`_tick`:

```python
from PySide6.QtMultimedia import QCamera, QMediaCaptureSession, QMediaDevices, QVideoSink

cameras = QMediaDevices.videoInputs()          # заменяет перебор индексов 0..3
self._camera = QCamera(cameras[index])
self._sink = QVideoSink()
self._session = QMediaCaptureSession()
self._session.setCamera(self._camera)
self._session.setVideoSink(self._sink)
self._sink.videoFrameChanged.connect(self._on_frame)
self._camera.start()
```

`_on_frame(frame)` получает `QVideoFrame`, из него `frame.toImage()` даёт
`QImage`. Дальше — то же, что и сейчас: показать в `self.video`, а каждый
второй кадр отдать декодеру:

```python
img = image.convertToFormat(QImage.Format_Grayscale8)
buf = np.frombuffer(img.constBits(), dtype=np.uint8).reshape(
    img.height(), img.bytesPerLine()
)[:, : img.width()]
results = zxingcpp.read_barcodes(buf, formats=zxingcpp.BarcodeFormat.QRCode)
```

Что это даёт помимо ARM: минус OpenCV — это минус около 40 МБ в сборке для
обеих архитектур, и минус зеркалирование кадра вручную (`QVideoSink` умеет
отдавать зеркальный кадр, а `QCamera` сам разбирается с бэкендом Media
Foundation вместо перебора `CAP_DSHOW` / дефолтного).

Замену делать **сразу для обеих архитектур**, одной реализацией. Держать две
ветки кода (OpenCV на x64, Qt+zxing на arm64) — это гарантированно
разъезжающийся сканер, который никто не проверяет на второй платформе.

Запасной вариант, если Qt-захват на ARM окажется проблемным: собирать
arm64-сборку вообще без сканера (кнопка «Сканировать QR» скрывается, ссылку
подписки вставляют текстом или из буфера). Функционально это потеря
одного удобства, а не режима работы. Решать по результату замера, а не
заранее.

### 5.3. `requirements.txt`

```
PySide6>=6.9          ; 6.9 — первая версия с колесом win_arm64
requests>=2.31
qrcode>=7.4
zxing-cpp>=3.1        ; декодер QR, есть win_arm64 (opencv его не имеет)
numpy>=2.0            ; нужен zxing-cpp для входного кадра
```

`opencv-python-headless` уходит целиком. Отдельного
`requirements-arm64.txt` заводить не нужно — в этом и смысл замены.

### 5.4. Сборка

* `SCVPN.spec`: `upx=True` заменить на `upx=False`. Поддержка arm64-PE в UPX
  непроверена, а выигрыш в размере сомнителен на фоне ложных срабатываний
  антивирусов. Проверить это отдельно и вернуть UPX, если работает, — но не
  на критическом пути.
* В имя выходной папки добавить архитектуру: `--distpath dist\arm64` и
  `dist\x64`, иначе два билда затрут друг друга на одной машине.
* `build.bat` определяет архитектуру хоста (`if "%PROCESSOR_ARCHITECTURE%"=="ARM64"`)
  и передаёт её дальше: в `--distpath` и в `ISCC /DMyArch=arm64`.
  Кросс-сборки нет: PyInstaller собирает только под ту архитектуру, на
  которой запущен, потому что подкладывает свой бутлоадер.

### 5.5. Установщик

```ini
#ifndef MyArch
  #define MyArch "x64compatible"
#endif

ArchitecturesAllowed={#MyArch}
ArchitecturesInstallIn64BitMode={#MyArch}
OutputBaseFilename=SCVPN-Setup-{#MyVersion}-{#MyArch}
Source: "..\dist\{#MyArch}\SCVPN\*"; DestDir: "{app}"; ...
```

Вызов: `ISCC /DMyArch=arm64 setup\installer.iss`.

`AppId` оставить общий: тогда установка arm64-версии поверх ранее
поставленной x64 будет обновлением, а не вторым приложением в списке
«Программы и компоненты». Старые бинарники в `{app}\bin` при этом останутся —
их отбракует метка архитектуры из шага 3, и приложение предложит скачать
нужные. Специально чистить `bin` в `[InstallDelete]` не надо: это заставило
бы перекачивать ядро при каждом обновлении.

### 5.6. CI (опционально, но окупается)

GitHub-hosted раннер `windows-11-arm` доступен; для публичных репозиториев он
бесплатен. Матрица из двух джоб (`windows-latest` и `windows-11-arm`), в
каждой — `pip install -r requirements.txt`, `python test_arch_assets.py`,
`build.bat`, `build_installer.bat`, выгрузка установщика артефактом. Это
единственный способ не держать дома ARM-машину ради каждого релиза.

Обратить внимание: раннер `windows-11-vs2026-arm` пока в public preview,
брать надо базовый `windows-11-arm`.

### Критерии приёмки этапа 2

1. `SCVPN-Setup-<ver>-arm64.exe` ставится на Windows 11 ARM, в диспетчере
   задач процесс `SCVPN.exe` показан без пометки об эмуляции.
2. Сканирование QR камерой работает на обеих архитектурах — новой,
   одинаковой реализацией.
3. x64-установщик по-прежнему ставится и на x64, и (под эмуляцией) на ARM.
4. `smoke_test.py` зелёный на обеих машинах.

Оценка: два-три дня, из которых большая часть — переписывание сканера и
отладка сборки на живой ARM-машине.

---

## 6. Матрица тестирования

| Сценарий | x64 Windows | ARM64 Windows, сборка x64 | ARM64 Windows, сборка arm64 |
|---|---|---|---|
| Установка | этап 1 | этап 1 | этап 2 |
| Прокси-режим | регресс | этап 1 | этап 2 |
| TUN-режим | регресс | этап 1 (ключевой) | этап 2 |
| Раздельный туннель | регресс | этап 1 | этап 2 |
| Скачивание ядра/TUN | регресс | этап 1 (ключевой) | этап 2 |
| Обновление поверх старой установки | регресс | этап 1 (метка bin) | этап 2 (смена архитектуры) |
| Сканер QR | этап 2 (замена) | этап 2 | этап 2 |
| HWID стабилен после обновления | регресс | этап 1 | этап 2 |

«Регресс» — то, что должно остаться неизменным и проверяется на текущей
рабочей машине.

## 7. Риски и открытые вопросы

1. **Драйвер wintun на ARM.** Главная неизвестная, снимается шагом 0.
   Если arm64-wintun по какой-то причине не встанет (подпись, политика Secure
   Boot), TUN-режим на ARM останется недоступным, и надо будет честно
   писать об этом в интерфейсе, а не показывать бесконечное «подключаюсь».
2. **Отладка только на живом железе.** Виртуалка на Apple Silicon покрывает
   почти всё, но сетевые драйверы в виртуалке ведут себя иначе, чем на
   Snapdragon-ноутбуке. Финальную проверку TUN стоит сделать на физической
   машине, если она доступна.
3. **UPX и arm64.** Помечено как непроверенное; на этапе 2 просто выключается.
4. **Inno Setup 6.3+.** Если на сборочной машине стоит 6.0–6.2,
   `x64compatible` не скомпилируется. Проверку версии добавить в
   `build_installer.bat`.
5. **Смена имени ассетов у Xray.** `Xray-windows-arm64-v8a.zip` — имя с
   суффиксом версии архитектуры, оно уже менялось в истории проекта.
   Разумно при отсутствии точного совпадения искать первый ассет, чей имя
   начинается с `Xray-windows-arm64`, а не падать сразу.
6. **Что не делаем.** 32-битный ARM (arm32) не поддерживаем: Windows 11 24H2
   выкинула эмуляцию arm32, а нативных arm32-сборок ни у Xray, ни у sing-box
   для Windows нет. Отдельного «универсального» установщика с обеими
   архитектурами внутри тоже не делаем — это лишние 60 МБ ради экономии
   одного клика на странице загрузки.

## 8. Порядок работ одним списком

1. Шаг 0: проверить wintun на ARM-виртуалке.
2. `native/arch.py` + тест выбора ассетов.
3. `native/downloader.py`: ассеты по архитектуре, метка `bin/arch.txt`.
4. `core_present()` / `tun_present()`: сверка архитектуры.
5. `installer.iss`: `x64compatible`; проверка версии Inno в `build_installer.bat`.
6. Сообщения в `ui/main_window.py`, `native/tun.py`, заголовки в `hwid.py`.
7. `smoke_test.py`: нулевой шаг про архитектуру.
8. Прогон критериев приёмки этапа 1 на ARM-машине. **Здесь можно
   останавливаться и выпускать релиз.**
9. Замена OpenCV на QtMultimedia + zxing-cpp, проверка сканера на x64.
10. Правки `requirements.txt`, `SCVPN.spec`, `build.bat`, `installer.iss`
    под две архитектуры.
11. Сборка и проверка arm64-установщика на ARM-машине.
12. CI-матрица на `windows-latest` + `windows-11-arm`.
