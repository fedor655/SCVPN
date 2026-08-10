# Порт SCVPN на macOS (Apple Silicon)

Дата: 2026-08-11

## Задача

Портировать десктопный клиент SCVPN (Python + PySide6, сейчас только Windows) на
macOS для Apple Silicon. Поддержка Intel не нужна. Папку `desktop/` разложить на
`Windows/` и `MacOS/`. Обновить README под новую структуру.

Отдельное требование: **TUN должен быть максимально стабильным**. Опорная точка —
опыт с Happ, где туннель вёл себя ненадёжно.

## Проверенные факты

Проверено на macOS 26.6.1, arm64, до начала работы:

| Что | Результат |
|---|---|
| Релизы Xray-core | ассет `Xray-macos-arm64-v8a.zip` (zip) |
| Релизы sing-box | ассет `sing-box-<ver>-darwin-arm64.tar.gz` (**tar.gz**, не zip) |
| `networksetup -setwebproxystate` от обычного пользователя-администратора | `exit=0`, пароль не запрашивается → **режиму прокси root не нужен** |
| `iconutil`, `sips`, `codesign` | есть в `/usr/bin` |
| sing-box `strict_route` | только Linux и Windows, на darwin неприменимо |
| sing-box `stack` | `system` / `gvisor` / `mixed` |
| sing-box `interface_name` на darwin | своё имя задать нельзя, устройство именуется `utunN` ядром |

Бинарники Xray и sing-box для darwin/arm64 собраны Go, а линковщик Go начиная с
1.16 сам проставляет ad-hoc подпись для darwin/arm64 — значит скачанные ядра
запускаются без отдельного `codesign`. Достаточно `chmod +x`.

## Архитектурное решение №1: привилегии TUN

TUN на macOS требует root. Рассматривались три варианта.

**Отвергнуто: `osascript ... with administrator privileges` на каждое подключение.**
Разбирается ниже по конкретному отказу.

**Отвергнуто: NetworkExtension (`NEPacketTunnelProvider`).** Требует Swift/ObjC,
платный Apple Developer ID и отдельный энтайтлмент от Apple. Для приложения,
собираемого PyInstaller, путь нерабочий.

**Выбрано: привилегированный LaunchDaemon-хелпер.**

### Почему это стабильнее — по отказам

**Отказ 1. Приложение упало или снято, sing-box жив.** Он работает от root и
держит маршруты; весь трафик системы уходит в мёртвый туннель, и снаружи это
выглядит как «интернет пропал». Прибить его может только root. С `osascript`
это означает диалог пароля, который **некому показать** — GUI уже мёртв.

Решение: GUI держит открытое соединение по unix-сокету к демону. Демон следит
за этим соединением; EOF означает, что GUI мёртв, и демон **сам** сносит
sing-box и маршруты. Не при следующем запуске приложения, а через секунду.
Это и есть главный аргумент за демона.

**Отказ 2. sing-box умер сам.** Туннель поднят, ядра нет. Демон видит выход
дочернего процесса и убирает за ним. Сам демон при падении поднимается launchd
по `KeepAlive`.

**Отказ 3. Сон/пробуждение, смена сети (Wi-Fi ↔ Ethernet, новый DHCP).**
Лечится `auto_detect_interface: true` — sing-box сам переопределяет исходящий
интерфейс. Явные хуки на wake в этой версии не пишутся, помечаются
`ponytail:`-комментарием с путём доработки.

**Отказ 4. Петля маршрутизации.** Соединение xray к серверу не должно снова
попадать в TUN. Два независимых пояса, оба уже есть в Windows-конфиге и оба
работают на darwin:
- правило `process_path` для бинарника xray → `direct` (главный: переживает
  смену IP сервера и работает для доменов с ротацией A-записей);
- `route_exclude_address` по резолву адреса сервера (запасной).

Побочная выгода: пароль спрашивается один раз при установке компонента, а не
при каждом подключении.

### Граница доверия

Демон работает от root и слушает сокет, доступный группе `admin`. Это вектор
эскалации привилегий, и он закрывается явно:

- Сокет `/var/run/scvpn-helper.sock`, владелец `root:admin`, права `0660`.
- Демон **не принимает готовый конфиг sing-box**. Он принимает только набор
  параметров и собирает JSON сам. Валидация каждого:
  - `socks_port` — целое в диапазоне 1…65535;
  - `exclude_ips` — каждый разбирается через `ipaddress`, невалидные отброшены;
  - `split_mode` — одно из `off` / `exclude` / `include`;
  - `split_apps` — имена без разделителей пути, без `..`, длина ≤ 64;
  - `stack` — одно из `gvisor` / `system` / `mixed`.
- Путь к бинарнику xray для правила `process_path` демон **выводит сам** из
  своего расположения, а не принимает от клиента.
- `sing-box` живёт в `/Library/Application Support/SCVPN/bin`, владелец
  `root:wheel`, права `0755`. Скачивает и распаковывает его сам демон. Демон
  отказывается запускать что-либо вне этой папки, и проверяет перед запуском,
  что бинарник не доступен на запись группе и остальным. Без этого любой
  процесс пользователя подменил бы `sing-box` и получил root.
- `xray` остаётся в пользовательской папке — он работает от пользователя,
  root ему не нужен.

### Протокол

Построчный JSON поверх `SOCK_STREAM`. Команды: `start` (параметры выше),
`stop`, `status`, `install_singbox`. Ответ — одна строка JSON с `ok` и либо
результатом, либо `error`. Лог sing-box демон пересылает клиенту строками
`{"log": "..."}`, чтобы панель лога в приложении работала как на Windows.

Соединение живёт всё время работы приложения — оно же dead-man's switch.

### Установка

При первом выборе TUN приложение сообщает, что нужен разовый системный
компонент, и по подтверждению запускает `osascript` с правами администратора:
скопировать plist в `/Library/LaunchDaemons/com.scvpn.helper.plist`,
`launchctl bootstrap system`. Дальше приглашений пароля нет. В меню «⋯»
появляется пункт удаления компонента (`launchctl bootout` + удаление файлов).

Код демона живёт в `helper/daemon.py` и входит в тот же бандл. `ProgramArguments`
указывают на исполняемый файл внутри `SCVPN.app` с флагом `--helper`, который
`run.py` разбирает и отдаёт управление `daemon.main()`. Отдельный интерпретатор
Python в системе поэтому не нужен — PyInstaller приносит свой. При запуске из
исходников plist указывает на python из venv и тот же `run.py --helper`.

## Архитектурное решение №2: структура папок

```
desktop/
├── shared/          models.py subscription.py xray_config.py storage.py
│                    subinfo.py ping.py connect.py core_runner.py  ui/
├── Windows/
│   ├── native/      sysproxy.py tun.py paths.py hwid.py downloader.py
│   ├── run.py SCVPN.bat build.bat build_installer.bat test.bat SCVPN.spec smoke_test.py
│   ├── setup/       brand.py make_icon.py installer.iss scvpn.ico scvpn_256.png
│   └── README.md
└── MacOS/
    ├── native/      sysproxy.py tun.py paths.py hwid.py downloader.py
    ├── helper/      daemon.py com.scvpn.helper.plist install.py
    ├── run.py build.sh test.sh SCVPN.spec smoke_test.py
    ├── setup/       scvpn.icns
    └── README.md
```

Общего кода около 2300 строк, он существует в одном экземпляре. Платформенного
около 700 на платформу.

Папка платформенного слоя называется `native`, а **не** `platform`: каталог
`desktop/MacOS/` попадает в `sys.path` как каталог запускаемого скрипта, и
пакет с именем `platform` перекрыл бы одноимённый стандартный модуль, которым
пользуется `hwid.py`.

Модуля-моста между слоями нет. `shared/` пишет `from native import paths`, и
подставляется реализация из той папки, откуда запущено приложение. `run.py`
добавляет `desktop/` в `sys.path`, чтобы работал `from shared.models import ...`.

## Что переписывается

| Модуль | Windows (как есть) | macOS (новое) |
|---|---|---|
| `sysproxy` | реестр `Internet Settings` | `networksetup -setwebproxy` / `-setsecurewebproxy` / `-setsocksfirewallproxy` по всем активным сетевым сервисам, со снимком прежнего состояния для отката |
| `tun` | sing-box дочерним процессом + перезапуск с UAC | клиент unix-сокета к демону |
| `paths` | `%LOCALAPPDATA%\SCVPN` | `~/Library/Application Support/SCVPN`; `bin/` там же — внутрь `.app` писать нельзя |
| `hwid` | `MachineGuid` из реестра | `IOPlatformUUID` из `ioreg -rd1 -c IOPlatformExpertDevice` |
| `downloader` | zip, `xray.exe`, wintun | `Xray-macos-arm64-v8a.zip`; sing-box через `tarfile` и руками демона; wintun не нужен |
| `cleanup_stray` | `tasklist` / `taskkill` | `ps -p` / `kill` для xray; sing-box — забота демона |
| `ui/split_dialog` | `tasklist`, имена `.exe` | `ps -axo comm=`, фильтр по `/Applications/`, имена без расширения |
| `ui/theme` | Segoe UI, Consolas | системный шрифт, Menlo |

Без изменений: `models.py`, `subscription.py`, `xray_config.py`, `storage.py`,
`subinfo.py`, `ping.py`, `connect.py`, `core_runner.py` (там `CREATE_NO_WINDOW`
уже под `hasattr`), весь остальной `ui/`.

### Конфиг sing-box для macOS

Отличия от windows-варианта: убран `strict_route` (только Linux/Windows), убран
`interface_name` (устройство именует ядро), `stack` по умолчанию `gvisor` с
переключателем на `system` / `mixed` в меню «⋯» — калибровочный винт, который
в туннелях всегда нужен. Остальное совпадает: `auto_route: true`,
`auto_detect_interface: true`, `route_exclude_address`, правило `process_path`
для xray → `direct`, правила сплит-туннеля по `process_name`.

Матчинг по процессам на darwin требует root — он у демона есть. Работоспособность
правил `process_name` на darwin проверяется на первой рабочей сборке; если
не подтвердится, сплит-туннель для macOS помечается неподдерживаемым в UI,
а не тихо не работает.

## Иконка

Знак рисуется `setup/brand.py` (Pillow, 4× суперсэмплинг, LANCZOS). Иконка
генерируется **один раз** и коммитится готовым файлом `MacOS/setup/scvpn.icns`;
скрипта-генератора на стороне macOS нет.

Одна поправка против windows-варианта: у macOS-иконок знак занимает около 80 %
холста с прозрачным полем вокруг, иначе в доке иконка смотрится крупнее
соседних. Плашка рисуется на 824 px по центру холста 1024. Собирается полный
iconset (16, 32, 128, 256, 512 плюс @2x) и сворачивается `iconutil -c icns`.

## Сборка

`build.sh` → PyInstaller `BUNDLE` → `dist/SCVPN.app`, arm64, ad-hoc подпись
(`codesign -s -`). DMG не делается. В `Info.plist`:

- `NSCameraUsageDescription` — иначе сканер QR молча не получит камеру;
- `LSMinimumSystemVersion`;
- `NSHighResolutionCapable`.

Первый запуск без Developer ID — через ПКМ → «Открыть», это пишется в README.

## README

- Корневой: строка macOS в таблице платформ; третий блок в схеме «чем платформы
  отличаются» — про utun и демона; раздел сборки — `build.sh`; раздел «Фирменный
  знак» правится, потому что теперь `.icns` лежит готовым файлом, а не
  генерируется; из «Планов» ничего не убирается (там iOS).
- `desktop/README.md` расходится на `desktop/Windows/README.md` (текущий текст с
  поправкой путей под `shared/` и `native/`) и новый `desktop/MacOS/README.md`.

## Проверка

`smoke_test.py` переносится в обе платформенные папки; общая часть (парсинг,
сборка конфигов) уже платформенно-нейтральна. Для macOS добавляются проверки:

- сборка конфига sing-box не содержит `strict_route` и `interface_name`;
- валидатор параметров демона отбрасывает мусор (порт вне диапазона, имя
  приложения с `/`, неизвестный `split_mode`, невалидный IP);
- демон отказывается запускать бинарник вне своей root-овой папки;
- `sysproxy` восстанавливает прежнее состояние после `enable` → `disable`.

Последние две — самое ценное: это граница доверия и это то, что ломает интернет.

## Границы

Не делается: поддержка Intel; DMG; NetworkExtension; явные хуки на
сон/пробуждение; нотаризация и Developer ID.
