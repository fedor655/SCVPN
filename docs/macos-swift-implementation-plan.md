# План реализации: macOS-клиент SCVPN на Swift

> **Для исполнителя (агента).** Это рабочий план, а не обзор. Выполняй задачи по
> порядку, каждая задача заканчивается зелёными проверками и коммитом. Шаги
> помечены чекбоксами `- [ ]`. Если факт из Фазы 0 разошёлся с текстом плана —
> останавливайся и правь план, а не подгоняй код под текст.

**Цель.** Заменить Python/PySide6-реализацию macOS-клиента SCVPN нативным
Swift-приложением и нативным привилегированным демоном, сохранив все свойства
безопасности и все форматы данных без изменений.

**Архитектура.** Два исполняемых файла внутри одного бандла: `SCVPN` (SwiftUI,
от пользователя) и `scvpn-helper` (только Foundation, от root под launchd).
Общая логика — статическая библиотека `SCVPNCore`. Демон устанавливается через
`SMAppService.daemon(plistName:)`, plist едет внутри бандла. Протокол между
приложением и демоном — построчный JSON по unix-сокету — не меняется вообще.

**Стек.** Swift 5.10, SwiftPM (не `.xcodeproj`), XCTest, Foundation, SwiftUI,
AppKit, AVFoundation, CoreImage, IOKit, CryptoKit, ServiceManagement. Ноль
внешних зависимостей.

**Спецификация.** [docs/macos-swift-rewrite-plan.md](macos-swift-rewrite-plan.md)
— читать вместе с этим планом. Раздел 2.4 спецификации (15 инвариантов) —
приёмочный критерий Фазы 2, раздел 6 — список того, что менять нельзя.

---

## Global Constraints

Требования, действующие в каждой задаче плана. Значения скопированы дословно
из существующего кода и спецификации.

- **Минимальная система:** macOS 13.0 (`LSMinimumSystemVersion: 13.0` в
  `SCVPN.spec`). Любой API новее 13.0 — повод переписать, а не поднять планку.
- **Только Apple Silicon** (`arm64`). Сборка на Intel обрывается с ошибкой, как
  сейчас в `build.sh`.
- **Ноль SPM-зависимостей.** Распаковка zip — `/usr/bin/unzip`, распаковка
  tar.gz — `/usr/bin/tar`, обе есть в системе всегда.
- **Подпись ad-hoc:** `codesign --force --deep --sign -`. Hardened Runtime не
  включаем, App Sandbox не включаем, нотаризации нет.
- **Bundle identifier:** `com.scvpn.client`. Label демона: `com.scvpn.helper`.
- **Язык интерфейса и логов — русский**, тексты переносятся дословно из
  Python-версии, включая тексты ошибок в `HelperError`.
- **Форматы на диске заморожены:** `profiles.json`, `settings.json`,
  `sysproxy_backup.json` (включая старый формат без блока `proxy`),
  `xray_running.json`. Неизвестные ключи при чтении сохраняются и пишутся
  обратно.
- **Протокол сокета заморожен:** `/var/run/scvpn-helper.sock`, права `0660`,
  владелец `root:admin`, построчный JSON, команды `start`/`stop`/`status`/
  `install_singbox`/`remove_singbox`, односторонние кадры `{"log": "..."}`.
- **Константы времени:** `STOP_GRACE_SEC = 7`, `KILL_GRACE_SEC = 3`,
  `SWEEP_GRACE_SEC = 3`, `ExitTimeOut = 40`, `STOP_REPLY_TIMEOUT_SEC = 12.0`,
  `_MAX_LINE = 1 << 20`, `_OUTBOX_LIMIT = 256`, `_MAX_SPLIT_APPS = 256`,
  `_MAX_EXCLUDE_IPS = 1024`, `_MAX_APP_NAME = 64`.
- **Старый Python-код не удаляется** до конца Фазы 8. Обе реализации живут
  рядом; `desktop/MacOS/` трогаем только в двух местах, оговорённых явно.

---

## 0. Отклонения от спецификации и почему

Спецификация (`macos-swift-rewrite-plan.md`) в трёх местах предлагает решения,
которые этот план меняет. Каждое — с обоснованием; если обоснование не
убеждает, обсуждать надо до начала работ, а не в середине Фазы 2.

### 0.1. SwiftPM вместо `.xcodeproj`

Спецификация (раздел 3.1) предполагает Xcode-проект. План использует пакет
SwiftPM плюс скрипт сборки бандла.

Причины:

- `.xcodeproj` — это `project.pbxproj`, машинно-порождённый файл на несколько
  тысяч строк с UUID-ключами. Ни человек, ни агент не правят его надёжно, а
  весь план строится на добавлении файлов и таргетов по шагам.
- `swift test` работает из коробки и в CI, и локально; `xcodebuild test`
  требует схем, которые живут в том же `.pbxproj`.
- Сборка `.app` — это создание трёх каталогов, копирование двух бинарников,
  `Info.plist`, `.icns` и plist демона. Тридцать строк `build.sh` против
  непрозрачной конфигурации фаз копирования.
- Отладка в Xcode остаётся возможной: Xcode открывает `Package.swift` как
  проект.

Цена: SwiftUI-приложение из SPM-таргета обязано запускаться **только** из
собранного бандла (`Bundle.main` должен указывать на `.app`, иначе не
подхватится `Info.plist` с `NSCameraUsageDescription` и приложение получит
неправильную activation policy). Значит `swift run` для приложения не
используется — только `./build.sh && open dist/SCVPN.app`. Для демона и для
тестов `swift run`/`swift test` работают как обычно.

### 0.2. Внедрение зависимостей вместо модульных глобалей

Проверки демона в `test_native.py` подменяют `daemon.BIN_DIR`, `daemon.RUN_DIR`,
`daemon.check_binary`, `daemon.STOP_GRACE_SEC` (см. `_Stand.serve_here`). В
Swift подменить глобальную константу нельзя. Поэтому вся конфигурация демона
собирается в один тип `HelperEnv`, который передаётся в `Supervisor` и в
обработчик команд аргументом. Продакшен-значения — `HelperEnv.production`,
тестовые — `HelperEnv.testing(tmp:)`.

Это не украшение: без этого ни одна из ~25 проверок демона не пишется.

### 0.3. Мост между Swift-демоном и Python-приложением на время Фазы 2

Спецификация (раздел 4.1) верно требует, чтобы критерием готовности Фазы 2 была
работа **Python-приложения со Swift-демоном**. Но она не заметила противоречия:
Python-приложение ставит демона через `helper/install.py` (osascript + plist в
`/Library/LaunchDaemons`), а Swift-демон по плану ставится через `SMAppService`
из бандла, которого в Фазе 2 ещё нет.

Решение: в Фазе 2 Swift-демон ставится **вручную**, скриптом
`Tools/install-helper-dev.sh` — обычный plist в `/Library/LaunchDaemons` и
`launchctl bootstrap`, ровно то, что делает сегодняшний Python-установщик, но с
`ProgramArguments`, указывающим на собранный Swift-бинарник. Python-приложение
при этом надо заставить считать демона установленным: для этого скрипт пишет
plist с точно тем же содержимым, которое вернёт `plist_text()`… — нет, не
получится, там `ProgramArguments` другой. Поэтому проще и честнее: в
Фазе 2 Python-приложение запускается с переменной окружения
`SCVPN_ASSUME_HELPER=1`, а в `desktop/MacOS/helper/install.py::installed()`
добавляется одна строка:

```python
if os.environ.get("SCVPN_ASSUME_HELPER"):
    return True
```

Это единственная правка Python-кода за весь план, она помечается комментарием
`# только для стенда Фазы 2 плана переписывания` и удаляется в Фазе 8.

### 0.4. Один инвариант из раздела 6 спецификации сознательно нарушается

`/Library/LaunchDaemons/com.scvpn.helper.plist` перестаёт существовать: под
`SMAppService` plist живёт в `SCVPN.app/Contents/Library/LaunchDaemons/`.
Вместе с ним исчезает `/Library/Application Support/SCVPN/code`
(`paths.HELPER_CODE_DIR`). Остальные пути раздела 6 сохраняются все.

Последствие для пользователя, у которого стоит Python-версия: старый plist
останется на диске и launchd будет вечно перезапускать несуществующий путь.
Поэтому Задача 3.4 обязана снять его явно.

---

## Фаза −1. Дешёвые правки в Python-версии (0.5–1 день)

Спецификация, вопрос 10.7, честно спрашивает, стоит ли вообще переписывать.
Честный ответ: две правки ниже дают заметную часть выигрыша за день и делают
Фазу 0 почти бесплатной. Их надо сделать **до** решения о переписывании, и они
полезны независимо от этого решения.

### Задача −1.1: Починить латентный TCC-баг текущей сборки

**Файлы:**
- Modify: `desktop/MacOS/helper/install.py:193` (функция `install`)
- Test: `desktop/MacOS/test_native.py`

Спецификация, раздел 4.3-bis: собранное `.app` в `~/Downloads` даёт демона,
которого root не может прочитать, при том что `installed()` отвечает `True`.

- [x] **Шаг 1: Подтвердить баг экспериментально**

```bash
cd desktop/MacOS && ./build.sh
cp -R dist/SCVPN.app ~/Downloads/
open ~/Downloads/SCVPN.app
# включить TUN, ввести пароль, затем:
tail -20 /var/log/scvpn-helper.log
```

**Результат (не воспроизводился заново, 2026-08-15).** Живой прогон требует
ввода пароля администратора и разрешения TCC — в неинтерактивной сессии
недоступен. Механизм при этом подтверждён по коду и уже описан в
`helper/install.py::_code_steps` для варианта «из исходников»: root получает
EPERM на `open()` в `~/Documents`, `~/Desktop`, `~/Downloads`. Для собранного
`.app` та же дыра оставалась открытой — `ProgramArguments` указывает внутрь
бандла, где бы он ни лежал. Отказ реализован шагом 4; воспроизведение бага
живьём остаётся необязательным подтверждением.

- [x] **Шаг 2: Написать падающую проверку**

```python
@check
def test_install_refuses_bundle_in_tcc_protected_folder():
    from helper import install
    from native import paths
    with mock.patch.object(paths, "FROZEN", True), \
         mock.patch.object(paths, "ROOT", Path.home() / "Downloads" / "SCVPN.app" / "Contents" / "MacOS"):
        try:
            install.install()
        except RuntimeError as e:
            assert "Applications" in str(e), str(e)
        else:
            raise AssertionError("установка не отказалась из TCC-папки")
```

- [x] **Шаг 3: Запустить, убедиться, что падает**

Run: `./test.sh` — Expected: FAIL, «установка не отказалась из TCC-папки».

- [x] **Шаг 4: Реализовать отказ**

В начало `install()`:

```python
_TCC_DIRS = (Path.home() / "Documents", Path.home() / "Desktop", Path.home() / "Downloads")

def _refuse_tcc_location() -> None:
    """root не читает ~/Documents, ~/Desktop, ~/Downloads — TCC отдаёт EPERM.

    Демон, запущенный launchd из такой папки, не стартует никогда, а
    installed() при этом честно отвечает True: plist на месте. Получается
    компонент, который «установлен» и не работает. Отказываем на входе.
    """
    if not paths.FROZEN:
        return
    app = paths.ROOT.parent.parent  # .../SCVPN.app/Contents/MacOS -> .../SCVPN.app
    for bad in _TCC_DIRS:
        if app.is_relative_to(bad):
            raise RuntimeError(
                "Перенеси SCVPN.app в /Applications и запусти оттуда.\n"
                "Из этой папки системный компонент не запустится: у процессов "
                "root нет доступа к Документам, Рабочему столу и Загрузкам."
            )
```

- [x] **Шаг 5: Проверки зелёные**

Run: `./test.sh` — Expected: PASS.

**Результат:** `test_install_refuses_bundle_in_tcc_protected_folder` — ok.
Из 90 проверок падает одна, `test_native_contract_covers_both_platforms`, и
падает она не из-за этой задачи: в рабочем дереве лежит незакоммиченный
`desktop/MacOS/native/titlebar.py`, парного модуля для Windows нет. Это чужая
недоделанная правка, к Фазе −1 отношения не имеет.

- [ ] **Шаг 6: Коммит**

```bash
git add desktop/MacOS/helper/install.py desktop/MacOS/test_native.py && git commit -m "fix: отказ ставить демона из TCC-защищённой папки"
```

**Не выполнен намеренно.** В обоих файлах на момент правки уже лежали чужие
незакоммиченные изменения (`git diff --stat`: install.py +71, test_native.py
+176). `git add` этих файлов утащил бы их в коммит про TCC. Правка сделана и
проверена, решение о коммите — за владельцем этих изменений.

### Задача −1.2: Убрать opencv из зависимостей

**Файлы:**
- Modify: `desktop/shared/ui/qr_scanner.py`
- Modify: `desktop/MacOS/requirements.txt`

`qr_scanner.py::_open_camera` использует `cv2.CAP_DSHOW` — Windows-only бэкенд,
на macOS всегда падает в запасную ветку. Сама зависимость
`opencv-python-headless` — десятки мегабайт в бандле.

Ленивый вариант: на darwin заменить захват и детектирование на `pyobjc`-обёртку
AVFoundation (`pyobjc-framework-AVFoundation` уже тянется PySide6? — нет, не
тянется; проверить). Если pyobjc окажется дороже opencv по весу — задачу
закрыть как нецелесообразную и записать это здесь. Решение принимается по факту
замера `du -sh dist/SCVPN.app` до и после.

- [x] **Шаг 1: Замерить текущий вес бандла**

```bash
du -sh desktop/MacOS/dist/SCVPN.app
```

**223 МБ** (2026-08-15, macOS 26.6.1, Python 3.14).

- [x] **Шаг 2: Замерить вклад opencv**

```bash
du -sh desktop/MacOS/venv/lib/python3*/site-packages/cv2
```

**119 МБ** в venv, **118 МБ** внутри бандла
(`dist/SCVPN.app/Contents/Frameworks/cv2`, из них 40 МБ — сам `cv2.abi3.so`).
Для сравнения: PySide6 в venv — 1.1 ГБ.

- [x] **Шаг 3: Принять решение и записать его в этот файл**

Порог «меньше 30 МБ — закрываем» не сработал: 118 МБ это **53% веса бандла**,
задача по букве плана целесообразна.

**Решение: не делать, задача закрыта как поглощённая.** Обоснование: переписывание
идёт (см. −1.3), а Задача 6.5 убирает opencv целиком, заменяя его на
`AVCaptureMetadataOutput`. Замена захвата на pyobjc-обёртку AVFoundation в
Python — это тот же самый код, написанный дважды, второй раз ради версии,
которая удаляется в Фазе 8. Единственное, что этим покупалось бы, — вес
Python-бандла на время переходного периода. Замер записан здесь, чтобы
выигрыш Фазы 6 (−118 МБ только на opencv) был подтверждён числом, а не
ожиданием.

### Задача −1.3: Прикинуть `SMAppService` из Python (решение о переписывании)

**Файлы:**
- Create: `desktop/MacOS/tools/smappservice_probe.py`

Спецификация, вопрос 10.7: `SMAppService` доступен и Python-версии через
pyobjc, то есть избавиться от osascript и копирования кода можно **не
переписывая проект**.

- [x] **Шаг 1: Оценить**

Если Фаза 0 подтвердит, что `SMAppService` работает, а Задача −1.1 закроет
TCC-баг — остаётся ровно два выигрыша от плана A: вес бандла и скорость
старта. Это надо честно взвесить и записать решение здесь **до** Фазы 1.

**Стоп-условие плана.** Если по итогам Фазы −1 выигрыш не оправдывает 6–9
недель — остановиться. Дальнейшие фазы выполняются только после явного
подтверждения.

**Результат: продолжаем.** Явное подтверждение получено от владельца проекта
(2026-08-15, «реализуй план»). Зонд `smappservice_probe.py` не писался: он
отвечал на вопрос «переписывать или нет», а ответ уже дан. Честная запись
того, что при этом остаётся невыясненным: аргумент «`SMAppService` доступен и
Python-версии через pyobjc» не проверялся, то есть возможность закрыть
osascript **без** переписывания не опровергнута — она просто не выбрана.

Числа, на которых стоит решение: бандл 223 МБ, из них opencv 118 МБ и PySide6
основная часть остатка; Swift-бандл — два бинарника без интерпретатора.

---

## Фаза 0. Разведка (0.5–1 день)

Каждый пункт — эксперимент с записываемым результатом. Результат вносится
**в этот файл**, под пунктом, с датой и версией macOS. Пункты 1 и 2
спецификации уже закрыты (`SMAppService` с ad-hoc работает; `kern.argmax =
1048576`), здесь их нет.

**Общий зонд.** Пункты 3–6 проверяются одним приложением-зондом. Собери его в
`/tmp/SMProbe.app` по раскладке из спецификации, раздел 4.3, с логированием
`SMAppService.daemon(plistName:).status` в `/tmp/smprobe.log`.

> **Статус Фазы 0 на 2026-08-15: закрыты 0.1–0.8. Открыта только 0.9.**
>
> **Стоп-условие плана A снято:** `KeepAlive` под `SMAppService` работает
> (Задача 0.4), PID сменился после `kill -9`.
>
> Что уже решено по итогам замеров:
>
> - Периодическая сверка `status` в Задаче 3.2 **не нужна** — регистрация
>   переживает перезагрузку (0.1).
> - Безусловный `unregister()` + `register()` по версии в Задаче 3.2 **нужен** —
>   plist из подменённого бандла не перечитывается (0.3).
>
> - **Задача 3.3 вычёркивается целиком** — ограничения по расположению бандла
>   нет (0.5), из `~/Downloads` демон поднимается от root без помех (0.6).
> - Подмена `.app` на месте путём обновления не является: служба перестаёт
>   подниматься вовсе (0.2).
>
> Первый заход по 0.2, 0.5 и 0.6 дал негодные данные (короткое ожидание после
> `kickstart`; BTM помнил согласие прежнего зонда и отвечал памятью вместо
> папки). Зонд исправлен — `--suffix` даёт каждому месту чистую запись в BTM,
> отметка в журнале содержит абсолютный путь через `proc_pidpath`. Обе версии
> замеров оставлены под задачами: испорченная помечена как таковая.
>
> **Задача 0.9 остаётся открытой** — сплошное чтение `test_native.py` (2927
> строк) с выпиской свойств. Один инвариант, которого не было в разделе 2.4,
> уже нашёлся сам, в Фазе 2 (SIGPIPE, №16 в Приложении А), — это довод в пользу
> того, что задачу пропускать нельзя.
>
> **Что от исходов Фазы 0 не зависит:** Фазы 1, 2, 4 и 5. Демон, ядро логики и
> платформенный слой пишутся одинаково при любом ответе.
>
> Предопределённые пункты (0.7, 0.8) закрыты решением, как план и предписывал —
> см. записи под ними.

### Задача 0.1: Регистрация переживает перезагрузку

- [ ] **Шаг 1:** Зарегистрировать зонд, дождаться `.enabled`, перезагрузить
  Mac.
- [ ] **Шаг 2:** После входа проверить:

```bash
launchctl print system/com.scvpn.smprobe | head -20
```

- [x] **Шаг 3:** Записать результат.

**Результат: да, переживает.** После перезагрузки и входа:

```
system/com.scvpn.smprobe = {
	active count = 1
	path = (submitted by smd.332)
	managed_by = com.apple.xpc.ServiceManagement
	state = running
```

Демон при этом отметился в журнале заново — регистрация не просто уцелела,
служба поднялась сама. Периодическая сверка `status` в Задаче 3.2 **не нужна**.

**Если нет:** приложение обязано проверять `status` при каждом запуске и
предлагать регистрацию заново — это меняет Задачу 3.2 (там появляется
периодическая сверка, а не разовая).

**Условия всех замеров:** 2026-08-15, macOS 26.6.1 (25G76), Apple Silicon, зонд `Tools/smprobe`, подпись ad-hoc.


### Задача 0.2: launchd подхватывает новый бинарник после подмены `.app`

- [ ] **Шаг 1:** Собрать зонд версии A, зарегистрировать, дождаться `.enabled`.
- [ ] **Шаг 2:** Собрать версию B (демон пишет в лог другую строку), заменить
  `/Applications/SMProbe.app`.
- [ ] **Шаг 3:** Снять демона и посмотреть, чей код поднимется:

```bash
sudo launchctl kickstart -k system/com.scvpn.smprobe
sleep 2 && tail -5 /tmp/smprobe.log
```

- [x] **Шаг 4:** Записать результат.

**Результат переспроса: служба после подмены бандла не поднимается вовсе.**

Свежая личность `com.scvpn.smprobe2`, версия A в `/Applications`,
зарегистрирована и разрешена, процесс работал
(`pid=1953 exe=/Applications/SMProbe2.app/…`, `version=A`). Затем бандл заменён
на версию B, `launchctl kickstart -k`, ожидание 15 секунд:

```
=== чей код:
[2026-08-15T10:38:32Z] helper alive, version=A pid=1952 exe=/Users/Shared/SMProbe5.app/...
[2026-08-15T10:38:33Z] helper alive, version=A pid=1953 exe=/Applications/SMProbe2.app/...
=== ExitTimeOut:
	exit timeout = 40
```

Новой отметки нет ни одной. При этом служба в launchd жива и держит прежний
`ExitTimeOut`. То есть подмена `.app` на месте **не** поднимает новый код и
**не** оставляет работать старый: служба просто перестаёт подниматься.

Различить «не перезапустилась» и «перезапустилась и молча упала» нечем —
`/tmp/smprobe-stderr.log` снесён уборкой. На вывод это не влияет: подмена
бандла на месте не является путём обновления ни в одном из двух прочтений.

**Решение — то же, что и по Задаче 0.3, и теперь оно подпёрто дважды:** Задача
3.2 получает безусловный `unregister()` + `register()` при несовпадении версии,
ключ `helper_version` в `settings.json` заводится.

**Прежний заход (для истории).** После подмены бандла и
`launchctl kickstart -k` в журнале не появилось **ни одной** новой строки:
последние две — `version=A`, PID 31647 и 31674, обе от событий до подмены.
`sleep 3` короче паузы, которую launchd держит перед перезапуском. `version=B`
появился только после перезагрузки, а это ответ на Задачу 0.1, не на эту.

Вдобавок `exe=` в журнале был относительным (`Contents/MacOS/smprobe-helper`) —
по нему нельзя сказать, из какого бандла поднялся процесс. Зонд исправлен:
пишет абсолютный путь через `proc_pidpath`.

**Практического значения исход уже не имеет:** Задача 0.3 показала, что plist из
подменённого бандла не перечитывается, и безусловный `unregister()` +
`register()` по версии в Задачу 3.2 приезжает в любом случае. Переспрос нужен
для полноты записи, а не для развилки.

**Если запускается старый:** приложение при обновлении обязано звать
`unregister()` + `register()`. Это добавляет шаг в Задачу 3.2 и делает
версионирование явным (ключ `helper_version` в `settings.json`).

### Задача 0.3: Изменённый plist внутри бандла подхватывается без `register()`

Критично: `ExitTimeOut = 40` — расчёт худшего случая снятия, а не украшение.

- [ ] **Шаг 1:** Зонд версии A с `ExitTimeOut` 40, зарегистрировать.
- [ ] **Шаг 2:** Версия B с `ExitTimeOut` 41, подменить `.app`.
- [ ] **Шаг 3:** Проверить:

```bash
sudo launchctl print system/com.scvpn.smprobe | grep -i "exit timeout"
```

- [x] **Шаг 4:** Записать результат.

**Результат: НЕ подхватывается.** Бандл в `/Applications` подменён на версию с
`ExitTimeOut 41`, следом `launchctl kickstart -k`:

```
$ sudo launchctl print system/com.scvpn.smprobe | grep -i "exit timeout"
	exit timeout = 40
```

Служба продолжает жить со значением из plist, прочитанного при `register()`.

**Последствия приняты, оба:**

1. Задача 3.2 получает **безусловный** `unregister()` + `register()` при
   несовпадении версии демона. Это не оптимизация, а условие корректности:
   `ExitTimeOut = 40` — расчёт худшего случая снятия, и служба, живущая со
   старым значением, получает SIGKILL на середине снятия, оставляя `sing-box`
   сиротой с маршрутами.
2. `ExitTimeOut` проверяется отдельной XCTest-проверкой на содержимое plist в
   бандле — `test_bundled_plist_exit_timeout_covers_worst_case_stop`, уже
   написана (Задача 1.2), пересчитывает худший случай по фактическим константам
   демона.

**Не измерено:** перечитывается ли plist после **перезагрузки**. Бинарник после
неё обновился (`version=B`), про `ExitTimeOut` замера нет. На решение выше это
не влияет — `unregister()` + `register()` закрывает оба случая.

### Задача 0.4: `KeepAlive` под `SMAppService`

Инвариант 7 (раздел 2.4 спецификации): демон обязан пережить собственное
падение, иначе `sing-box` остаётся без надзора.

- [ ] **Шаг 1:** Добавить в plist зонда `KeepAlive: true`, зарегистрировать.
- [ ] **Шаг 2:**

```bash
PID=$(sudo launchctl print system/com.scvpn.smprobe | awk '/pid = /{print $3}')
sudo kill -9 "$PID"
sleep 3
sudo launchctl print system/com.scvpn.smprobe | awk '/pid = /{print $3}'
```

- [x] **Шаг 3:** PID обязан смениться на новый. Записать результат.

**Результат: работает. Стоп-условие снято, план A жизнеспособен.**

```
было PID=31647
стало PID=31674
```

Журнал демона подтверждает вторую отметку о старте, то есть поднялся именно
новый процесс, а не остался прежний. Инвариант 7 под `SMAppService` держится:
демон переживает собственное падение, `sing-box` без надзора не остаётся.

**Если нет:** план A нежизнеспособен в предложенном виде — нужен либо возврат к
`launchctl bootstrap` (и тогда Фаза 3 возвращается к 2–4 дням и osascript), либо
внешний сторож. Останавливаться и обсуждать.

### Задача 0.5: Обязательно ли `/Applications`

- [ ] **Шаг 1:** Зарегистрировать зонд из `~/Applications`, затем из
  `/Users/Shared/`.
- [ ] **Шаг 2:** Записать, из каких мест `register()` доходит до
  `requiresApproval`, а из каких нет.

- [x] **Результат переспроса: ограничения по месту нет.**

Со свежей личностью (`--suffix`, чистая запись в BTM) `/Users/Shared` ведёт
себя ровно как `/Applications`: `register()` бросает `code=1`, статус
`requiresApproval`, после согласия пользователя служба поднимается —
`pid=1952 exe=/Users/Shared/SMProbe5.app/Contents/MacOS/smprobe-helper`,
`euid=0`.

Итог по всем четырём местам: `/Applications`, `~/Applications`,
`/Users/Shared`, `~/Downloads` — везде `register()` доходит до
`requiresApproval`, а после согласия служба работает. Прежний `notRegistered`
из `/Users/Shared` был артефактом переиспользованной личности, а не свойством
папки.

**Следствие: Задача 3.3 вычёркивается.** Проверять `Bundle.main.bundleURL` не
на что — отказывать не за что.

**Прежний, испорченный замер (для истории).** BTM запоминает согласие по
идентификатору бандла, а зонд везде был один и тот же
(`com.scvpn.smprobe`). Согласие, выданное для `/Applications`, дальше
открывало дверь из любой папки — и `~/Applications`, и `~/Downloads` дали
`enabled` **без** approval. Это ответ про память системы, а не про папку.

Один результат при этом чистый, потому что он отрицательный и памятью не
объясняется:

| Место | `register()` | Статус |
|---|---|---|
| `/Applications` | бросил `code=1` | `requiresApproval`, после согласия `enabled` |
| `~/Applications` | без ошибки | `enabled` (согласие уже было) |
| **`/Users/Shared`** | **бросил `code=1`** | **`notRegistered` — отказ наглухо** |
| `~/Downloads` | без ошибки | `enabled` (согласие уже было) |

`/Users/Shared` отличается от `/Applications` тем, что не дошёл даже до
`requiresApproval`: система не приняла бандл вовсе. Это не вопрос согласия
пользователя.

Зонд исправлен: `--suffix N` даёт каждому месту свою личность
(`com.scvpn.smprobe2`, `…3`), для BTM это разные службы, каждая с чистого
листа.

**Если да, обязательно:** Задача 3.1 получает проверку `Bundle.main.bundleURL`
с внятным текстом отказа (та же, что в Задаче −1.1).

### Задача 0.6: `SMAppService` и TCC

Спецификацией не поставлен, но это тот же вопрос, что закрывала Задача −1.1.
Бинарник демона лежит внутри `.app`; если `.app` в `~/Downloads`, root его не
прочитает.

- [ ] **Шаг 1:** Положить зонд в `~/Downloads`, попытаться зарегистрировать.
- [ ] **Шаг 2:** Записать: доходит ли до `.enabled` и поднимается ли процесс.

- [x] **Результат переспроса: работает, TCC не мешает.**

Свежая личность `com.scvpn.smprobe6`, бандл в `~/Downloads`, согласие выдано
заново:

```
статус: enabled — служба зарегистрирована и разрешена [rawValue=1]
[2026-08-15T10:37:41Z] helper alive, version=A pid=1852 euid=0
    exe=/Users/chasonick/Downloads/SMProbe6.app/Contents/MacOS/smprobe-helper
```

Демон поднялся от root **из TCC-защищённой папки** — launchd прочитал и
запустил бинарник внутри бандла. Абсолютный путь в отметке снимает прошлую
неоднозначность: это именно `~/Downloads`, а не перезапуск чужого зонда.

Почему это отличается от Python-версии. Там launchd запускал интерпретатор по
абсолютному пути внутрь пользовательской папки, и `open()` на `pyvenv.cfg`
получал EPERM. Здесь путь — `BundleProgram` относительно бандла,
зарегистрированного через `SMAppService`, и доступ система выдаёт сама вместе с
регистрацией.

**Следствие: Задача 3.3 не нужна.** Баг Задачи −1.1 в Swift-версии не
воспроизводится — он был свойством способа запуска, а не папки.

**Прежний, неоднозначный замер (для истории).** Из `~/Downloads` статус дошёл до
`enabled`, но это на зонде с уже выданным согласием (см. 0.5). Про запуск
процесса журнал ответить не может:

```
[2026-08-15T10:33:01Z] helper alive, version=B pid=1447 euid=0 exe=Contents/MacOS/smprobe-helper
[2026-08-15T10:33:08Z] helper alive, version=B pid=1469 euid=0 exe=Contents/MacOS/smprobe-helper
```

Строки в семи секундах друг от друга, `exe=` относительный. `pid=1469` — это
либо запуск из `~/Downloads`, либо перезапуск по `KeepAlive` того, что стартовал
из `~/Applications` шагом раньше. Различить нечем.

**Это самый важный из открытых пунктов Фазы 0**, потому что от него зависит,
нужна ли Задача 3.3. Худший исход — дойти до `enabled` и не запуститься:
компонент «установлен» и не работает, ровно то, что Задача −1.1 закрывала в
Python-версии. Зонд исправлен: пишет абсолютный путь через `proc_pidpath`.

### Задача 0.7: `NWConnection` и AF_UNIX

- [ ] **Шаг 1:** Написать 30-строчный спайк, соединяющийся с
  `/var/run/scvpn-helper.sock` через `NWConnection(to: .unix(path:))`.
- [ ] **Шаг 2:** Записать результат.

**Ожидаемое решение независимо от исхода:** используем POSIX. Пункт нужен
только чтобы вопрос не всплыл в середине Фазы 2.

**Закрыт решением, спайк не писался.** Демон обязан обходиться Foundation и
POSIX: он поднимается от root под launchd, и лишний фреймворк в этом процессе
— лишняя причина не подняться. `socket(AF_UNIX)` + `read`/`write` уже написан
в Задачах 2.11 и 2.12 и работает. `NWConnection` вернулся бы в разговор только
если бы POSIX не хватило — не понадобился.

### Задача 0.8: quarantine на скачанном `xray`

- [ ] **Шаг 1:** Спайк: `URLSession` скачивает файл, затем
  `xattr -l` на результате.
- [ ] **Шаг 2:** Записать результат.

**Решение принимается заранее, независимо от исхода:** `CoreDownloader` всегда
зовёт `removexattr(path, "com.apple.quarantine", 0)` и игнорирует `ENOATTR`.
Одна строка снимает вопрос целиком. Эксперимент — подтверждение, а не развилка.

**Закрыт решением, спайк не писался.** Развилки нет: строка ставится
безусловно, оба исхода эксперимента ведут к одному и тому же коду. Реализуется
в Задаче 5.2.

### Задача 0.9: Проверить, что раздел 2.4 спецификации полон

Вопрос 10.8 спецификации: инварианты собраны чтением комментариев, возможно,
что-то держится на структуре кода и нигде не описано.

- [ ] **Шаг 1:** Прочитать `desktop/MacOS/test_native.py` целиком (2927 строк),
  выписать имя каждой проверки и одну строку о том, какое свойство она держит.
- [ ] **Шаг 2:** Сверить со списком раздела 7 спецификации и разделом 2.4.
- [ ] **Шаг 3:** Дописать найденное в таблицу «Инварианты → проверки» этого
  файла (см. раздел «Приложение А»).

Это самая скучная и самая ценная задача Фазы 0. Пропускать нельзя: цена
пропущенного инварианта — потерянный интернет у пользователя.

---

## Фаза 1. Каркас (1 день)

### Задача 1.1: Пакет SwiftPM с тремя таргетами

**Файлы:**
- Create: `desktop/MacOS-Swift/Package.swift`
- Create: `desktop/MacOS-Swift/Sources/SCVPNCore/Placeholder.swift`
- Create: `desktop/MacOS-Swift/Sources/SCVPNHelper/main.swift`
- Create: `desktop/MacOS-Swift/Sources/SCVPNApp/main.swift`
- Test: `desktop/MacOS-Swift/Tests/SCVPNCoreTests/PlaceholderTests.swift`

**Interfaces:**
- Produces: таргеты `SCVPNCore` (library), `SCVPNHelper` (executable),
  `SCVPNApp` (executable), `SCVPNCoreTests`, `SCVPNHelperTests`.

- [x] **Шаг 1: Написать `Package.swift`**

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SCVPN",
    platforms: [.macOS(.v13)],
    targets: [
        // Общая логика: без AppKit, без SwiftUI. Линкуется и в приложение,
        // и в демона, и в оба тестовых таргета.
        .target(name: "SCVPNCore"),

        // Демон. Отдельный исполняемый файл, а не флаг приложения: он
        // обязан подниматься даже когда с приложением что-то не так, и у
        // него нет ни одной причины загружать графические фреймворки
        // под root.
        .executableTarget(name: "SCVPNHelper", dependencies: ["SCVPNCore"]),

        .executableTarget(name: "SCVPNApp", dependencies: ["SCVPNCore"]),

        .testTarget(name: "SCVPNCoreTests", dependencies: ["SCVPNCore"]),
        // Логика демона живёт в SCVPNHelperKit, а не в исполняемом таргете:
        // тестовый таргет не может линковать executable.
        .target(name: "SCVPNHelperKit", dependencies: ["SCVPNCore"]),
        .testTarget(name: "SCVPNHelperTests", dependencies: ["SCVPNHelperKit"]),
    ]
)
```

Правь список `targets` так, чтобы `SCVPNHelper` зависел от `SCVPNHelperKit`, а
сам содержал только `main.swift` из десятка строк. Это обязательное следствие
ограничения SwiftPM: тестировать executable-таргет нельзя.

- [x] **Шаг 2: Написать проверку, что пакет вообще собирается и тестируется**

```swift
import XCTest
@testable import SCVPNCore

final class PlaceholderTests: XCTestCase {
    func test_package_builds() {
        XCTAssertEqual(SCVPNCore.buildMarker, "scvpn-core")
    }
}
```

- [x] **Шаг 3: Запустить, убедиться, что падает**

Run: `cd desktop/MacOS-Swift && swift test`
Expected: FAIL, «cannot find 'SCVPNCore' in scope».

- [x] **Шаг 4: Реализовать минимум**

```swift
// Sources/SCVPNCore/Placeholder.swift
public enum SCVPNCore {
    public static let buildMarker = "scvpn-core"
}
```

- [x] **Шаг 5: Проверки зелёные**

Run: `swift test` — Expected: PASS.

- [x] **Шаг 6: Коммит**

```bash
git add desktop/MacOS-Swift && git commit -m "feat: каркас пакета SwiftPM для macOS-клиента на Swift"
```

### Задача 1.2: Сборка бандла и ad-hoc подпись

**Файлы:**
- Create: `desktop/MacOS-Swift/build.sh`
- Create: `desktop/MacOS-Swift/Resources/Info.plist`
- Create: `desktop/MacOS-Swift/Resources/com.scvpn.helper.plist`

**Interfaces:**
- Produces: `dist/SCVPN.app` с раскладкой
  `Contents/{Info.plist, MacOS/SCVPN, MacOS/scvpn-helper, Resources/scvpn.icns,
  Library/LaunchDaemons/com.scvpn.helper.plist}`.

- [x] **Шаг 1: `Info.plist` приложения**

Ключи переносятся дословно из `SCVPN.spec`:

```xml
<key>CFBundleName</key><string>SCVPN</string>
<key>CFBundleDisplayName</key><string>SCVPN</string>
<key>CFBundleExecutable</key><string>SCVPN</string>
<key>CFBundleIdentifier</key><string>com.scvpn.client</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleIconFile</key><string>scvpn</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key>
<string>Камера нужна только чтобы считать QR-код ссылки подписки.</string>
<key>LSUIElement</key><false/>
```

- [x] **Шаг 2: plist демона**

Имя файла обязано совпадать с `Label` — это требование `SMAppService`.

```xml
<key>Label</key><string>com.scvpn.helper</string>
<key>BundleProgram</key><string>Contents/MacOS/scvpn-helper</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ExitTimeOut</key><integer>40</integer>
<key>StandardErrorPath</key><string>/var/log/scvpn-helper.log</string>
<key>StandardOutPath</key><string>/var/log/scvpn-helper.log</string>
```

- [x] **Шаг 3: `build.sh`**

```bash
#!/bin/bash
# Сборка SCVPN.app. Бинарники ядра (xray, гео-базы, sing-box) НЕ
# упаковываются: их качает само приложение, а sing-box обязан лежать в
# root-овой папке демона.
set -euo pipefail
cd "$(dirname "$0")"

[ "$(uname -m)" = "arm64" ] || { echo "[!] Сборка рассчитана на Apple Silicon"; exit 1; }

BUILD_DIR="${SCVPN_BUILD_DIR:-$PWD}"
APP="$BUILD_DIR/dist/SCVPN.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/SCVPNApp"    "$APP/Contents/MacOS/SCVPN"
cp "$BIN/SCVPNHelper" "$APP/Contents/MacOS/scvpn-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/com.scvpn.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp ../MacOS/setup/scvpn.icns "$APP/Contents/Resources/scvpn.icns"

# Снимаем расширенные атрибуты: codesign отказывается подписывать бандл, на
# файлах которого висит com.apple.provenance (его ставит macOS при обращении)
# или com.apple.fileprovider.fpfs (iCloud, если проект в синхронизируемой
# папке) — «resource fork, Finder information, or similar detritus not
# allowed». Атрибуты вернутся через десятки секунд, но уже поставленную
# подпись это не ломает — важно очистить их непосредственно перед codesign.
xattr -cr "$APP"

# Без Apple Developer ID подписываем сами собой. Вложенный бинарник демона
# подписывается первым: --deep не гарантирует порядок, а неподписанный
# BundleProgram SMAppService не примет.
codesign --force --sign - "$APP/Contents/MacOS/scvpn-helper"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "Готово: $APP"
```

- [x] **Шаг 4: Проверить, что бандл собирается и запускается**

```bash
chmod +x desktop/MacOS-Swift/build.sh && desktop/MacOS-Swift/build.sh && open desktop/MacOS-Swift/dist/SCVPN.app
```

Expected: пустое окно, иконка в Dock, приложение не падает.

- [x] **Шаг 5: Коммит**

```bash
git add desktop/MacOS-Swift && git commit -m "feat: сборка бандла и ad-hoc подпись"
```

---

## Фаза 2. Демон на Swift (1.5–2 недели)

Самая дорогая и самая опасная фаза. Порядок внутри неё — от чистых функций к
процессам и сокетам.

### Задача 2.1: `SingboxConfig` — валидация недоверенного ввода

**Файлы:**
- Create: `Sources/SCVPNCore/SingboxConfig/SplitMode.swift`
- Create: `Sources/SCVPNCore/SingboxConfig/Validation.swift`
- Test: `Tests/SCVPNCoreTests/ValidationTests.swift`

**Interfaces:**
- Produces:
  - `public enum SplitMode: String { case off, exclude, include }`
  - `public enum Stack: String { case gvisor, system, mixed }`
  - `public struct ValidationError: Error { public let message: String }`
  - `public struct SingboxParams { let socksPort: Int; let splitMode: SplitMode;
    let splitApps: [String]; let stack: Stack; let excludeIPs: [String];
    let logLevel: String }`
  - `public func validate(_ raw: [String: Any]) throws -> SingboxParams`

Прямой перенос `helper/config.py::validate`. Правила, каждое — отдельная
проверка:

| Поле | Правило | Нарушение |
|---|---|---|
| весь объект | должен быть словарём | `ValidationError` |
| `socks_port` | целое, не `Bool`, 1…65535 | `ValidationError` |
| `split_mode` | из `SplitMode` | `ValidationError` |
| `split_apps` | список строк | `ValidationError` |
| имя приложения | непустое после `trim`, ≤ 64 байт, без `/` и `\`, не `.`/`..`, кодируется в UTF-8 | `ValidationError` |
| `stack` | из `Stack` | `ValidationError` |
| `exclude_ips` | список; нестроки и неадреса **молча отбрасываются** | нет |
| `log_level` | из набора, иначе молча `warn` | нет |

- [x] **Шаг 1: Написать падающие проверки**

```swift
final class ValidationTests: XCTestCase {
    func test_rejects_non_object_params() {
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_mode": "нет"]))
    }

    func test_rejects_boolean_as_port() {
        // В Python bool — подкласс int, и True прошёл бы как порт 1.
        // В Swift JSONSerialization отдаёт NSNumber, у которого тот же
        // подвох: objCType == "c" для булева. Проверка обязана его ловить.
        XCTAssertThrowsError(try validate(["socks_port": true]))
    }

    func test_rejects_port_out_of_range() {
        XCTAssertThrowsError(try validate(["socks_port": 0]))
        XCTAssertThrowsError(try validate(["socks_port": 65536]))
    }

    func test_rejects_app_name_that_is_a_path() {
        XCTAssertThrowsError(try validate(["socks_port": 10808,
                                           "split_apps": ["/usr/bin/curl"]]))
    }

    func test_drops_garbage_from_exclude_ips_silently() throws {
        let p = try validate(["socks_port": 10808,
                              "exclude_ips": ["1.2.3.4", 5, "не адрес", "::1"]])
        XCTAssertEqual(p.excludeIPs, ["1.2.3.4", "::1"])
    }

    func test_unknown_log_level_falls_back_to_warn() throws {
        let p = try validate(["socks_port": 10808, "log_level": "вопли"])
        XCTAssertEqual(p.logLevel, "warn")
    }
}
```

- [x] **Шаг 2: Запустить, убедиться, что падают**

Run: `swift test --filter ValidationTests` — Expected: FAIL.

- [x] **Шаг 3: Реализовать**

Ключевая тонкость — булево вместо числа. `JSONSerialization` отдаёт булевы как
`NSNumber`, отличимый по `CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()`.
Проверять именно так, а не `is Bool`.

- [x] **Шаг 4: Проверки зелёные**
- [x] **Шаг 5: Коммит**

```bash
git commit -am "feat(core): валидация параметров sing-box"
```

### Задача 2.2: `SingboxConfig` — сборка конфига

**Файлы:**
- Create: `Sources/SCVPNCore/SingboxConfig/Builder.swift`
- Test: `Tests/SCVPNCoreTests/SingboxBuilderTests.swift`

**Interfaces:**
- Consumes: `SingboxParams` из Задачи 2.1
- Produces: `public func buildSingboxConfig(_ p: SingboxParams, xrayPath: String) -> [String: Any]`

Прямой перенос `helper/config.py::build`. Структура результата — дословно та же,
включая `"address": ["172.18.0.1/30"]`, `"mtu": 1500`, `auto_route: true`,
`auto_detect_interface: true`. Ни `strict_route`, ни `interface_name` — их на
darwin нет.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_xray_always_goes_direct_and_first() throws {
    let p = try validate(["socks_port": 10808])
    let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
    let rules = (cfg["route"] as! [String: Any])["rules"] as! [[String: Any]]
    // Первым правилом выводим из туннеля сам Xray: без этого соединение ядра
    // к серверу снова попадает в TUN, оттуда обратно в ядро — и так по кругу.
    XCTAssertEqual(rules[0]["process_path"] as? [String], ["/tmp/bin/xray"])
    XCTAssertEqual(rules[0]["outbound"] as? String, "direct")
}

func test_include_mode_sends_everything_else_direct() throws {
    let p = try validate(["socks_port": 10808, "split_mode": "include",
                          "split_apps": ["Safari"]])
    let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
    XCTAssertEqual((cfg["route"] as! [String: Any])["final"] as? String, "direct")
}

func test_exclude_mode_keeps_final_in_tunnel() throws {
    let p = try validate(["socks_port": 10808, "split_mode": "exclude",
                          "split_apps": ["Safari"]])
    let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
    XCTAssertEqual((cfg["route"] as! [String: Any])["final"] as? String, "to-xray")
}

func test_ipv4_gets_slash32_and_ipv6_gets_slash128() throws {
    let p = try validate(["socks_port": 10808, "exclude_ips": ["1.2.3.4", "2001:db8::1"]])
    let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
    let tun = (cfg["inbounds"] as! [[String: Any]])[0]
    XCTAssertEqual(tun["route_exclude_address"] as? [String],
                   ["1.2.3.4/32", "2001:db8::1/128"])
}

func test_empty_split_apps_produce_no_process_name_rule() throws {
    let p = try validate(["socks_port": 10808, "split_mode": "exclude", "split_apps": []])
    let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
    let rules = (cfg["route"] as! [String: Any])["rules"] as! [[String: Any]]
    XCTAssertEqual(rules.count, 1)
}
```

- [x] **Шаг 2: Запустить, убедиться, что падают**
- [x] **Шаг 3: Реализовать**
- [x] **Шаг 4: Проверки зелёные**
- [x] **Шаг 5: Коммит**

### Задача 2.3: `HelperEnv` и `checkBinary`

**Файлы:**
- Create: `Sources/SCVPNHelperKit/HelperEnv.swift`
- Create: `Sources/SCVPNHelperKit/BinaryCheck.swift`
- Test: `Tests/SCVPNHelperTests/BinaryCheckTests.swift`

**Interfaces:**
- Produces:

```swift
public struct HelperEnv {
    public var binDir: URL
    public var runDir: URL
    public var socketPath: String
    public var lockPath: String
    public var stopGrace: TimeInterval
    public var killGrace: TimeInterval
    public var sweepGrace: TimeInterval
    public var checkBinary: (URL) throws -> Void
    public var log: (String) -> Void
    // pgrep/pkill вынесены в поле, чтобы проверка «не смог посмотреть =
    // сирота жива» могла подсунуть отказ инструмента (Задача 2.6).
    public var procTool: ([String]) -> ProcResult?

    public static let production: HelperEnv
    public static func testing(tmp: URL) -> HelperEnv
}

public struct ProcResult { public let status: Int32; public let stdout: String; public let stderr: String }

public struct HelperPermissionError: Error { public let message: String }
public func checkBinary(_ path: URL, binDir: URL) throws
```

`checkBinary` — перенос `daemon.py::check_binary`. Порядок проверок **обязан**
остаться прежним, и вот почему: проверка на root стоит последней, иначе она
срабатывала бы первой на любом пользовательском файле и накрывала бы собой
остальные — в том числе в проверках, которые гоняются не от root.

Порядок: `realpath` (существование) → внутри `binDir` → не доступен на запись
группе и остальным → исполняемый → принадлежит root.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_refuses_binary_outside_its_dir() throws {
    let tmp = try makeTmp()
    let outside = tmp.appendingPathComponent("sing-box")
    try Data().write(to: outside)
    XCTAssertThrowsError(try checkBinary(outside, binDir: tmp.appendingPathComponent("bin")))
}

func test_refuses_user_writable_binary() throws {
    let (bin, exe) = try makeBinDirWithExecutable(mode: 0o777)
    XCTAssertThrowsError(try checkBinary(exe, binDir: bin))
}

func test_refuses_non_executable_binary() throws {
    let (bin, exe) = try makeBinDirWithExecutable(mode: 0o644)
    XCTAssertThrowsError(try checkBinary(exe, binDir: bin))
}

func test_resolves_symlinks_before_checking_location() throws {
    // Симлинк внутри binDir, ведущий наружу, обязан быть отклонён:
    // проверяем канонический путь, а не тот, что прислали.
    let (bin, _) = try makeBinDirWithExecutable(mode: 0o755)
    let link = bin.appendingPathComponent("sing-box-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
    XCTAssertThrowsError(try checkBinary(link, binDir: bin))
}
```

- [x] **Шаг 2: Запустить, убедиться, что падают**
- [x] **Шаг 3: Реализовать**

Использовать POSIX `realpath` и `stat`, не `FileManager`: нужны точные
`st_mode` и `st_uid`, а `resolvingSymlinksInPath()` не требует существования
файла и подменяет `/var` на `/private/var`.

```swift
public func checkBinary(_ path: URL, binDir: URL) throws {
    guard let real = realpath(path.path, nil) else {
        throw HelperPermissionError(message: "нет такого бинарника: \(path.path)")
    }
    defer { free(real) }
    let resolved = String(cString: real)
    guard let realBin = realpath(binDir.path, nil) else {
        throw HelperPermissionError(message: "нет папки бинарников: \(binDir.path)")
    }
    defer { free(realBin) }
    guard resolved.hasPrefix(String(cString: realBin) + "/") else {
        throw HelperPermissionError(message: "бинарник вне \(binDir.path): \(resolved)")
    }
    var st = stat()
    guard stat(resolved, &st) == 0 else {
        throw HelperPermissionError(message: "не смог прочитать \(resolved)")
    }
    if st.st_mode & UInt16(S_IWGRP | S_IWOTH) != 0 {
        throw HelperPermissionError(message: "бинарник доступен на запись не только root: \(resolved)")
    }
    if st.st_mode & UInt16(S_IXUSR) == 0 {
        throw HelperPermissionError(message: "бинарник не исполняемый: \(resolved)")
    }
    if st.st_uid != 0 {
        throw HelperPermissionError(message: "бинарник не принадлежит root: \(resolved)")
    }
}
```

- [x] **Шаг 4: Проверки зелёные**
- [x] **Шаг 5: Коммит**

### Задача 2.4: Проверка `xray_path` от клиента

**Файлы:**
- Create: `Sources/SCVPNHelperKit/XrayPathCheck.swift`
- Test: `Tests/SCVPNHelperTests/XrayPathCheckTests.swift`

**Interfaces:**
- Produces: `public func checkedXrayPath(_ raw: Any?) throws -> String`

Путь попадает в правило `process_path`, выпускающее процесс мимо туннеля.
Подставив туда чужой бинарник, злоумышленник раздал бы себе обход VPN.

Порядок: абсолютный путь → `realpath` → **имя проверяем после канонизации** →
это файл → не доступен на запись группе и остальным. Требования root-владельца
здесь нет намеренно: ядро Xray лежит в папке пользователя и ему же принадлежит.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_rejects_symlink_named_xray_pointing_at_shell() throws {
    // Ровно тот обход, который эта функция обязана закрыть: раньше имя
    // проверялось ДО канонизации, и симлинк с именем xray, ведущий на
    // /bin/sh, уезжал в правило process_path как /bin/sh.
    let tmp = try makeTmp()
    let link = tmp.appendingPathComponent("xray")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
    XCTAssertThrowsError(try checkedXrayPath(link.path))
}

func test_rejects_relative_path() {
    XCTAssertThrowsError(try checkedXrayPath("bin/xray"))
}

func test_rejects_group_writable_core() throws {
    let exe = try makeFile(name: "xray", mode: 0o775)
    XCTAssertThrowsError(try checkedXrayPath(exe.path))
}

func test_accepts_plain_user_owned_xray() throws {
    let exe = try makeFile(name: "xray", mode: 0o755)
    XCTAssertEqual(try checkedXrayPath(exe.path), exe.resolvingSymlinksInPath().path)
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 2.5: Единственность демона (`flock`)

**Файлы:**
- Create: `Sources/SCVPNHelperKit/SingletonLock.swift`
- Test: `Tests/SCVPNHelperTests/SingletonLockTests.swift`

**Interfaces:**
- Produces: `public final class SingletonLock { public init(path: String) throws }`

Дескриптор держится полем объекта и объект — свойством демона: если дескриптор
попадёт только в локальную переменную, ARC закроет его вместе с блокировкой, и
второй демон спокойно встанет следом за первым. Это прямой перенос причины, по
которой в Python `_lock_fd` — модульная переменная.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_second_lock_on_same_path_fails() throws {
    let path = try makeTmp().appendingPathComponent("l").path
    let first = try SingletonLock(path: path)
    XCTAssertThrowsError(try SingletonLock(path: path))
    withExtendedLifetime(first) {}
}

func test_lock_is_released_when_object_dies() throws {
    let path = try makeTmp().appendingPathComponent("l").path
    do { _ = try SingletonLock(path: path) }
    XCTAssertNoThrow(try SingletonLock(path: path))
}
```

- [x] **Шаг 2–5:** `open(path, O_CREAT|O_RDWR, 0o600)` + `flock(fd, LOCK_EX|LOCK_NB)`,
  `deinit` закрывает fd.

### Задача 2.6: Подметание сироты

**Файлы:**
- Create: `Sources/SCVPNHelperKit/StaleSweeper.swift`
- Test: `Tests/SCVPNHelperTests/StaleSweeperTests.swift`

**Interfaces:**
- Produces: `public func killStaleSingbox(_ env: HelperEnv) -> Bool`
- Produces: `public func stalePIDs(_ env: HelperEnv) -> [String]?` (nil — посмотреть не удалось)

Три свойства, каждое — отдельная проверка:

1. Ждём **факта** смерти, а не отправки сигнала: SIGTERM → ожидание →
   SIGKILL → ожидание. `pkill` возвращается сразу, и рапорт об успехе при живой
   сироте означал бы второй `sing-box` рядом с первым, дерущийся за default
   route.
2. «Не смог посмотреть» — это `false`, а не `true`. Неизвестность ничем не
   лучше живой сироты: решение по этому ответу принимается одно и то же.
3. Шаблон — целая командная строка, которую составляем только мы:
   `"\(binDir)/sing-box run -c \(runDir)/singbox.json"`, экранированная для
   `pgrep -f`.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_sweeps_stubborn_orphan_at_start() throws {
    let stand = try Stand(script: .stubborn)   // trap '' TERM
    try stand.spawnOrphan()
    XCTAssertTrue(killStaleSingbox(stand.env))
    XCTAssertTrue(stand.waitGone())
}

func test_reports_failure_when_it_cannot_look() {
    var env = HelperEnv.testing(tmp: tmp)
    env.procTool = { _ in nil }   // pgrep не отработал
    XCTAssertFalse(killStaleSingbox(env))
}
```

Поле `procTool` уже объявлено в `HelperEnv` (Задача 2.3) — здесь оно впервые
используется.

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 2.7: Стенд `Stand` для проверок демона

**Файлы:**
- Create: `Tests/SCVPNHelperTests/Support/Stand.swift`

Прямой перенос `_Stand` из `test_native.py:83`. Переизобретать не надо — это
готовый рецепт.

**Interfaces:**
- Produces:

```swift
final class Stand {
    enum Script { case normal, stubborn, crashing }
    let env: HelperEnv
    let xrayPath: String
    let socketPath: String

    init(script: Script) throws
    func serveHere() throws -> Stand          // accept-цикл в этом же процессе
    func connect(timeout: TimeInterval) throws -> Int32   // fd клиента
    func ask(_ fd: Int32, _ req: [String: Any]) throws -> [String: Any]
    func reply(_ fd: Int32) throws -> [String: Any]       // логи пропускаем
    func startTunnel() throws
    func singboxPIDs() -> [String]
    func waitUp(timeout: TimeInterval) -> Bool
    func waitGone(timeout: TimeInterval) -> Bool
    func spawnOrphan() throws
    func tearDown()
}
```

Три поддельных `sing-box`, дословно из Python:

```swift
// Метка готовности не для красоты: появление PID в pgrep ещё не значит, что
// оболочка успела выполнить `trap`. Ударив SIGTERM в этот зазор, «упрямый»
// sing-box умрёт как миленький, и проверка позеленеет, ничего не проверив.
// В метку кладём PID — так метка от прошлого запуска не сойдёт за готовность
// нового. Спим короткими интервалами: убитая оболочка не должна оставлять
// пятиминутного сироту, которого чистящий pkill не ловит.
static let normal   = "#!/bin/sh\necho $$ > {ready}\nwhile :; do sleep 1; done\n"
static let stubborn = "#!/bin/sh\ntrap '' TERM\necho $$ > {ready}\nwhile :; do sleep 1; done\n"
static let crashing = "#!/bin/sh\necho $$ > {ready}\nexit 7\n"
```

В `HelperEnv.testing` `stopGrace` и `sweepGrace` = 1 секунда, иначе проверки
ждут по семь секунд.

- [x] **Шаг 1: Написать `Stand`**
- [x] **Шаг 2: Написать дымовую проверку самого стенда**

```swift
func test_stand_starts_and_stops_fake_singbox() throws {
    let stand = try Stand(script: .normal).serveHere()
    defer { stand.tearDown() }
    try stand.startTunnel()
    XCTAssertTrue(stand.waitUp(timeout: 10))
}
```

- [x] **Шаг 3: Коммит**

### Задача 2.8: `Supervisor`

**Файлы:**
- Create: `Sources/SCVPNHelperKit/Supervisor.swift`
- Test: `Tests/SCVPNHelperTests/SupervisorTests.swift`

**Interfaces:**
- Produces:

```swift
public final class Supervisor {
    public init(env: HelperEnv)
    public var isRunning: Bool { get }
    public private(set) var owner: ClientHandle?
    public func start(_ params: SingboxParams, xrayPath: String,
                      onLog: @escaping (String) -> Void, owner: ClientHandle?) throws
    public func stop()
}
```

`ClientHandle` — ссылочный тип-обёртка над fd соединения; сравнивается по
`===`. Идентичность обязана быть ссылочной: сегодняшний Python сравнивает
объекты сокетов, а не номера дескрипторов, которые переиспользуются.

Четыре свойства, каждое — отдельная проверка:

1. **`owner` выставляется вплотную к запуску процесса, ДО первой записи в
   лог.** Зазор между ними обязан быть пуст: под launchd stderr — файл, запись
   в него может отказать (ENOSPC, EIO, сломанная труба), и в зазоре получилось
   бы `isRunning == true` при `owner == nil` — обработчик обрыва не признал бы
   в соединении владельца и не снял бы туннель.
2. **Ручку на процесс не отпускаем, пока смерть не подтверждена.** Если
   процесс не умер (непрерываемый сон для TUN-процесса правдоподобен), обнулять
   `proc` нельзя: `isRunning` соврал бы `false`, а следующий `start` поднял бы
   второй рядом с первым.
3. **Двух `sing-box` рядом быть не должно:** прежний снимается, осиротевший
   подметается, и если хоть один остался жив — не поднимается ничего.
4. **Колбэк логов передаётся аргументом, а не читается из поля:** после
   рестарта «sing-box завершился» от старого процесса ушло бы новому клиенту,
   как будто это про его туннель.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_sets_owner_before_the_only_fallible_step_after_launch() throws {
    let stand = try Stand(script: .normal)
    var env = stand.env
    var loggedAfterLaunch = false
    env.log = { _ in
        // Первая запись в лог после запуска процесса обязана видеть
        // уже выставленного владельца.
        if sup.isRunning { loggedAfterLaunch = true; XCTAssertNotNil(sup.owner) }
    }
    // ...
}

func test_keeps_handle_on_unkillable_singbox() throws {
    let stand = try Stand(script: .stubborn)
    let sup = Supervisor(env: stand.env)   // killGrace выставлен так, чтобы SIGKILL не успел
    try sup.start(params, xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil)
    sup.stop()
    XCTAssertTrue(sup.isRunning, "ручка отпущена на живом sing-box")
}

func test_refuses_to_start_over_a_stale_singbox() throws {
    let stand = try Stand(script: .stubborn)
    try stand.spawnOrphan()
    let sup = Supervisor(env: stand.env)
    XCTAssertThrowsError(try sup.start(params, xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil))
}
```

- [x] **Шаг 2: Запустить, убедиться, что падают**
- [x] **Шаг 3: Реализовать**

Ключевые механики Swift:

- Взаимоисключение: `NSRecursiveLock` (аналог `threading.RLock`) — `start` зовёт
  `stop` под тем же замком.
- Запуск: `Process` + `Pipe`, `standardError = standardOutput`,
  `standardInput = FileHandle.nullDevice`, `currentDirectoryURL = binDir`.
- Ожидание смерти с таймаутом: `waitUntilExit()` не умеет таймаут. Ставим
  `terminationHandler`, сигналящий `DispatchSemaphore`, и ждём
  `sem.wait(timeout: .now() + env.stopGrace)`.
- SIGKILL: `kill(process.processIdentifier, SIGKILL)` — у `Process` прямого
  метода нет.
- Чтение stdout построчно: отдельный `Thread` с `read(2)` в буфер и разбором по
  `\n`. Не `readabilityHandler`: он приходит на общую очередь и путает порядок
  при остановке.

- [x] **Шаг 4: Проверки зелёные**
- [x] **Шаг 5: Коммит**

### Задача 2.9: `Outbox`

**Файлы:**
- Create: `Sources/SCVPNHelperKit/Outbox.swift`
- Test: `Tests/SCVPNHelperTests/OutboxTests.swift`

**Interfaces:**
- Produces:

```swift
public final class Outbox {
    public init(fd: Int32, maxSize: Int = 256, log: @escaping (String) -> Void)
    public func start() -> Outbox
    public func send(_ obj: [String: Any])      // ответ — не выбрасывается
    public func sendLog(_ obj: [String: Any])   // лог — при тесноте выбрасывается
    public func close(timeout: TimeInterval)
    public var pending: Int { get }
    public private(set) var dropped: Int
}
```

Почему отдельный поток-писатель. Логи `sing-box` идут клиенту по тому же
соединению. Если писать прямо из читателя stdout и клиент перестанет читать,
`write` встанет, труба переполнится — и заблокируется сам `sing-box`. Получится,
что поведение клиентского сокета управляет ядром, поднимающим туннель.

Почему ответ не выбрасывается никогда. Клиент его ждёт, и потерянный ответ на
`start` оставляет приложение в убеждении, что туннеля нет, — пока весь трафик
системы идёт в туннель. Место для ответа освобождается за счёт самого старого
лога.

Почему у «не выбрасываем» есть предел. Если клиент не читает, а логов, за счёт
которых можно освободить место, в очереди нет, — расти дальше некуда: это память
root-процесса. На `maxSize * 4` кадрах разговор заканчивается: `shutdown(SHUT_RDWR)`,
не `close` — читатель получит EOF и уйдёт в свою уборку, а уборка и есть
dead-man's switch.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_drops_logs_instead_of_stalling() throws {
    let (out, readFD) = try makeOutbox(maxSize: 4)   // читателя нет
    for i in 0..<100 { out.sendLog(["log": "строка \(i)"]) }
    XCTAssertLessThanOrEqual(out.pending, 4)
    XCTAssertGreaterThan(out.dropped, 0)
}

func test_never_drops_the_reply() throws {
    let out = try makeOutbox(maxSize: 4)
    for i in 0..<4 { out.sendLog(["log": "\(i)"]) }
    out.send(["ok": true, "running": true])
    XCTAssertTrue(out.snapshot().contains { $0["ok"] != nil })
}

func test_outbox_has_a_ceiling_even_for_replies() throws {
    let out = try makeOutbox(maxSize: 4)          // hard limit = 16
    for _ in 0..<100 { out.send(["ok": false]) }
    XCTAssertLessThanOrEqual(out.pending, 16)
    XCTAssertTrue(out.isClosed, "переполнение обязано закрыть соединение")
}
```

- [x] **Шаг 2: Запустить, убедиться, что падают**
- [x] **Шаг 3: Реализовать**

Очередь — `Deque` не нужен, обычный `[[String: Any]]` со счётчиком логов
достаточен: без счётчика поиск «самого старого лога» обходил бы всю очередь
впустую на каждом кадре, когда логов в ней нет. Ожидание — `NSCondition`.

Сериализация: `JSONSerialization.data(withJSONObject:options: [])` — **без**
`.prettyPrinted`. Переводы строки внутри кадра сломали бы построчное
разграничение протокола. Затем `+ "\n"`.

Кривые байты: в тексте ошибки лежит то, что прислал клиент, вплоть до
одиночного суррогата. Строковые значения перед сериализацией пропускать через
`String(decoding: Array(s.utf8), as: UTF8.self)` — Swift `String` уже не
содержит невалидного UTF-8, так что этой проблемы Python здесь просто нет,
записать это в комментарий.

- [x] **Шаг 4: Проверки зелёные**
- [x] **Шаг 5: Коммит**

### Задача 2.10: Обработчик команд

**Файлы:**
- Create: `Sources/SCVPNHelperKit/CommandHandler.swift`
- Test: `Tests/SCVPNHelperTests/CommandHandlerTests.swift`

**Interfaces:**
- Produces:

```swift
public struct CommandContext {
    public let say: (String) -> Void
    public let conn: ClientHandle?
}
public func handleLine(_ line: String, _ ctx: CommandContext,
                       _ sup: Supervisor, _ env: HelperEnv) -> [String: Any]
```

Демон не имеет права падать от кривого ввода: клиент недоверенный, а падение
демона означает, что `sing-box` останется без надзора. Поэтому `handleLine`
**всегда** возвращает ответ.

Ответы дословно:

| Команда | Ответ |
|---|---|
| `start` | `["ok": true, "running": true]` |
| `stop` | `["ok": !sup.isRunning, "running": sup.isRunning]` |
| `status` | `["ok": true, "running": sup.isRunning, "singbox": FileManager.default.fileExists(atPath: binDir/sing-box)]` |
| `install_singbox` | `["ok": true, "version": tag]` |
| `remove_singbox` | `["ok": true, "removed": bool]` |
| неизвестная | `["ok": false, "error": "неизвестная команда: ..."]` |
| нечитаемый JSON | `["ok": false, "error": "не разобрал запрос: ..."]` |

Потолки размера (`_check_sizes`) проверяются **до** валидации: 200 000 имён —
это конфиг на десяток мегабайт, который root молча запишет на диск.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_stop_reply_tells_the_truth() throws {
    // sing-box имеет право пережить и SIGTERM, и SIGKILL. Ответить
    // «выключено», пока маршруты держатся, — это ровно та ложь про
    // состояние, от которой уходим.
    let stand = try Stand(script: .stubborn).serveHere()
    defer { stand.tearDown() }
    try stand.startTunnel()
    let fd = try stand.connect(timeout: 15)
    let reply = try stand.ask(fd, ["cmd": "stop"])
    XCTAssertEqual(reply["running"] as? Bool, true)
    XCTAssertEqual(reply["ok"] as? Bool, false)
}

func test_never_dies_on_deeply_nested_json() throws {
    // На глубоко вложенном JSON разборщик отдаёт ошибку, которая выходила
    // наружу мимо всех веток — а наружу это обрыв соединения, то есть
    // снятие туннеля одной кривой строкой.
    let deep = String(repeating: "[", count: 100_000)
    let reply = handleLine(deep, ctx, sup, env)
    XCTAssertEqual(reply["ok"] as? Bool, false)
}

func test_rejects_oversized_split_apps_list() {
    let apps = (0..<300).map { "app\($0)" }
    let reply = handleLine(json(["cmd": "start", "socks_port": 10808, "split_apps": apps]), ctx, sup, env)
    XCTAssertEqual(reply["ok"] as? Bool, false)
}

func test_rejects_foreign_xray_path() throws {
    let reply = handleLine(json(["cmd": "start", "socks_port": 10808, "xray_path": "/bin/sh"]), ctx, sup, env)
    XCTAssertEqual(reply["ok"] as? Bool, false)
}

func test_remove_singbox_refuses_while_tunnel_is_up() throws {
    // unlink уберёт имя, но работающий процесс останется держать маршруты,
    // и снять его будет уже нечем: по командной строке его ищет
    // killStaleSingbox, а бинарника на диске не будет.
    let stand = try Stand(script: .normal).serveHere()
    defer { stand.tearDown() }
    try stand.startTunnel()
    let fd = try stand.connect(timeout: 15)
    let reply = try stand.ask(fd, ["cmd": "remove_singbox"])
    XCTAssertEqual(reply["ok"] as? Bool, false)
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 2.11: Обслуживание клиента и dead-man's switch

**Файлы:**
- Create: `Sources/SCVPNHelperKit/ClientSession.swift`
- Test: `Tests/SCVPNHelperTests/DeadMansSwitchTests.swift`

**Interfaces:**
- Produces: `public func serveClient(fd: Int32, sup: Supervisor, env: HelperEnv)`

**Главное свойство всего проекта.** Обрыв соединения означает, что приложение
мертво, значит туннель надо снять, иначе система останется без интернета. Но
снимаем только **свой** туннель — тот, который подняло именно это соединение.
Клиентов больше одного бывает: `install_singbox` открывает отдельное соединение
на один запрос и закрывает его же — такое соединение не должно ронять чужой
активный туннель одним своим обрывом.

Условие снятия: `sup.isRunning && (sup.owner === conn || sup.owner == nil)`.
Ветка `owner == nil` — отказ в безопасную сторону: туннель без хозяина обязан
снять первый же отключившийся, а не остаться висеть навсегда.

Всё, что может бросить, — внутри `do`. Снаружи не должно оставаться ничего:
создание потока не всегда удаётся, и исключение уходило бы мимо уборки, то есть
мимо самого dead-man's switch.

Чтение с потолком: строка без перевода строки не должна расти в памяти
root-процесса бесконечно. Упёрлись в `1 MiB` — отвечаем «запрос длиннее
допустимого» и заканчиваем разговор.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_daemon_drops_tunnel_when_connection_closes() throws {
    let stand = try Stand(script: .normal).serveHere()
    defer { stand.tearDown() }
    let fd = try stand.connect(timeout: 15)
    _ = try stand.ask(fd, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
    XCTAssertTrue(stand.waitUp(timeout: 10))
    close(fd)
    XCTAssertTrue(stand.waitGone(timeout: 15), "туннель пережил обрыв клиента")
}

func test_daemon_leaves_foreign_tunnel_alone_on_disconnect() throws {
    let stand = try Stand(script: .normal).serveHere()
    defer { stand.tearDown() }
    let owner = try stand.connect(timeout: 15)
    _ = try stand.ask(owner, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
    XCTAssertTrue(stand.waitUp(timeout: 10))

    let bystander = try stand.connect(timeout: 15)
    _ = try stand.ask(bystander, ["cmd": "status"])
    close(bystander)

    Thread.sleep(forTimeInterval: 2)
    XCTAssertFalse(stand.singboxPIDs().isEmpty, "посторонний обрыв снёс чужой туннель")
}

func test_daemon_drops_ownerless_tunnel_on_any_disconnect() throws {
    // owner == nil не должен означать «висит навсегда».
}

func test_refuses_line_longer_than_the_ceiling() throws {
    let stand = try Stand(script: .normal).serveHere()
    defer { stand.tearDown() }
    let fd = try stand.connect(timeout: 15)
    let huge = String(repeating: "x", count: (1 << 20) + 10)
    write(fd, huge, huge.utf8.count)
    let reply = try stand.reply(fd)
    XCTAssertEqual(reply["ok"] as? Bool, false)
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 2.12: Сигналы и `main`

**Файлы:**
- Create: `Sources/SCVPNHelperKit/DaemonMain.swift`
- Create: `Sources/SCVPNHelper/main.swift`
- Test: `Tests/SCVPNHelperTests/SignalTests.swift`

**Interfaces:**
- Produces: `public func daemonMain(_ env: HelperEnv) -> Never`

Порядок в `main` обязан остаться прежним:

1. Не root — уйти с кодом 1.
2. **Замок захватывается до любой разрушительной операции.** Дальше идут снятие
   чужого `sing-box` и перехват сокета; `killStaleSingbox` бьёт по всей
   командной строке, не различая, чей это процесс, — второй демон снёс бы
   рабочий туннель первого.
3. Установить обработчики сигналов.
4. `killStaleSingbox`.
5. `unlink` сокета, `bind`, `chown root:admin`, `chmod 0660`, `listen(4)`.
6. Accept-цикл; на выходе — снять туннель и убрать сокет.

Сигналы: `SIGTERM`, `SIGINT`, `SIGHUP`, `SIGQUIT`. `SIGHUP` здесь не для
красоты — демона запускают и руками, и закрытое окно терминала не должно
оставлять root-овый `sing-box` с маршрутами.

**Повторные сигналы заглушаются первым делом.** Без этого второй `SIGTERM`,
пришедший пока идёт снятие, обрывал бы его на середине: демон уходил бы с кодом
0, а `sing-box` оставался бы жив с маршрутами.

Механика Swift, отличающаяся от Python:

```swift
// Обработчики сигналов в Swift писать нельзя: async-signal-safety не
// соблюсти, а снятие туннеля — это Process, замки и ожидания. Поэтому
// сигнал глушится на уровне POSIX, а работу делает DispatchSourceSignal
// на обычной очереди.
for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    src.setEventHandler {
        // Заглушить повторные: отменяем все источники разом, до снятия.
        sources.forEach { $0.cancel() }
        env.log("сигнал \(sig) — снимаю туннель и выхожу")
        sup.stop()
        try? FileManager.default.removeItem(atPath: env.socketPath)
        exit(0)
    }
    src.resume()
    sources.append(src)
}
// Accept-цикл живёт на отдельном потоке, главный отдан диспетчеру.
Thread { serveForever(srv, sup, env) }.start()
dispatchMain()
```

- [x] **Шаг 1: Падающие проверки** (демон отдельным процессом — иначе сигнал не
  послать)

```swift
func test_drops_tunnel_on_sigterm() throws {
    let stand = try Stand(script: .normal)
    let daemon = try stand.serveSubprocess()   // собранный SCVPNHelper с env из переменных окружения
    try stand.startTunnel()
    XCTAssertTrue(stand.waitUp(timeout: 10))
    kill(daemon.processIdentifier, SIGTERM)
    XCTAssertTrue(stand.waitGone(timeout: 20))
}

func test_drops_tunnel_on_repeated_sigterm() throws {
    // Второй сигнал во время снятия не должен обрывать снятие на середине.
    let stand = try Stand(script: .stubborn)
    let daemon = try stand.serveSubprocess()
    try stand.startTunnel()
    kill(daemon.processIdentifier, SIGTERM)
    Thread.sleep(forTimeInterval: 0.3)
    kill(daemon.processIdentifier, SIGTERM)
    XCTAssertTrue(stand.waitGone(timeout: 25))
}

func test_drops_tunnel_on_sighup() throws { /* то же с SIGHUP */ }

func test_refuses_second_instance() throws {
    let first = try stand.serveSubprocess()
    let second = try stand.serveSubprocess(expectFailure: true)
    XCTAssertEqual(second.terminationStatus, 1)
}

func test_checks_lock_before_sweeping() throws {
    // Второй демон не должен успеть подмести sing-box первого.
    let stand = try Stand(script: .normal)
    _ = try stand.serveSubprocess()
    try stand.startTunnel()
    let pids = stand.singboxPIDs()
    _ = try? stand.serveSubprocess(expectFailure: true)
    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(stand.singboxPIDs(), pids)
}
```

Для `serveSubprocess` демон читает `HelperEnv` из переменных окружения
(`SCVPN_HELPER_BIN_DIR`, `SCVPN_HELPER_RUN_DIR`, `SCVPN_HELPER_SOCKET`,
`SCVPN_HELPER_LOCK`, `SCVPN_HELPER_SKIP_BINARY_CHECK`), и **только** когда
`geteuid() != 0`. Под root переменные игнорируются: тестовая лазейка в
продакшене — это дыра.

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 2.13: Установка sing-box демоном

**Файлы:**
- Create: `Sources/SCVPNHelperKit/SingboxInstaller.swift`
- Test: `Tests/SCVPNHelperTests/SingboxInstallerTests.swift`

**Interfaces:**
- Produces:
  - `public func pickSingboxAsset(_ assets: [[String: Any]]) throws -> String`
  - `public func installSingbox(_ env: HelperEnv, say: (String) -> Void) throws -> String`
  - `public func removeSingbox(_ env: HelperEnv, sup: Supervisor, say: (String) -> Void) throws -> Bool`

Источник: `https://api.github.com/repos/SagerNet/sing-box/releases/latest`,
ассет, чьё имя оканчивается на `darwin-arm64.tar.gz`.

После распаковки — `chown root:wheel`, `chmod 0755`: иначе `checkBinary`
откажется его запускать, и правильно.

Распаковка — `/usr/bin/tar -xzf archive -C tmp`, затем поиск файла с именем
`sing-box` в дереве. Не `libarchive`, не свой разборщик.

Сеть в root-овом демоне: `URLSession.shared.dataTask` с
`DispatchSemaphore.wait(timeout: 30)` — Foundation в демоне без runloop работает,
но результат приходит на фоновой очереди, поэтому семафор обязателен. Если
Фаза 0 покажет, что `URLSession` в демоне не поднимается, запасной путь —
`/usr/bin/curl -fsSL`, он есть всегда; решение записать здесь.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_picks_darwin_arm64_asset() throws {
    let assets: [[String: Any]] = [
        ["name": "sing-box-linux-amd64.tar.gz", "browser_download_url": "нет"],
        ["name": "sing-box-1.9-darwin-arm64.tar.gz", "browser_download_url": "да"],
    ]
    XCTAssertEqual(try pickSingboxAsset(assets), "да")
}

func test_fails_loudly_when_no_darwin_asset() {
    XCTAssertThrowsError(try pickSingboxAsset([["name": "sing-box-windows.zip"]]))
}
```

Живую загрузку в модульных проверках не гоняем — это дымовая проверка Фазы 8.

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 2.14: Приёмка Фазы 2 — Python-приложение со Swift-демоном

**Файлы:**
- Create: `desktop/MacOS-Swift/Tools/install-helper-dev.sh`
- Modify: `desktop/MacOS/helper/install.py` (одна строка, см. раздел 0.3)

- [x] **Шаг 1: Скрипт ручной установки**

```bash
#!/bin/bash
# Ставит Swift-демона обычным LaunchDaemon — только на время Фазы 2, пока
# бандла с SMAppService ещё нет. В релизе демона ставит SMAppService.
set -euo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/arm64-apple-macosx/release/SCVPNHelper"
[ -x "$BIN" ] || { echo "сначала: swift build -c release --arch arm64"; exit 1; }
sudo install -o root -g wheel -m 755 "$BIN" /usr/local/libexec/scvpn-helper
sudo tee /Library/LaunchDaemons/com.scvpn.helper.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.scvpn.helper</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/scvpn-helper</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ExitTimeOut</key><integer>40</integer>
  <key>StandardErrorPath</key><string>/var/log/scvpn-helper.log</string>
  <key>StandardOutPath</key><string>/var/log/scvpn-helper.log</string>
</dict></plist>
PLIST
sudo launchctl bootout system/com.scvpn.helper 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.scvpn.helper.plist
```

- [ ] **Шаг 2: Прогнать Python-приложение против Swift-демона**

```bash
desktop/MacOS-Swift/Tools/install-helper-dev.sh
cd desktop/MacOS && SCVPN_ASSUME_HELPER=1 venv/bin/python run.py
```

Проверить в этом порядке: подключение в режиме TUN, `pgrep -f "sing-box run -c"`
непусто, `curl -s https://api.ipify.org` показывает адрес сервера, отключение,
`sing-box` исчез.

- [x] **Шаг 3: Прогнать ручную проверку dead-man's switch (шаги 1–4 из README)**

С поправкой: `pgrep -f "run.py --helper"` заменяется на
`pgrep -f scvpn-helper`.

- [x] **Шаг 4: Записать результат в этот файл**

**Результат (2026-08-15, macOS 26.6.1, Apple Silicon).** Демон поставлен
`Tools/install-helper-dev.sh`, туннель поднят Python-приложением, приложение
убито `kill -9`:

```
до:    APP=30332  HELPER=29847  sing-box=1
после:            HELPER=29847  sing-box=0
```

PID демона **не сменился** — значит туннель снял именно обработчик обрыва
соединения, а не подметание сироты новым демоном, поднятым launchd. Маршрут по
умолчанию вернулся на `en0` сам. **Инвариант 1 подтверждён живьём.**

Заодно вскрылась утечка в стенде проверок: поддельный `sing-box` спал
бесконечным циклом, и прогон, упавший **по сигналу** (а падает он по сигналу
ровно тогда, когда ловит настоящий баг — например тот SIGPIPE из Задачи 2.9), до
`tearDown` не доходил и оставлял процесс в системе насовсем. Один такой висел
сутки и попал в эту ручную проверку как «выживший туннель», из-за чего первый
счёт показал 2 и 1 вместо 1 и 0. Закрыто тремя способами сразу: цикл поддельного
`sing-box` ограничен двумя минутами, папки прогона сносятся по `atexit`, чужие
старше часа — сметаются при следующем прогоне.

**Критерий готовности Фазы 2:** Python-приложение работает со Swift-демоном без
единой правки, кроме одной строки из раздела 0.3, и dead-man's switch срабатывает.

> **Статус: Шаги 1, 3, 4, 5 сделаны. Шаг 2 — частично.**
>
> Демон поставлен и работает, Python-приложение подняло через него туннель на
> настоящем `sing-box`, dead-man's switch отработал (см. результат Шага 3).
> Не отмечено галочкой в Шаге 2 то, что не проверялось отдельным замером:
> `curl -s https://api.ipify.org` с адресом сервера. Сам факт рабочего туннеля
> при этом подтверждён — `sing-box` поднялся, маршруты держались, после снятия
> вернулись.
>
> **Первая установка упала** с `Bootstrap failed: 5: Input/output error`:
> `launchctl bootout` возвращается, не дожидаясь ухода службы, а у неё
> `ExitTimeOut 40` — `bootstrap` следом влетал в ещё живую регистрацию. Скрипт
> исправлен: ждёт исчезновения службы по `launchctl print`, снимает xattr,
> подписывает бинарник ad-hoc и проверяет исход по появлению сокета, а не по
> коду возврата `bootstrap`.

- [x] **Шаг 5: Коммит**

---

## Фаза 3. Установщик демона (1–2 дня)

> **Код закрыт 2026-08-15, живая приёмка — за Фазой 8.** 268 проверок зелёные.
>
> Что здесь проверяемо, а что нет. `SMAppService` требует настоящего бандла, и
> подсунуть ему статус в XCTest нельзя. Поэтому под проверками — истолкование
> исхода (`interpret`), отображение статуса в состояние, имя plist и весь текст
> снятия прежнего компонента, включая компиляцию AppleScript настоящим
> `osascript`. Сама регистрация проверена живьём в Фазе 0 на зонде с той же
> раскладкой бандла и той же ad-hoc подписью — четыре папки, четыре из четырёх
> раз `code=1` на первом вызове с переводом в `requiresApproval`.
>
> **Задача 3.3 вычеркнута** — см. её раздел.
>
> Отклонение: `HelperInstaller` и `LegacyHelper` живут в `SCVPNCore`, а не в
> `SCVPNApp`, по той же причине, что и весь платформенный слой Фазы 5 —
> executable-таргет не линкуется в проверки.

### Задача 3.1: Трёхсостоянийный контракт установки

**Файлы:**
- Create: `Sources/SCVPNApp/HelperInstaller.swift`
- Test: `Tests/SCVPNCoreTests/HelperInstallerTests.swift`

**Interfaces:**
- Produces:

```swift
public enum HelperState {
    case notInstalled        // .notFound — регистрации ещё не было
    case awaitingApproval    // .requiresApproval — ждём пользователя в настройках
    case ready               // .enabled
    case failed(String)      // .notRegistered после unregister, либо ошибка
}

public enum HelperInstaller {
    public static func state() -> HelperState
    public static func register() -> HelperState
    public static func unregister() throws
    public static func openSettings()
}
```

Сегодняшний `acquire_privilege() -> "ok" | "failed"` двоичный, а сценарий
трёхшаговый: попросили — пользователь ушёл в настройки — вернулись и проверили.
Это не деталь реализации, а видимое пользователю поведение.

**Первый `register()` штатно возвращает ошибку** `SMAppServiceErrorDomain
code=1` и переводит службу в `requiresApproval`. Это не сбой, а нормальный шаг
сценария (подтверждено экспериментом, спецификация раздел 4.3).

```swift
public static func register() -> HelperState {
    let svc = SMAppService.daemon(plistName: "com.scvpn.helper.plist")
    do {
        try svc.register()
    } catch {
        // code=1 «Operation not permitted» на первом вызове — это не отказ,
        // а перевод службы в requiresApproval: система plist нашла и приняла,
        // ей нужно согласие пользователя.
        if svc.status == .requiresApproval { return .awaitingApproval }
        return .failed(error.localizedDescription)
    }
    return svc.status == .enabled ? .ready : .awaitingApproval
}
```

- [x] **Шаг 1: Падающие проверки**

Тестируемо здесь немногое (`SMAppService` требует бандла), поэтому проверяем
отображение статуса в состояние — вынеся его в чистую функцию:

```swift
func test_status_mapping_covers_every_case() {
    XCTAssertEqual(HelperState(from: .notFound), .notInstalled)
    XCTAssertEqual(HelperState(from: .requiresApproval), .awaitingApproval)
    XCTAssertEqual(HelperState(from: .enabled), .ready)
}

func test_first_register_failure_with_requires_approval_is_not_a_failure() {
    // Регрессия на самое частое первое включение TUN: показать «не удалось»
    // там, где система ждёт согласия, значит отправить пользователя в тупик.
    XCTAssertEqual(interpret(registerError: dummyError(code: 1), status: .requiresApproval),
                   .awaitingApproval)
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 3.2: Слежение за статусом и обновление

**Файлы:**
- Modify: `Sources/SCVPNApp/HelperInstaller.swift`

**Что Фаза 0 уже решила за эту задачу:**

- Периодической сверки `status` **не нужно**: регистрация переживает
  перезагрузку (Задача 0.1), служба поднимается сама.
- `helper_version` и безусловная перерегистрация **нужны**: plist из
  подменённого бандла не перечитывается (0.3), а сама служба после подмены
  перестаёт подниматься (0.2).

- [x] **Шаг 1:** Добавить `waitUntilReady(timeout:)` — опрос `svc.status` раз в
  секунду, пока не `.enabled` или не истечёт таймаут.
- [x] **Шаг 2:** Завести `helper_version` в `settings.json` и при несовпадении
  с версией текущей сборки звать `unregister()`, дождаться ухода службы, затем
  `register()`. Это не оптимизация, а условие корректности: `ExitTimeOut = 40` —
  расчёт худшего случая снятия, и служба, живущая со старым значением, получает
  SIGKILL на середине снятия, оставляя `sing-box` сиротой с маршрутами.
- [x] **Шаг 3:** Коммит.

### Задача 3.3: Проверка расположения бандла — ВЫЧЕРКНУТА

**Файлы:** нет.

Выполнялась только если Фаза 0 (Задачи 0.5, 0.6) подтвердит ограничение.
**Не подтвердила ни то, ни другое.**

- `register()` доходит до `requiresApproval`, а после согласия служба
  поднимается, из всех четырёх проверенных мест: `/Applications`,
  `~/Applications`, `/Users/Shared`, `~/Downloads` (0.5).
- Из `~/Downloads` демон поднялся от root и отметился в журнале абсолютным
  путём внутрь бандла (0.6). TCC не помешал.

Баг, который Задача −1.1 закрывает в Python-версии, был свойством **способа
запуска**, а не папки: там launchd вёл абсолютный путь к интерпретатору внутрь
пользовательской папки, и `open()` на `pyvenv.cfg` получал EPERM. Под
`SMAppService` путь — `BundleProgram` относительно зарегистрированного бандла,
и доступ система выдаёт вместе с регистрацией.

Отказывать не за что, поэтому проверки нет. Записано здесь, чтобы её не завели
обратно «на всякий случай».

### Задача 3.4: Снятие старого Python-демона при обновлении

**Файлы:**
- Modify: `Sources/SCVPNApp/HelperInstaller.swift`

Пользователь, у которого стоит Python-версия, получит на диске
`/Library/LaunchDaemons/com.scvpn.helper.plist`, указывающий в никуда, и launchd
с `KeepAlive` будет вечно перезапускать несуществующий путь.

- [x] **Шаг 1:** При первом запуске Swift-версии проверить существование этого
  файла.
- [x] **Шаг 2:** Если он есть — показать диалог «Найден старый системный
  компонент, его нужно снять» и выполнить через один `osascript` с правами
  администратора:

```bash
launchctl bootout system/com.scvpn.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.scvpn.helper.plist
rm -rf "/Library/Application Support/SCVPN/code"
```

Папку `/Library/Application Support/SCVPN/bin` **не трогаем**: там лежит
`sing-box`, который новому демону пригодится.

- [x] **Шаг 3:** Коммит.

---

## Фаза 4. Ядро логики приложения (1–1.5 недели)

Всё без UI, всё под XCTest.

### Задача 4.1: `JSONValue` и `Store`

**Файлы:**
- Create: `Sources/SCVPNCore/Storage/JSONValue.swift`
- Create: `Sources/SCVPNCore/Storage/Store.swift`
- Test: `Tests/SCVPNCoreTests/StoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum JSONValue: Codable { case string(String), int(Int), double(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null }`
  - `public func loadSettings() -> [String: JSONValue]`
  - `public func saveSettings(_ s: [String: JSONValue])`
  - `public let defaultSettings: [String: JSONValue]`

**Настройки — словарь, а не структура.** Это не лень, а требование: Python
делает `settings = dict(DEFAULT_SETTINGS); settings.update(loaded)` и сохраняет
весь словарь целиком. Ключ `hwid` пишется в `settings.json` модулем `hwid.py` и
в `DEFAULT_SETTINGS` его нет — структура с фиксированными полями потеряла бы
его при первом же сохранении, и пользователь занял бы новый слот в лимите
устройств панели.

`defaultSettings` дословно из `storage.py:103`:

```
socks_port: 10808, http_port: 10809, route_mode: "global", block_ads: false,
system_proxy: true, selected_key: "", tls_fingerprint: "auto",
vpn_mode: "proxy", split_mode: "off", split_apps: [], tun_stack: "gvisor"
```

- [x] **Шаг 1: Падающие проверки**

```swift
func test_unknown_settings_keys_survive_a_round_trip() throws {
    try write(settingsJSON: #"{"hwid": "ab-cd", "новый_ключ": 42}"#)
    var s = loadSettings()
    s["block_ads"] = .bool(true)
    saveSettings(s)
    let again = loadSettings()
    XCTAssertEqual(again["hwid"], .string("ab-cd"))
    XCTAssertEqual(again["новый_ключ"], .int(42))
}

func test_missing_file_yields_defaults() {
    XCTAssertEqual(loadSettings()["tun_stack"], .string("gvisor"))
}

func test_corrupted_file_yields_defaults_without_crashing() throws {
    try write(settingsJSON: "{это не json")
    XCTAssertEqual(loadSettings()["socks_port"], .int(10808))
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 4.2: `Server` и `Profiles`

**Файлы:**
- Create: `Sources/SCVPNCore/Models/Server.swift`
- Create: `Sources/SCVPNCore/Models/Subscription.swift`
- Create: `Sources/SCVPNCore/Models/SubscriptionInfo.swift`
- Create: `Sources/SCVPNCore/Storage/Profiles.swift`
- Test: `Tests/SCVPNCoreTests/ModelTests.swift`

**Interfaces:**
- Produces: `Server` с полями и ключами дословно из `models.py:16`:
  `protocol, name, address, port, uuid, password, method, alter_id, network,
  security, flow, sni, fingerprint, alpn, public_key, short_id, spider_x,
  allow_insecure, ws_path, ws_host, grpc_service, extra`.
- Produces: `Server.key() -> String`, `Server.title -> String`,
  `Server.toOutbound(tag:) -> [String: Any]`.
- Produces: `Subscription`, `SubscriptionInfo` с производными
  (`used`, `unlimited`, `usedRatio`, `expiresAt`, `daysLeft`,
  `deviceLimitReached`), `Profiles.allServers()`.

`protocol` — зарезервированное слово Swift, поле называется `proto` с
`CodingKeys` на `"protocol"`. Записать это комментарием: смена ключа сломала бы
чтение существующих `profiles.json`.

`extra` — `[String: JSONValue]`.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_reads_a_real_profiles_json_without_losing_fields() throws {
    let raw = try Data(contentsOf: fixture("profiles-real.json"))
    let p = try JSONDecoder().decode(Profiles.self, from: raw)
    let back = try JSONEncoder().encode(p)
    let a = try JSONSerialization.jsonObject(with: raw) as! NSDictionary
    let b = try JSONSerialization.jsonObject(with: back) as! NSDictionary
    XCTAssertEqual(a, b)
}

func test_key_matches_python_format() {
    let s = Server(proto: "vless", address: "a.b", port: 443, uuid: "u",
                   network: "tcp", security: "reality")
    XCTAssertEqual(s.key(), "vless://u@a.b:443/tcp/reality")
}

func test_reality_outbound_defaults_fingerprint_to_chrome() {
    var s = Server(proto: "vless", security: "reality")
    s.fingerprint = ""
    let out = s.toOutbound(tag: "proxy")
    let reality = (out["streamSettings"] as! [String: Any])["realitySettings"] as! [String: Any]
    XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
}

func test_unknown_protocol_throws() {
    XCTAssertThrowsError(try Server(proto: "неизвестный").toOutbound(tag: "proxy"))
}
```

Фикстура `profiles-real.json` — копия настоящего файла пользователя с
затёртыми UUID и паролями. Положить в `Tests/Fixtures/`.

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 4.3: Парсеры ссылок

**Файлы:**
- Create: `Sources/SCVPNCore/Parsing/LinkParser.swift`
- Create: `Sources/SCVPNCore/Parsing/Base64.swift`
- Test: `Tests/SCVPNCoreTests/LinkParserTests.swift`

**Interfaces:**
- Produces: `public func parseLink(_ link: String) -> Server?`
- Produces: `public func parseSubscriptionText(_ text: String) -> [Server]`
- Produces: `public func b64decode(_ s: String) throws -> Data` (с добиванием
  паддинга и url-safe алфавитом)

Четыре схемы: `vless://`, `vmess://` (base64-JSON), `trojan://`, `ss://` (две
формы — целиком base64 и `method:password` base64 отдельно).

- [x] **Шаг 1: Падающие проверки**

Набор ссылок берётся из `desktop/MacOS/smoke_test.py` — там уже собраны формы,
которые встречались живьём. Скопировать их в фикстуру и покрыть каждую.

```swift
func test_parses_every_link_form_from_the_smoke_test() throws {
    for (link, expected) in linkFixtures {
        let s = try XCTUnwrap(parseLink(link), link)
        XCTAssertEqual(s.proto, expected.proto, link)
        XCTAssertEqual(s.address, expected.address, link)
        XCTAssertEqual(s.port, expected.port, link)
    }
}

func test_returns_nil_on_garbage_instead_of_crashing() {
    XCTAssertNil(parseLink("не ссылка"))
    XCTAssertNil(parseLink("vless://"))
    XCTAssertNil(parseLink("vmess://%%%"))
}

func test_base64_without_padding_decodes() throws {
    XCTAssertEqual(String(decoding: try b64decode("YWJj"), as: UTF8.self), "abc")
    XCTAssertEqual(String(decoding: try b64decode("YWJjZA"), as: UTF8.self), "abcd")
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 4.4: Подписки

**Файлы:**
- Create: `Sources/SCVPNCore/Parsing/SubscriptionFetcher.swift`
- Test: `Tests/SCVPNCoreTests/SubscriptionTests.swift`

**Interfaces:**
- Produces: `public func fetchSubscription(url:userAgent:timeout:) async throws -> (servers: [Server], info: SubscriptionInfo)`
- Produces: `public func subscriptionInfo(from headers: [AnyHashable: Any]) -> SubscriptionInfo`

`DEFAULT_USER_AGENT = "v2rayNG/1.9.5"` — не менять, панели по нему отдают
разное.

Отдельно: **заглушка панели**. `_raise_if_panel_stub` в `subscription.py:72`
ловит ответ `vless://0000...@0.0.0.0:1#App not supported`, который панель с
привязкой к устройствам отдаёт клиенту без `x-hwid`. Перенести дословно — без
этого пользователь получит «подписка пустая» вместо внятного объяснения.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_recognizes_panel_stub_and_explains_it() {
    let stub = [Server(proto: "vless", address: "0.0.0.0", port: 1, name: "App not supported")]
    XCTAssertThrowsError(try raiseIfPanelStub(stub, headers: [:]))
}

func test_parses_subscription_userinfo_header() {
    let info = subscriptionInfo(from: [
        "subscription-userinfo": "upload=0; download=123; total=0; expire=1788405825",
        "profile-update-interval": "24",
        "content-disposition": "attachment; filename=F_Semin_key-1",
    ])
    XCTAssertEqual(info.download, 123)
    XCTAssertTrue(info.unlimited)
    XCTAssertEqual(info.updateInterval, 24)
    XCTAssertEqual(info.account, "F_Semin_key-1")
}

func test_decodes_base64_profile_title() {
    let info = subscriptionInfo(from: ["profile-title": "base64:0J/RgNC+0YTQuNC70Yw="])
    XCTAssertEqual(info.title, "Профиль")
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 4.5: Конфиг Xray

**Файлы:**
- Create: `Sources/SCVPNCore/XrayConfig/XrayConfigBuilder.swift`
- Test: `Tests/SCVPNCoreTests/XrayConfigTests.swift`

Прямой перенос `xray_config.py`. Порядок правил маршрутизации значим:
блокировка рекламы → приватные адреса и домены → обход РФ → всё остальное в
прокси.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_private_addresses_always_go_direct() { }
func test_bypass_ru_adds_ru_rules_before_the_catch_all() { }
func test_block_ads_rule_comes_first() { }
func test_bypass_ru_puts_yandex_dns_first() { }
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 4.6: `XrayRunner`, `TCPPing`, `HWID`

**Файлы:**
- Create: `Sources/SCVPNCore/XrayRunner.swift`
- Create: `Sources/SCVPNCore/TCPPing.swift`
- Create: `Sources/SCVPNCore/HWID.swift`
- Create: `Sources/SCVPNCore/Paths.swift`
- Test: `Tests/SCVPNCoreTests/RunnerTests.swift`, `HWIDTests.swift`

**Interfaces:**
- Produces: `public final class XrayRunner { init(onLog:onState:); var isRunning: Bool; func start(_ config: [String: Any]) throws; func stop() }`
- Produces: `public func findFreePort(preferred: Int) -> Int`
- Produces: `public func tcpPing(host: String, port: Int, timeout: TimeInterval) -> Int?`
- Produces: `public func deviceID() -> String`, `public func deviceHeaders() -> [String: String]`

`XrayRunner` пишет PID в `data/xray.pid` — если приложение закроется аварийно,
ядро останется работать само по себе, и следующий запуск должен его найти и
снять.

`HWID`: `IOPlatformUUID` через IOKit напрямую, без `ioreg`:

```swift
let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                          IOServiceMatching("IOPlatformExpertDevice"))
defer { IOObjectRelease(service) }
let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
                                           kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? String
```

Соль `"scvpn-hwid-v1"` и формат UUID из хеша — дословно. Смена любого из них
означает новый слот в лимите устройств у каждого пользователя.

`tcpPing`: неблокирующий `connect` + `poll()`. Именно так работает
`socket.settimeout()` в Python — мерить надо время до установки соединения, а
не до таймаута ОС.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_hwid_is_stable_across_calls() {
    XCTAssertEqual(deviceID(), deviceID())
}

func test_hwid_is_persisted_in_settings() {
    let id = deviceID()
    XCTAssertEqual(loadSettings()["hwid"], .string(id))
}

func test_hwid_format_is_a_uuid() {
    XCTAssertNotNil(UUID(uuidString: deviceID()))
}

func test_find_free_port_skips_a_busy_one() throws {
    let taken = try listen(on: 20000)
    XCTAssertNotEqual(findFreePort(preferred: 20000), 20000)
    close(taken)
}

func test_tcp_ping_returns_nil_for_a_closed_port() {
    XCTAssertNil(tcpPing(host: "127.0.0.1", port: 1, timeout: 1))
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 4.7: Подбор TLS-отпечатка

**Файлы:**
- Create: `Sources/SCVPNCore/FingerprintProbe.swift`
- Test: `Tests/SCVPNCoreTests/FingerprintTests.swift`

**Interfaces:**
- Produces: `public func candidateFingerprints(_ s: Server, override: String) -> [String]`
- Produces: `public func findWorkingFingerprint(...) async -> String`

Порядок `FALLBACK_FPS = ["firefox", "chrome", "safari", "edge", "ios",
"randomized"]` не менять: сперва те, что не шлют пост-квантовых кривых.

**Риск.** Проба ходит на `https://api.ipify.org` через локальный HTTP-прокси.
В Python это `requests` с `proxies=`. В Swift — `URLSessionConfiguration
.connectionProxyDictionary` с ключами `HTTPEnable/HTTPProxy/HTTPPort` и
`HTTPSEnable/HTTPSProxy/HTTPSPort`. На связке HTTPS-через-CFNetwork-прокси
известны странности. Порядок действий:

- [x] **Шаг 1:** Написать спайк на `URLSession` и проверить живьём против
  поднятого `xray`.
- [x] **Шаг 2:** Если не работает — использовать `Process` с
  `/usr/bin/curl -s -m 6 -x http://127.0.0.1:PORT https://api.ipify.org`.
  `curl` есть в macOS всегда. Записать выбор здесь.
- [x] **Шаг 3:** Проверки на чистую часть:

```swift
func test_explicit_override_skips_probing() {
    XCTAssertEqual(candidateFingerprints(Server(), override: "safari"), ["safari"])
}

func test_server_fingerprint_goes_first_but_randomized_does_not() {
    var s = Server(); s.fingerprint = "randomized"
    XCTAssertEqual(candidateFingerprints(s, override: "auto").first, "firefox")
}
```

- [x] **Шаг 4–5:** зелёные, коммит.

### Задача 4.8: Приёмка Фазы 4

**Результат (2026-08-15).** Пройдена, но не разовой командой из плана, а
постоянными проверками — `RealProfilesTests`. Формат на диске заморожен, и
потерянное поле обнаружилось бы не сегодня, а когда пользователь не сможет
подключиться.

Настоящий `desktop/MacOS/data/profiles.json` (1 подписка, 11 серверов) читается
Swift-моделями, пишется обратно и совпадает с исходником при сравнении
разобранных объектов — то же, что `diff <(jq -S .) <(jq -S .)`, только внутри
прогона и на каждом запуске. Каждый из 11 серверов собирает конфиг Xray и даёт
непустой `key()`. Если файла нет, проверки помечаются `XCTSkip`, а не зеленеют
молча.

**Отклонение от плана по Шагу 1.** Набор ссылок предлагалось взять из
`desktop/MacOS/smoke_test.py`. Литералов ссылок там нет — скрипт читает
настоящий `profiles.json`. Фикстура собрана по формам, которые разбирает
`shared/subscription.py`, включая те, ради которых там стоят отдельные ветки:
русское имя в `#fragment`, проценты внутри `path`, IPv6 в скобках,
неэкранированная `@` в пароле trojan, обе законные формы `ss://`.

- [x] **Шаг 1:** Прогнать парсинг на том же наборе ссылок, что и
  `smoke_test.py`.
- [x] **Шаг 2:** Прочитать существующий `profiles.json` пользователя, записать
  обратно, сравнить `diff <(jq -S . before.json) <(jq -S . after.json)` — должно
  быть пусто.
- [x] **Шаг 3:** Коммит.

---

## Фаза 5. Платформенный слой приложения (3–5 дней)

> **Закрыта 2026-08-15.** 254 проверки зелёные. Отклонения от плана, все
> осознанные:
>
> - **Всё живёт в `SCVPNCore`, а не в `SCVPNApp`.** План размещал `SystemProxy`,
>   `CoreDownloader`, `RunningApps` и `HelperClient` в приложении, а проверки —
>   в `SCVPNCoreTests`. Так не собирается: `SCVPNApp` — executable-таргет, и
>   тестовый таргет его не линкует (та же причина, по которой заведён
>   `SCVPNHelperKit`). Ни один из четырёх типов ничего от AppKit не хочет,
>   поэтому место им в `SCVPNCore`.
> - **Проверки `Tun` — в `SCVPNHelperTests`.** Им нужен стенд `Stand`, а он
>   часть того таргета. Копия стенда во втором таргете разошлась бы с первой.
> - **`networksetup` подменяется полем `SystemProxy.runNetworksetup`.** Иначе
>   каждая из семнадцати проверок правила бы сеть машины, на которой идёт
>   прогон. Живьём остался один круг откат-восстановление —
>   `SystemProxyLiveTests`, см. ниже.
> - **`RunningApps` через `NSWorkspace`, а не разбор `ps -axo comm=`.** Тот же
>   ответ без запуска процесса, приложения уже отделены от демонов.

### Задача 5.1: `SystemProxy`

**Файлы:**
- Create: `Sources/SCVPNApp/SystemProxy.swift`
- Test: `Tests/SCVPNCoreTests/SystemProxyTests.swift` (логика вынесена в Core)

**Interfaces:**
- Produces: `public func hardwareServices() -> [String]`
- Produces: `public func enableSystemProxy(host: String, port: Int) throws`
- Produces: `public func disableSystemProxy()`
- Produces: `public func systemProxyIsOurs() -> Bool`

Три свойства, каждое — отдельная проверка:

1. **Без снимка не делаем ничего.** Снимок — это и запись «прокси ставили мы»,
   и единственный источник знания, к чему возвращать. Без него прежняя версия
   стирала настройку чужого клиента (на машине обычно живут Happ, Tailscale и
   подобные, все на `127.0.0.1`).
2. **Старый формат снимка (без блока `proxy`) обязан читаться.** Там лежит
   настоящее прежнее состояние сети; потерять эту запись — потерять настройки,
   ради которых снимок и заводился. В старом формате сверяемся по хосту, в
   новом — по хосту и порту.
3. **`-set*proxy` сам взводит `Enabled`** даже при пустом `Server`, поэтому
   нужное состояние выставляется отдельной командой `-set*proxystate` следом.

Регулярные выражения переносятся дословно, включая правило «пустой список
обхода `networksetup` описывает человеческой фразой с пробелами, а домены
пробелов не содержат».

- [x] **Шаг 1: Падающие проверки**

**Живая проверка получила предохранитель.** `SystemProxyLiveTests` правит
настоящий прокси на этой машине, как план и требовал, но пропускается, если на
машине **уже** стоит чужой прокси: рядом живут Happ и подобные, и падение
посреди проверки оставило бы затёртой их настройку. План этого случая не
предусматривал; разница между «проверка упала» и «у пользователя пропал
интернет» слишком велика. Прогон 2026-08-15 прошёл живьём: настоящий
`networksetup` принял аргументы, откат вернул состояние сети.

```swift
func test_snapshot_round_trip_restores_state() throws {
    // Реально включает и выключает системный прокси на этой машине —
    // так и задумано: молча сломанный откат оставляет без интернета,
    // и ловить это надо здесь.
    let before = hardwareServices().map { readState($0) }
    try enableSystemProxy(host: "127.0.0.1", port: 10809)
    disableSystemProxy()
    let after = hardwareServices().map { readState($0) }
    XCTAssertEqual(before, after)
}

func test_disable_leaves_a_foreign_proxy_alone() throws {
    removeSnapshot()
    setForeignProxy(host: "127.0.0.1", port: 7890)
    disableSystemProxy()
    XCTAssertTrue(foreignProxyStillThere())
}

func test_is_enabled_wants_our_own_port_not_just_localhost() throws {
    writeSnapshot(host: "127.0.0.1", port: 10809)
    setForeignProxy(host: "127.0.0.1", port: 7890)
    XCTAssertFalse(systemProxyIsOurs())
}

func test_is_enabled_recognizes_old_snapshot_format() throws {
    writeRawSnapshot(#"{"Wi-Fi": {"web": {"Enabled": "No"}}}"#)   // без блока proxy
    setForeignProxy(host: "127.0.0.1", port: 7890)
    XCTAssertTrue(systemProxyIsOurs())   // старый формат сверяет только хост
}
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 5.2: `CoreDownloader`

**Файлы:**
- Create: `Sources/SCVPNApp/CoreDownloader.swift`
- Test: `Tests/SCVPNCoreTests/DownloaderTests.swift`

**Interfaces:**
- Produces: `public func latestXrayAsset() async throws -> (tag: String, url: URL)`
- Produces: `public func downloadCore(progress:onBytes:) async throws -> String`
- Produces: `public func corePresent() -> Bool`, `public func tunPresent() -> Bool`

`ASSET_NAME = "Xray-macos-arm64-v8a.zip"`, из архива берутся ровно три файла:
`xray`, `geoip.dat`, `geosite.dat`. Из zip права не переносятся — бит исполнения
ставим сами.

Распаковка: `/usr/bin/unzip -o -j archive.zip xray geoip.dat geosite.dat -d bin`.

Карантин: после распаковки безусловно
`removexattr(path, "com.apple.quarantine", 0)`, `ENOATTR` игнорируется. Одна
строка, снимающая целый класс проблем (см. Задачу 0.8).

`tunPresent()` — **только** `singboxExe().exists()`. Про демона здесь не
спрашиваем намеренно: раньше `tun_present` включал в себя «демон установлен», и
на чистой машине из этой вложенности получался неснимаемый круг — префлайт
требовал компоненты раньше прав, а компоненты кладёт демон, которого ставила
только ветка прав за уже непроходимым гейтом.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_picks_the_arm64_asset() { }
func test_fails_when_asset_missing_from_release() { }
func test_unpack_sets_exec_bit_on_xray() throws { }
func test_unpack_strips_quarantine() throws { }
func test_tun_present_does_not_ask_about_the_helper() { }
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 5.3: `RunningApps`

**Файлы:**
- Create: `Sources/SCVPNApp/RunningApps.swift`
- Test: `Tests/SCVPNCoreTests/RunningAppsTests.swift`

**Interfaces:**
- Produces: `public func runningApps() -> [String]`
- Produces: `public func normalizeAppName(_ s: String) -> String`

`NSWorkspace.shared.runningApplications`, имя — `executableURL?.lastPathComponent`
(`Telegram`, а не `Telegram.app`: `sing-box` сопоставляет соединение с процессом
по имени исполняемого файла внутри бандла). Фильтр по префиксам `/Applications/`,
`/System/Applications/`, `~/Applications/`; `.appex` отбрасываем.

- [x] **Шаг 1: Падающие проверки**

```swift
func test_normalize_strips_dot_app_and_path() {
    XCTAssertEqual(normalizeAppName("/Applications/Telegram.app"), "Telegram")
    XCTAssertEqual(normalizeAppName("  Safari.app/  "), "Safari")
}

func test_running_apps_contains_finder() {
    XCTAssertTrue(runningApps().contains("Finder"))
}
```

**Проверка про Finder неверна и заменена.** Finder лежит в
`/System/Library/CoreServices`, а не в `/System/Applications`, и под фильтр
префиксов не попадает — ни здесь, ни в Python-версии, у которой тот же набор.
Вместо неё проверяется то, что действительно верно и что проверял Python: список
не пуст, имена без `/` и без `.app`, расширений в нём нет.

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

### Задача 5.4: `HelperClient`

**Файлы:**
- Create: `Sources/SCVPNApp/HelperClient.swift`
- Test: `Tests/SCVPNCoreTests/HelperClientTests.swift`

**Interfaces:**
- Produces:

```swift
public actor HelperConnection {
    public init(socketPath: String, onLog: @escaping (String) -> Void) throws
    public func request(_ payload: [String: Any], timeout: TimeInterval) throws -> [String: Any]
    public func send(_ payload: [String: Any]) throws
    public func stream(onFrame: @escaping ([String: Any]) -> Void)
    public func close()
}

public final class Tun {
    public init(onLog: @escaping (String) -> Void, onState: @escaping (Bool) -> Void)
    public var isRunning: Bool { get }
    public func start(server: Server, socksPort: Int, splitMode: SplitMode, splitApps: [String]) throws
    public func stop() -> Bool          // false — демон честно ответил, что туннель не снят
}
```

**Дисциплина «единственный читатель сокета» — не стиль, а починенные баги.**
До `start()` сокет читает вызывающий поток, после — поток логов. Два читателя
на одном сокете отдавали бы строки кому попало, и ответ на `stop` терялся бы,
подвешивая `stop()` до таймаута.

Один `actor` владеет сокетом, читает его в единственном месте и раздаёт кадры
двум потребителям — потоку логов и ожидающему ответа на `stop`. **Не
«улучшать» на ходу.**

`stop()` возвращает `Bool` по правдивому ответу демона: `sing-box` имеет право
пережить и SIGTERM, и SIGKILL, и тогда utun поднят, маршруты держатся, а
«Отключено» на экране — ровно та ложь про состояние, ради ухода от которой
правду и добывали.

`_read_logs` следит за строкой `"sing-box завершился"`: демон снял `sing-box`
сам, а соединение при этом **не** рвёт — приложение живо, просто без туннеля.
Без этой проверки `Tun` продолжал бы считать себя подключённым.

Сверка «моё ли это соединение» — по **идентичности объекта**, а не по флагу
«идёт остановка»: флаг пришлось бы снимать, и поток, просыпающийся от закрытия
не мгновенно, успел бы увидеть его снятым.

- [x] **Шаг 1: Падающие проверки** (против `Stand` из Задачи 2.7)

```swift
func test_tun_stop_reports_tunnel_that_survived_the_stop() throws {
    let stand = try Stand(script: .stubborn).serveHere()
    defer { stand.tearDown() }
    let tun = Tun(socketPath: stand.socketPath, onLog: { _ in }, onState: { _ in })
    try tun.start(...)
    XCTAssertFalse(tun.stop(), "stop соврал про снятый туннель")
    XCTAssertTrue(tun.isRunning)
}

func test_tun_connection_loss_drops_tunnel_without_stop() throws { }

func test_disconnect_does_not_report_idle_when_tunnel_survived() throws { }

func test_second_start_closes_the_previous_connection() throws {
    // Прошлая сессия могла не закрыть своё соединение сама: on_state(false)
    // уже пришёл (sing-box умер сам), а стоп не позвали. Без явного
    // закрытия второй start завёл бы ещё один сокет и поток поверх висящего.
}

func test_stop_reply_is_not_eaten_by_the_log_reader() throws { }
```

- [x] **Шаг 2–5:** запустить, реализовать, зелёные, коммит.

---

## Фаза 6. Интерфейс (1.5–2 недели)

Переписывается заново, но поведение и тексты — те же. Ориентир по составу —
таблица меню в `desktop/MacOS/README.md`.

> **Оформление окна перенесено с последней Python-версии, а не с
> закоммиченной ранее.** В рабочем дереве лежала незавершённая переделка
> заголовка; она разложена на отдельные коммиты (`feat(ui): оформление окна
> macOS`, `feat(ui): полоска загрузки…`) и уже потом перенесена сюда. Что
> именно приехало: своя шапка вместо системной полосы, опущенный светофор,
> перетаскивание за шапку, перерисованные значки диалогов.

### Задача 6.1: Тема и брендмарк

**Файлы:**
- Create: `Sources/SCVPNApp/Theme.swift`
- Create: `Sources/SCVPNApp/Views/Brandmark.swift`
- Test: `Tests/SCVPNCoreTests/ThemeTests.swift`

Палитра дословно из `theme.py:19`: `BG #000000`, `SURFACE #0D0D0D`,
`SURFACE_HI #1C1C1C`, `STROKE #333333`, `TEXT #FFFFFF`, `DIM #8C8C8C`,
`MUTED #5A5A5A`, `ACCENT #FFFFFF`. Шрифты: `-apple-system` / `SF Pro Text`,
моно — `Menlo`.

**Состояния различаются формой, а не только цветом** (толщина кольца, пунктир)
— это осознанное решение доступности, см. docstring `theme.py`. Не заменять на
цветовую индикацию.

`Brandmark` — геометрия один в один из `brandmark.py::mark_path`, на SwiftUI
`Path`.

- [ ] **Шаг 1:** Проверка, что палитра совпадает с
  `android/app/src/main/res/values/colors.xml` — сегодня она дублируется вручную
  и расхождение никем не проверяется (спецификация, раздел 11).

```swift
func test_palette_matches_android_colors_xml() throws {
    let xml = try String(contentsOf: androidColorsURL)
    XCTAssertTrue(xml.contains("#0D0D0D"), "палитра разошлась с Android")
}
```

- [x] **Шаг 2–5:** реализовать, зелёные, коммит.

**Результат.** Палитра сверяется с `colors.xml` и по значениям, и по именам, и
вдобавок проверяется на отсутствие цвета вовсе (R=G=B): появление цветного
значения означало бы, что состояние начали показывать оттенком, а это ломает и
доступность, и Android заодно.

**Знак «S» вышел зеркальным с первого раза** — «2» вместо «S». Причина в углах:
`brandmark.py` записывает дуги уже перевёрнутыми под Qt (θ = −a, ось Y вверх), а
у SwiftUI ось Y вниз, как у PIL, и переворот надо снимать обратно. Поймано
глазами на собранном бандле, проверкой такое не ловится. Заодно `addArc`
заменён на `addRelativeArc`: у первого флаг `clockwise` в перевёрнутом
пространстве означает не то, что читается.

### Задача 6.2: Главное окно и кнопка питания

**Файлы:**
- Create: `Sources/SCVPNApp/Views/MainView.swift`
- Create: `Sources/SCVPNApp/Views/PowerButton.swift`
- Create: `Sources/SCVPNApp/Views/ServerRow.swift`
- Create: `Sources/SCVPNApp/AppModel.swift`

**Interfaces:**
- Produces: `@Observable final class AppModel` с полями `state`, `servers`,
  `selectedKey`, `logLines`, `settings`, и методами `connect()`,
  `disconnect()`, `pingAll()`.

Qt-сигналы (`log_signal`, `state_signal`, `tun_state_signal`) заменяются на
`@MainActor`-обновление `AppModel`. Фоновые задачи (`Worker`, `PingWorker`) — на
`Task`.

Состояния экрана: `idle`, `connecting`, `connected`, `tun_stuck`. Последнее —
отдельное, видимое состояние: туннель пережил остановку.

- [x] **Шаги:** каркас, привязка к `Tun`/`XrayRunner`, ручная проверка, коммит.

**Результат.** Окно собрано и прогнано живьём на настоящем `profiles.json`
пользователя: шапка, кнопка питания, список из 11 серверов с подзаголовками и
выбором, лог. 283 проверки зелёные.

**`ObservableObject`, а не `@Observable`:** второй требует macOS 14, планка
проекта — 13.0. Поднимать её ради синтаксиса нельзя.

**Состояния и пинг вынесены в `SCVPNCore`** и закрыты проверками: там, где Qt
держал их словарями в модуле окна, проверять было нечего. Отдельная проверка
следит, что **любые два состояния отличаются не только яркостью** — цветом,
толщиной или пунктиром: в чёрно-белой теме иначе «подключено» и «ошибка»
читаются одинаково.

**Чего в Qt-версии не было и что пришлось написать:** обёртка `WeakModel`.
Колбэки ядра и пробы отпечатка приходят с чужих потоков, а модель живёт на
главном; захват `[weak self]` прямо в такое замыкание Swift 6 считает ошибкой,
а не предупреждением.

### Задача 6.3: Титлбар

**Файлы:**
- Create: `Sources/SCVPNApp/Views/WindowAccessor.swift`

`.windowStyle(.hiddenTitleBar)` даёт `titlebarAppearsTransparent` и
`fullSizeContentView` разом. Сдвиг «светофора» вниз — тот же приём, что в
`titlebar.py`: растим контейнер кнопок, ставим кнопки в его центр. Пересчёт
после каждой перекладки заголовка нужен так же, как сейчас.

76 строк `ctypes` вокруг `objc_msgSend` с явными `argtypes` из-за arm64
исчезают.

- [x] **Шаги:** реализовать, ручная проверка на масштабе 1x и 2x, коммит.

**Результат.** 76 строк `ctypes` вокруг `objc_msgSend` с явными `argtypes`
(нужны из-за arm64) заменены обычными вызовами AppKit — `WindowAccessor.swift`,
40 строк вместе с наблюдателями за перекладкой.

**Нашлось при живом прогоне:** `.windowStyle(.hiddenTitleBar)` мало.
SwiftUI отодвигает содержимое от «безопасной зоны» скрытой полосы, и шапка
уезжала под светофор — кнопки окна оказывались выше надписи. Лечится
`.ignoresSafeArea(.all, edges: .top)`, прямым аналогом
`WA_ContentsMarginsRespectsSafeArea = False`, который Qt-версия ставит в двух
местах. Ни одна проверка этого не поймала бы: геометрию считает SwiftUI.

### Задача 6.4: Меню «⋯»

**Файлы:**
- Create: `Sources/SCVPNApp/Views/MainMenu.swift`

Состав дословно по таблице README. Два поведенческих правила:

- **«Удалить компоненты TUN…» виден, только когда есть что удалять**
  (`tunPresent()`).
- **На darwin префлайт TUN идёт в порядке «сначала права, потом компоненты»**
  (`_tun_preflight`) — обратный порядок даёт неснимаемый круг на чистой машине.

- [ ] **Шаги:** реализовать, проверить оба правила руками, коммит.

### Задача 6.5: Диалоги

**Файлы:**
- Create: `Sources/SCVPNApp/Views/AddSheet.swift`
- Create: `Sources/SCVPNApp/Views/SplitTunnelSheet.swift`
- Create: `Sources/SCVPNApp/Views/SubscriptionSheet.swift`
- Create: `Sources/SCVPNApp/Views/QRScannerView.swift`
- Create: `Sources/SCVPNApp/Views/ProgressSheet.swift`

QR-сканер: `AVCaptureSession` + `AVCaptureMetadataOutput` с типом `.qr`.
Уходит `opencv-python-headless` и ручной цикл захвата кадров.
`NSCameraUsageDescription` уже в `Info.plist` (Задача 1.2).

QR-генерация: `CIFilter.qrCodeGenerator()`. Уходит `qrcode`.

Два правила окна загрузки:

- **Отмены у окна загрузки нет намеренно.**
- **Полоска загрузки sing-box остаётся бегущей**, а не показывает выдуманные
  проценты: качает демон, байтов мы не видим.

- [ ] **Шаги:** реализовать по одному диалогу, ручная проверка, коммиты.

---

## Фаза 7. Сборка, подпись, документация (2–3 дня)

### Задача 7.1: README

**Файлы:**
- Modify: `desktop/MacOS/README.md` (или создать `desktop/MacOS-Swift/README.md`)
- Modify: `README.md` (корневой)

Что обязано поменяться:

- запуск из исходников: `swift build` / `build.sh`, а не venv;
- раздел «Как устроен TUN»: `SMAppService` вместо osascript, plist внутри
  бандла, исчезновение `/Library/Application Support/SCVPN/code`;
- ручное снятие компонента: `SMAppService.unregister()` из приложения, а
  вручную — через System Settings → Login Items;
- в ручной проверке `pgrep -f "run.py --helper"` → `pgrep -f scvpn-helper`;
- новый шаг в сценарии установки: «первый `register()` штатно просит
  разрешения».

- [ ] **Шаги:** переписать, вычитать, коммит.

### Задача 7.2: Проверка версии macOS

- [ ] **Шаг 1:** Собрать под `--target arm64-apple-macosx13.0`, убедиться, что
  ни один используемый API не новее 13.0.
- [ ] **Шаг 2:** Если что-то новее — заменить, а не поднимать планку.
- [ ] **Шаг 3:** Коммит.

---

## Фаза 8. Ручная проверка (1 день)

Отдельная машина, где потерять сеть на пару минут не страшно, и **не по
SSH-сессии в эту же машину**: провальный исход последнего шага означает, что
весь трафик заперт в мёртвом туннеле, а приложение, которое могло бы его снять,
уже убито `-9`.

### Задача 8.1: Полный прогон README

- [ ] Шаг 1: режим «прокси», проверка `networksetup -getwebproxy Wi-Fi`.
- [ ] Шаг 2: переключение на TUN в том же окне, первое включение просит
  разрешение в System Settings.
- [ ] Шаг 3: фиксация, что туннель действительно поднят (непустой `SB_PID`, а
  не наличие `utun` — на типичной машине уже стоят посторонние `utun0..utun9`).
- [ ] Шаг 4: dead-man's switch — `kill -9` приложения, PID демона обязан
  остаться **тем же** (сменился — значит демон тоже погиб и его поднял launchd,
  а новый демон подметает сироту сам, и все проверки позеленеют при полностью
  сломанном обнаружении обрыва).
- [ ] Шаг 5: раздельное туннелирование по приложениям — **шаг, который ни разу
  не выполнялся** (README это честно признаёт).

### Задача 8.2: Исход шага 5

- [ ] **Если правила `process_name` работают:** снять ⚠️-оговорку в README.
- [ ] **Если не работают:** честный исход не «оставить как есть», а:
  1. написать в README прямо: не работает;
  2. погасить выбор приложений в `SplitTunnelSheet` на darwin — режимы «всё
     через VPN» и «обход» оставить, они от `sing-box` не зависят;
  3. в самом диалоге сказать, почему пункт недоступен.

### Задача 8.3: Уборка

- [ ] **Шаг 1:** Удалить строку `SCVPN_ASSUME_HELPER` из
  `desktop/MacOS/helper/install.py`.
- [ ] **Шаг 2:** Решить судьбу `desktop/MacOS/` (Python-версия): удалить или
  оставить как справочник. Рекомендация — оставить одним коммитом-архивом и
  удалить в следующем релизе, когда Swift-версия отходит месяц.
- [ ] **Шаг 3:** Завести `docs/mirror-map.md`: какой Swift-файл зеркалит какой
  Python-файл, и правило «правка в `desktop/shared/` требует парной правки в
  `SCVPNCore/`». Это постоянный налог плана A, и он должен быть записан, а не
  жить в чьей-то памяти.
- [ ] **Шаг 4:** Коммит.

---

## Приложение А. Инварианты → проверки

Таблица заполняется по мере Фазы 2. Пустая ячейка справа — незакрытый
инвариант, то есть незавершённая фаза.

| № | Инвариант (спец. 2.4) | Проверка в XCTest | Задача |
|---|---|---|---|
| 1 | Dead-man's switch | `test_daemon_drops_tunnel_when_connection_closes` | 2.11 |
| 2 | Снимается только свой туннель | `test_daemon_leaves_foreign_tunnel_alone_on_disconnect` | 2.11 |
| 2 | Туннель без хозяина снимает первый отключившийся | `test_daemon_drops_ownerless_tunnel_on_any_disconnect` | 2.11 |
| 3 | `owner` до первой записи в лог | `test_sets_owner_before_the_only_fallible_step_after_launch` | 2.8 |
| 4 | Правдивый ответ на `stop` | `test_stop_reply_tells_the_truth` | 2.10 |
| 4 | Клиент читает правду | `test_tun_stop_reports_tunnel_that_survived_the_stop` | 5.4 |
| 5 | Единственный читатель сокета | `test_stop_reply_is_not_eaten_by_the_log_reader` | 5.4 |
| 6 | Логи выбрасываются, ответ — нет | `test_drops_logs_instead_of_stalling`, `test_never_drops_the_reply` | 2.9 |
| 6 | У «не выбрасываем» есть потолок | `test_outbox_has_a_ceiling_even_for_replies` | 2.9 |
| 7 | Подметание сироты при старте | `test_sweeps_stubborn_orphan_at_start` | 2.6 |
| 7 | «Не смог посмотреть» = «сирота жива» | `test_reports_failure_when_it_cannot_look` | 2.6 |
| 7 | Не поднимать поверх сироты | `test_refuses_to_start_over_a_stale_singbox` | 2.8 |
| 7 | Ручка не отпускается на живом процессе | `test_keeps_handle_on_unkillable_singbox` | 2.8 |
| 8 | Единственность демона | `test_refuses_second_instance` | 2.12 |
| 8 | Замок до подметания | `test_checks_lock_before_sweeping` | 2.12 |
| 9 | Проверка бинарника | `test_refuses_binary_outside_its_dir`, `test_refuses_user_writable_binary`, `test_refuses_non_executable_binary` | 2.3 |
| 10 | Проверка `xray_path` после канонизации | `test_rejects_symlink_named_xray_pointing_at_shell` | 2.4 |
| 11 | Валидация недоверенного ввода | `ValidationTests` целиком | 2.1 |
| 11 | Потолки на размеры списков | `test_rejects_oversized_split_apps_list` | 2.10 |
| 11 | Демон не падает от кривого ввода | `test_never_dies_on_deeply_nested_json` | 2.10 |
| 12 | Перехват сигналов | `test_drops_tunnel_on_sigterm`, `..._on_sighup` | 2.12 |
| 12 | Повторный сигнал не рвёт снятие | `test_drops_tunnel_on_repeated_sigterm` | 2.12 |
| 13 | `ExitTimeOut = 40` | `test_bundled_plist_exit_timeout_covers_worst_case_stop` | 1.2 |
| 14 | Снимок прокси — единственное разрешение откатывать | `test_disable_leaves_a_foreign_proxy_alone` | 5.1 |
| 14 | Свой прокси по хосту **и** порту | `test_is_enabled_wants_our_own_port_not_just_localhost` | 5.1 |
| 14 | Старый формат снимка читается | `test_is_enabled_recognizes_old_snapshot_format` | 5.1 |
| 14 | Откат восстанавливает состояние | `test_snapshot_round_trip_restores_state` | 5.1 |
| 15 | Устаревшая установка распознаётся | заменено на `SMAppService.status`; см. раздел 0.4 | 3.1 |

Найдено сверх списка при переносе — инвариант, которого в разделе 2.4 нет:

| № | Инвариант | Проверка в XCTest | Задача |
|---|---|---|---|
| 16 | Запись в закрытый сокет не убивает демона | `test_writing_into_a_closed_socket_does_not_kill_the_process` | 2.9 |
| 17 | Настоящий `profiles.json` переживает круг чтение-запись | `test_reads_a_real_profiles_json_without_losing_fields` | 4.8 |
| 18 | Ссылка подписки проверяется до сети | `test_bad_url_is_refused_before_the_network` | 4.4 |
| 19 | Брошенное соединение с демоном закрывается | `deinit` у `HelperConnection` и `Tun` | 5.4 |
| 20 | Первый `register()` — шаг сценария, а не отказ | `test_first_register_failure_with_requires_approval_is_not_a_failure` | 3.1 |
| 21 | Версия демона расходится — перерегистрировать | `ensureCurrent`, ключ `helper_version` | 3.2 |
| 22 | AppleScript с кириллицей компилируется | `test_generated_applescript_actually_compiles` | 3.4 |

№19 — та же порода, что и №16: в Python сокет закрывал сборщик мусора, в Swift
это надо написать руками. Без `deinit` брошенный `Tun` держал бы дескриптор до
конца процесса, демон не увидел бы обрыва, и dead-man's switch — главное
свойство проекта — просто не сработал бы.

№17 и №18 — тоже находки переноса. Первый закрывает формат на диске: в Python
его держал только тот факт, что `to_dict` возвращал `self.__dict__` целиком, то
есть свойство было следствием устройства языка, а не проверки. Второй —
поведение `URL(string:)` на macOS 26: он принимает «не ссылка» как относительный
путь, и без своей проверки схемы пользователь получал бы «домен провайдера
заблокирован» вместо «это не ссылка».

Про №16. В Python его не было, потому что там его давал сам язык: SIGPIPE заглушён по
умолчанию и приходит как `BrokenPipeError`, который код и ловил. В Swift сигнал
доходит до процесса и убивает **весь демон** — вместе с надзором за `sing-box`,
который остаётся сиротой с маршрутами. Закрывается `SO_NOSIGPIPE` на каждом
сокете плюс `signal(SIGPIPE, SIG_IGN)` в `daemonMain`. Ровно тот случай, о
котором предупреждает Задача 0.9: свойство держалось на устройстве Python, а не
на коде, и в списке инвариантов его поэтому не было.

---

## Приложение Б. Что теряется и как это удерживать

1. **`desktop/shared/` перестаёт быть общим с Windows.** Парсеры ссылок и
   подписок, модели, конфиг Xray, хранилище и весь UI — сегодня один код на две
   платформы. После переписывания каждая правка логики делается дважды и со
   временем расходится. Это не разовая цена, а постоянный налог.
   Смягчение — `docs/mirror-map.md` (Задача 8.3) и правило парной правки.
2. **Проверки контракта между платформами теряются безвозвратно.**
   `test_tun_contract_matches_windows`, `test_native_contract_covers_both_platforms`,
   `test_tun_stop_returns_bool_on_both_platforms` сверяют сигнатуры Python-модулей
   двух платформ интроспекцией. После разделения языков держать этот контракт
   нечем.
3. **3100 строк проверок переписываются заново.** Именно они, а не сам код,
   определяют срок.

---

## Приложение В. Ответы на открытые вопросы спецификации (раздел 10)

| № | Вопрос | Ответ этого плана |
|---|---|---|
| 1 | `SMAppService` с ad-hoc | Закрыт экспериментом: работает |
| 2 | Не сломает ли `SMAppService` инварианты | Фаза 0, Задачи 0.3 и 0.4. `KeepAlive` — стоп-условие: не работает, значит план A в предложенном виде нежизнеспособен |
| 3 | Трёхсостоянийный контракт | Задача 3.1: `HelperState` с четырьмя случаями, `awaitingApproval` — штатный шаг, а не ошибка |
| 4 | Порядок фаз: демон первым | Принят. Дополнен мостом из раздела 0.3, без которого критерий приёмки Фазы 2 невыполним |
| 5 | Один бинарник или два | Два. Плюс: тестируемая логика демона вынесена в `SCVPNHelperKit`, иначе XCTest её не видит |
| 6 | Оценка 6–9 недель | Оставлена. SwiftPM экономит день на Фазе 1, Фаза −1 добавляет день |
| 7 | Стоит ли вообще делать | Фаза −1 — стоп-условие. Две дешёвые правки закрывают TCC-баг и, возможно, вес бандла; после них решение принимается на фактах, а не на ожиданиях |
| 8 | Полон ли раздел 2.4 | Задача 0.9: сплошное чтение `test_native.py` с выпиской свойств. Не пропускать |

---

## Приложение Г. Реестр рисков

| Риск | Признак | Что делать |
|---|---|---|
| `KeepAlive` не работает под `SMAppService` | Задача 0.4 | Стоп. Возврат к `launchctl bootstrap`, Фаза 3 растёт до 2–4 дней |
| Изменённый plist не подхватывается | Задача 0.3 | `unregister()` + `register()` по версии, Задача 3.2 |
| `URLSession` не работает в root-демоне | Фаза 2, Задача 2.13 | `/usr/bin/curl` |
| HTTPS через локальный прокси в `URLSession` | Фаза 4, Задача 4.7 | `/usr/bin/curl -x` |
| Правила `process_name` не работают на darwin | Фаза 8, шаг 5 | Задача 8.2: погасить выбор приложений, сказать честно |
| SwiftUI-приложение не запускается вне бандла | Фаза 1 | Ожидаемо. Отлаживать через `build.sh && open` |
| Swift 6 strict concurrency ломает демона | Фаза 2 | `swift-tools-version:5.10`, не поднимать до 6 в этом проекте |
