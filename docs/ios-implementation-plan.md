# План реализации: iOS-клиент SCVPN

> **Статус: работа остановлена.** Всё, что можно сделать без платного
> аккаунта Apple, сделано и проверено. Оставшееся — Фаза 0: подпись с
> entitlement и проверка туннеля на устройстве. Подробности в корневом
> README, раздел «iOS: поддержка прекращена».

> **Для исполнителя (агента).** Это рабочий план, а не обзор. Выполняй задачи по
> порядку, каждая задача заканчивается зелёными проверками и коммитом. Шаги
> помечены чекбоксами `- [ ]`. Фаза 0 — стоп-условие: её отрицательный результат
> отменяет проект, а не сдвигает сроки. Если факт с живого устройства разошёлся
> с текстом плана — останавливайся и правь план, а не подгоняй код под текст.

**Цель.** Нативный iOS-клиент SCVPN: те же подписки, тот же формат профилей, тот
же конфиг ядру, туннель через `NEPacketTunnelProvider`. Схема внутри туннеля
повторяет Android: TUN → hev-socks5-tunnel → Xray в процессе расширения.

**Архитектура.** Два процесса: приложение (SwiftUI, UI и вся логика) и
расширение `PacketTunnel` (Xray как библиотека + мост TUN↔SOCKS). Общий код —
SwiftPM-пакет `core-swift`, тот же, что у macOS-версии. Конфиг ядру едет в
расширение через `NETunnelProviderProtocol.providerConfiguration`; App Group не
используется. Обратная связь — `sendProviderMessage` и `NEVPNStatusDidChange`.

**Стек.** Swift 5.10, Xcode-проект (`.xcodeproj`) для iOS-таргетов, SwiftPM для
общего кода, XCTest, Foundation, SwiftUI, NetworkExtension, AVFoundation,
CoreImage, CryptoKit, Security (Keychain). Внешние зависимости — ровно две:
`LibXray.xcframework` (ядро, MPL-2.0) и `Tun2SocksKit` (обёртка над
`hev-socks5-tunnel`, MIT).

**Спецификация.** [docs/ios-port-plan.md](ios-port-plan.md) — читать вместе с
этим планом. Раздел 0 спецификации (entitlement) — предусловие всего плана,
раздел 9 (инварианты) — список того, что менять нельзя, раздел 12 (открытые
вопросы) закрывается Фазой 0 и Приложением Б.

**Образец для подражания.** Готовая macOS-версия: `desktop/macOS/` (код) и
`desktop/macOS/README.md` (как это устроено и почему). Планов её переписывания в
`docs/` больше нет — они выполнены и удалены в коммите `ab91a65`; за
обоснованиями решений идти в историю коммитов, за правилами общего кода — в
раздел README «Общий код с Windows». Тексты интерфейса, палитра, геометрия знака
и уже написанные проверки `SCVPNCoreTests` берутся из кода, а не из документов.

**Состояние репозитория, на которое опирается план:** ветка `main`, коммит
`ab91a65`, рабочее дерево чистое (кроме самих документов `docs/ios-*.md`).
Раскладка на диске:

| Каталог | Что это |
|---|---|
| `desktop/macOS/` | Swift-версия, основная. Была `desktop/MacOS-Swift/` |
| ~~`desktop/macOS-python/`~~ | прежняя реализация на Python. Была `desktop/MacOS/`, удалена вместе с Qt-версией для macOS |
| `desktop/shared/` | общий Python-код с Windows-версией |

macOS-версия на Swift **закончена**: приложение, демон, интерфейс, README на
месте. Проверки:

```bash
cd desktop/macOS && swift test --skip SystemProxyLiveTests
```

Факт на 2026-08-16: `Executed 303 tests, with 0 failures`.
`SystemProxyLiveTests` пропускается намеренно — она правит системный прокси
настоящей машины. Это число — точка отсчёта для Фазы 1: после переезда пакета
оно обязано остаться тем же.

---

## Ход работ

Отметки о выполненном — здесь, чтобы следующий исполнитель не начинал с нуля.

| Фаза / задача | Состояние | Чем подтверждено |
|---|---|---|
| 1.1 Переезд `SCVPNCore` в `core-swift/` | **сделано** (`44a20f0`) | 197 + 106 = 303 проверки, `build.sh` собирает `.app` |
| 1.2 Сборка пакета под iOS | **сделано** (`d413109`) | `xcodebuild -destination 'generic/platform=iOS'` — BUILD SUCCEEDED |
| 2.1–2.2 Проект и таргеты | **сделано** (`689e647`) | `ios/project.yml` + XcodeGen; `.xcodeproj` не коммитится |
| 2.3 `TunnelController` | **сделано** | статус от `NEVPNStatusDidChange`, отказ объясняется словами |
| 3.1 Протокол `providerConfiguration` | **сделано** | `TunnelProtocolTests` — 5 проверок на симуляторе |
| 3.2 `XrayBridge` | **сделано** | готовое ядро из релиза libXray, версия API определяется перебором; настройки показывают Xray 26.7.28 |
| 3.5 Лог и счётчики из расширения | **сделано** | `askStatus` раз в секунду, строки уходят в журнал, трафик — в подстроку статуса |
| 3.3–3.4, 3.6 Мост и провайдер | **написаны, не проверены** | NetworkExtension в симуляторе не работает; нужен entitlement и устройство |
| 4.1 HWID через Keychain | **сделано** | `machineSource()` под `#if os(iOS)` |
| 4.4 Конфиг без гео-баз | **сделано** | `GeoFreeConfigTests` — 7 проверок |
| 4.5 Пинг | **частично** | TCP-пинг работает; замер через ядро ждёт libXray |
| 4.6 Автоподбор отпечатка | **сделано** | `DelayMeasuring` + `FingerprintProbeTests` — 6 проверок |
| 5.1–5.5 Интерфейс | **сделано** | проверено на iPhone 16 Pro, iOS 26.4: добавление, удаление сервера, подписки с QR, пинг, настройки, перенос профилей |
| Сверх плана: перенос профилей файлом | **сделано** | `mergeProfiles` + 6 проверок; тот же формат на всех четырёх платформах |
| Сверх плана: язык бандла | **сделано** | `CFBundleLocalizations: [ru]` — системные кнопки не разъезжаются с русским интерфейсом |
| 3.4 Порядок подъёма и откат | **сделано** | `TunnelBringUp` + 5 проверок на подделках: успех, отказ на каждом шаге, обратный порядок остановки |
| 5.6 Иконка | **сделано** | рендерится из `BrandmarkView`, видна на домашнем экране |
| 6.1–6.2 Сборка и документация | **сделано** | `ios/build.sh` (архив и ipa), `ios/README.md` |
| 0.x Разведка на железе | **не начата** | нужен платный аккаунт и устройство |

Проверено живьём в симуляторе: добавление сервера ссылкой и вставкой, разбор
`vless://` с REALITY, живая подписка на три сервера (vless+reality, vless+ws,
trojan; имена кириллицей), TCP-пинг, выбор и удаление сервера, экран подписки
с QR и «Поделиться», перенос профилей файлом, выбор отпечатка (уезжает в
`settings.json` в общем с десктопом формате), сканер QR (честная заглушка —
камеры нет), сохранение профилей между запусками, честный отказ подключения.

Крайние случаи, проверенные живьём (iOS-симулятор + Android-эмулятор):

- смена выбранного сервера при поднятом туннеле — статус остаётся на том,
  через который идёт трафик;
- удаление активного сервера — туннель жив, приложение предупреждает;
- обновление подписки, в которой активного сервера больше нет, — выбор
  переезжает на оставшийся, приложение не ломается;
- повторное добавление той же подписки — обновление, а не вторая копия;
- пустой ответ панели и недоступный адрес — запись не сохраняется;
- перезапуск приложения при живом туннеле (Android): после `am kill` —
  как при нехватке памяти — туннель уцелел, сервис поднялся сам, приложение
  восстановило и состояние, и имя сервера; после `force-stop` туннель снят и
  приложение честно показывает «Отключено».

Не проверено и не может быть проверено без железа: сам туннель. В симуляторе
NetworkExtension не работает, на устройстве нужен entitlement
`com.apple.developer.networking.networkextension` (Фаза 0).

**Зато та же схема проверена живьём на Android** (эмулятор Pixel, Android 14):
`VpnService` поднимает `tun0` с адресом `26.26.26.1/30`, Xray стартует внутри
процесса, мост отдаёт трафик, экран показывает «Подключено» и время сессии, в
статус-баре появляется значок VPN. Отключение снимает `tun0` и гасит сервис.
Схема на iOS та же, разница только в том, кто держит туннель:
`NEPacketTunnelProvider` вместо `VpnService`. Это не заменяет проверку на
устройстве, но показывает, что цепочка «ядро в процессе + мост + TUN» рабочая.

Итого проверок: 216 в общем пакете на macOS, 106 в macOS-приложении и демоне,
114 на iOS-симуляторе, 13 на JVM в Android.

---

## Global Constraints

Требования, действующие в каждой задаче. Значения скопированы дословно из
существующего кода и спецификации.

- **Минимальная система:** iOS 16.0. Любой API новее 16.0 — повод переписать, а
  не поднять планку.
- **Только устройство.** NetworkExtension в симуляторе не работает. Всё, что
  касается туннеля, проверяется на физическом устройстве; симулятор годится
  только для UI и для проверок, не трогающих сеть.
- **Bundle identifier приложения:** `com.scvpn.ios`. Расширение —
  `com.scvpn.ios.PacketTunnel` (обязано быть префиксом приложения, иначе профиль
  подписи не соберётся).
- **App Group не используется.** Ни для конфига, ни для настроек, ни для логов.
  Всё, что нужно расширению, едет в `providerConfiguration`.
- **Лимит памяти расширения — 50 МБ, целевой потолок 40 МБ.** Любая правка в
  коде расширения, поднимающая пик, обязана быть замерена (Задача 3.7).
- **Гео-базы в расширение не попадают.** Следствия зафиксированы в разделе 0.1.
- **Форматы на диске заморожены:** `profiles.json`, `settings.json` — те же, что
  на macOS и Windows. Неизвестные ключи при чтении сохраняются и пишутся обратно.
- **Контракт HWID заморожен:** соль `scvpn-hwid-v1`, SHA-256, UUID-форматирование,
  заголовки `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model`.
- **User-Agent подписки** по умолчанию `v2rayNG/1.9.5`, меняется в настройках.
- **Константы туннеля:** SOCKS-порт `10808`, MTU `1500`, адрес TUN `26.26.26.1`
  (маска `/30`), DNS `1.1.1.1` и `8.8.8.8` — те же значения, что в
  `ScVpnService.kt`.
- **Никакой телеметрии.** Сетевые вызовы приложения: подписка, проба отпечатка,
  трафик через сервер. Всё.
- **Сторонние бинарники не коммитятся:** ни `.xcframework`, ни гео-базы.
  `ios/Frameworks/` целиком в `.gitignore`.
- **Язык интерфейса и логов — русский**, тексты переносятся дословно из
  Android- и Python-версий.
- **Ноль изменений в Windows- и Android-версиях.** macOS-версия трогается ровно
  в двух местах: `Package.swift` и `build.sh` (Фаза 1).

---

## 0. Отклонения от спецификации и почему

### 0.1. Гео-баз в расширении нет, и это меняет объём v1

Спецификация (6.3, пункт 1) оставляет выбор из трёх вариантов и предлагает
решить по замерам. План решает заранее в пользу самого дешёвого: **`geoip.dat` и
`geosite.dat` в расширение не грузятся вообще**, и Фаза 0 не выбирает вариант, а
проверяет запас памяти у уже принятого решения.

Причина не только в памяти. В конфиге, который строит `XrayConfigBuilder`,
гео-ссылки есть и в **глобальном** режиме тоже:

```swift
rules.append(["type": "field", "outboundTag": "direct", "ip": ["geoip:private"]])
rules.append(["type": "field", "outboundTag": "direct", "domain": ["geosite:private"]])
```

То есть без гео-файлов сегодняшний конфиг не запустится ни в каком режиме — Xray
не найдёт базы и упадёт на разборе правил. Значит правка `XrayConfigBuilder`
обязательна независимо от результатов замера, и делать её надо один раз
(Задача 4.7), а не двумя способами.

Что из этого следует для v1:

| Функция | На iOS v1 | Почему |
|---|---|---|
| Режим «Глобально» | есть | приватные подсети выписываются явным списком CIDR |
| Режим «Обход РФ» | **нет** | нужен `geosite:category-ru` и `geoip:ru` |
| Блокировка рекламы | **нет** | нужен `geosite:category-ads-all` |

Пункт меню режима маршрутизации на iOS не показывается вовсе — не «показывается
и не работает». Возврат обеих функций — отдельная задача после v1 (Задача 8.2),
и делается он урезанными гео-базами в бандле, а не полными.

### 0.2. `SCVPNCore` линкуется и в расширение

Соблазн — не линковать в расширение ничего, чтобы не тратить память. Но
расширению нужны разбор `providerConfiguration` и типы протокола сообщений, а
дублирование этих типов — ровно тот способ, которым расходятся реализации
(`desktop/macOS/README.md`, раздел «Общий код с Windows»: правка логики уже
делается дважды — в `desktop/shared/` и в `SCVPNCore`).

Компромисс: общие типы туннеля живут в `SCVPNCore` в файлах под `#if os(iOS)`,
Swift-линкер выбрасывает неиспользуемый код, а платформенно-тяжёлое (`Process`,
`SystemProxy`, `Tun`) на iOS не компилируется в принципе. Стоимость проверяется
замером в Задаче 3.7; если `SCVPNCore` окажется заметен в пике — вынести
`TunnelProtocol.swift` в отдельный крошечный таргет, а не дублировать.

### 0.3. Фасад `XrayBridge` вместо прямых вызовов LibXray

Точные сигнатуры `LibXray.xcframework` в этом плане **не воспроизводятся**: они
зависят от версии libXray и способа сборки (`gomobile` против `go`/FFI), и
угаданная сигнатура хуже отсутствующей. Вместо этого:

- Задача 0.2 выписывает фактические сигнатуры из сгенерированного заголовка в
  Приложение Д этого документа;
- весь остальной код зовёт только фасад `XrayBridge` с четырьмя методами;
- смена gomobile → FFI (спецификация, вопрос 12.3) меняет один файл.

### 0.4. Автоподбор отпечатка переезжает на инъекцию зависимости

`FingerprintProbe.swift` сегодня поднимает ядро процессом и ходит через
`/usr/bin/curl`. На iOS нет ни того, ни другого. Вместо форка файла:
`candidateFingerprints` остаётся общим, а сам перебор получает протокол
`DelayMeasuring`. macOS подставляет существующую реализацию, iOS — `XrayBridge`,
проверки — подделку. Это единственный способ проверить порядок кандидатов
тестом, а не руками (см. Задачу 4.6).

### 0.5. Половина Фазы 5 уже написана — в `SCVPNCore`

Спецификация (раздел 2) составлялась по состоянию репозитория на коммит
`dffe9ab`, когда интерфейса на Swift ещё не было. К моменту написания этого
плана macOS-версия закончена, и часть того, что спецификация считала
«интерфейсом», лежит в `SCVPNCore` — то есть **переносится на iOS как есть**:

| Файл | Что внутри | На iOS |
|---|---|---|
| `SCVPNCore/Theme.swift` | `Palette` (8 цветов строками), `HeaderMetrics`, `Brandmark` (радиус, толщина, раскрытие) | палитра и знак — как есть; `HeaderMetrics` бессмыслен (шапки окна нет), но безвреден |
| `SCVPNCore/ConnectionState.swift` | `ConnectionState`, `PingResult`, `pingLabel`, `VPNMode`, `formatUptime` | как есть |
| `SCVPNCoreTests/ThemeTests.swift` | сверка палитры с `android/.../colors.xml` | как есть, работает на обеих платформах |
| `SCVPNCoreTests/ConnectionStateTests.swift` | правила подписей и колец | как есть |

Два следствия, меняющие план:

1. **Своего `TunnelController.State` не заводим.** `ConnectionState` уже
   существует, уже проверен и уже используется macOS-интерфейсом. iOS
   отображает в него `NEVPNStatus` и не производит `.tunStuck` никогда:
   туннель на iOS снимает система, а не демон. Второе перечисление состояний
   было бы ровно тем расхождением, ради предотвращения которого затевается
   `core-swift`.
2. **Задача 5.1 (палитра) сокращается** до SwiftUI-моста под iOS, а Задача 5.6
   (знак) — до переноса `BrandmarkShape` в общий пакет. Константы уже общие.

Из `ConnectionState` на iOS не используются `.tunStuck`, `tunStuckText` и
`VPNMode.proxy`. Удалять их нельзя (`vpn_mode` — ключ замороженного
`settings.json`), показывать — тоже: пункт меню, который ничего не делает,
хуже отсутствующего.

### 0.6. Проверок «только на устройстве» больше, чем на macOS

На macOS почти всё, включая демона, проверяется XCTest. Здесь туннель не
поднимается ни в симуляторе, ни в CI. Поэтому Фаза 7 — не формальность, а
единственная проверка половины Фазы 3, и её чек-лист заполняется руками с
записью результата в этот документ.

---

## Фаза 0. Разведка на железе (2–3 дня) — стоп-условие

Ничего из этой фазы не коммитится в основной код. Работа идёт в отдельной папке
`ios/Probe/` (в `.gitignore`), результат фазы — заполненная таблица фактов в
Приложении Г и решение «идём дальше / не идём».

### Задача 0.1: Подпись с NE-entitlement на живом устройстве

**Файлы:** ничего в репозитории.

- [ ] **Шаг 1: Выбрать путь подписи** (спецификация, раздел 0): A —
  Apple Developer Program, B — TrollStore. Записать выбор в Приложение Г.
- [ ] **Шаг 2:** Создать в Xcode пустой iOS-проект `Probe` с таргетом
  Network Extension типа Packet Tunnel. Capability
  `Network Extensions → Packet Tunnel` у обоих таргетов.
- [ ] **Шаг 3:** Собрать и установить на устройство. Проверить, что профиль
  подписи содержит `com.apple.developer.networking.networkextension`:

```bash
codesign -d --entitlements - --xml /path/to/Probe.app | plutil -p -
```

Ожидается ключ `com.apple.developer.networking.networkextension` со значением
`packet-tunnel-provider`.

- [ ] **Шаг 4:** Из приложения поставить VPN-профиль
  (`NETunnelProviderManager.saveToPreferences`) и включить туннель, который
  ничего не делает, кроме `setTunnelNetworkSettings`. Убедиться, что в
  Настройках iOS появился VPN и статус стал «Подключено».
- [ ] **Шаг 5 (только для пути B):** повторить шаги 3–4 для сборки, поставленной
  TrollStore. **Это ответ на вопрос 12.1 спецификации.** Отрицательный результат
  означает: бесплатного пути нет, путь A или проект закрыт.
- [ ] **Шаг 6:** Записать факт в Приложение Г.

### Задача 0.2: Сборка LibXray.xcframework и выписка сигнатур

- [ ] **Шаг 1:** Собрать:

```bash
git clone https://github.com/XTLS/libXray && cd libXray
python3 build/main.py apple gomobile
```

- [ ] **Шаг 2:** Положить результат в `ios/Frameworks/LibXray.xcframework`,
  убедиться, что путь в `.gitignore`.
- [ ] **Шаг 3:** Открыть сгенерированный заголовок и **выписать в Приложение Д
  этого документа** фактические имена и сигнатуры четырёх операций: запуск ядра
  с конфигом, остановка, замер задержки, установка каталога гео-баз (если она
  вообще требуется).

```bash
find ios/Frameworks/LibXray.xcframework -name "*.h" | xargs grep -n "FOUNDATION_EXPORT\|^- \|^+ " | head -60
```

- [ ] **Шаг 4:** Зафиксировать в Приложении Г версию libXray и версию Xray-core
  внутри неё. Обновление ядра = обновление приложения, поэтому версия — часть
  релиза.

### Задача 0.3: Xray поднимается внутри расширения

- [ ] **Шаг 1:** В `Probe` слинковать `LibXray.xcframework` с таргетом
  расширения.
- [ ] **Шаг 2:** В `startTunnel` поднять Xray с минимальным конфигом:
  SOCKS-инбаунд `127.0.0.1:10808`, один outbound `freedom`, `"log": {"loglevel":
  "warning"}`, **без единой гео-ссылки**.
- [ ] **Шаг 3:** Убедиться, что ядро действительно слушает: из того же
  расширения открыть TCP-соединение на `127.0.0.1:10808` и записать результат в
  системный лог (`os_log`), затем прочитать его через Console.app с
  подключённого устройства.
- [ ] **Шаг 4:** Записать факт в Приложение Г.

### Задача 0.4: Замер памяти — главный вопрос всего порта

**Мерять на самом слабом устройстве из целевых.**

- [ ] **Шаг 1:** Добавить в расширение периодический замер:

```swift
import Foundation
import os

// Сколько ещё можно занять до убийства расширения по лимиту.
let headroom = os_proc_available_memory()

// Сколько занято сейчас.
var info = task_vm_info_data_t()
var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
}
let footprint = kr == KERN_SUCCESS ? info.phys_footprint : 0
os_log("mem: footprint=%{public}llu headroom=%{public}ld", footprint, headroom)
```

- [ ] **Шаг 2:** Замерить в четырёх точках: сразу после старта ядра; после
  подъёма моста; на прокачке ~50 Мбит; после 30 минут под нагрузкой.
- [ ] **Шаг 3:** Для контроля — повторить замер с загруженными `geoip.dat` и
  `geosite.dat`, чтобы цена решения 0.1 была измерена, а не объявлена.
- [ ] **Шаг 4:** Записать все шесть чисел в Приложение Г.

**Критерий:** пик `phys_footprint` без гео-баз под нагрузкой ниже 40 МБ.
Не выполняется — план не идёт дальше Фазы 0 без переработки раздела 6.3
спецификации (урезание hev-буферов, форк libXray с `debug.SetMemoryLimit`).

### Задача 0.5: Мост TUN↔SOCKS и отсутствие петли

- [ ] **Шаг 1:** Добавить в `Probe` зависимость `Tun2SocksKit` (SwiftPM),
  поднять мост поверх дескриптора туннеля, выпустить трафик через SOCKS Xray с
  outbound `freedom`.
- [ ] **Шаг 2:** Проверить, что с устройства открываются сайты при включённом
  туннеле.
- [ ] **Шаг 3: Проверка на петлю.** Заменить outbound на реальный сервер и
  убедиться, что соединение ядра к серверу **не** заворачивается в собственный
  туннель. Признак петли — нулевая пропускная способность при живом ядре и
  растущий счётчик пакетов на `utun`.
- [ ] **Шаг 4:** Записать в Приложение Г, каким способом достаётся дескриптор
  туннеля (публично или через KVC `packetFlow.value(forKeyPath:
  "socket.fileDescriptor")`) — от этого зависит риск 3 из раздела 11
  спецификации.

### Задача 0.6: Поведение при убийстве расширения по памяти

- [ ] **Шаг 1:** Намеренно выйти за лимит (аллоцировать мегабайты в цикле).
- [ ] **Шаг 2:** Убедиться, что после смерти расширения система снимает туннель
  целиком, интернет на устройстве продолжает работать и в Настройках VPN не
  остаётся «подключённого» состояния.
- [ ] **Шаг 3:** Записать факт. Отрицательный результат — это отдельная задача
  Фазы 3 (перехват `memoryPressure` и добровольное `cancelTunnelWithError`).

### Задача 0.7: Итог фазы

- [ ] **Шаг 1:** Заполнить Приложение Г целиком.
- [ ] **Шаг 2:** Если любой из критериев 0.1, 0.3, 0.4, 0.5 не выполнен —
  остановиться и переписать план, а не начинать Фазу 1.
- [ ] **Шаг 3:** Коммит только документации:

```bash
git add docs/ios-implementation-plan.md && git commit -m "docs: результаты Фазы 0 iOS-порта"
```

---

## Фаза 1. Общий пакет `core-swift` (2–3 дня)

Механическая, но обязательная фаза: iOS-таргеты не могут ссылаться на код внутри
`desktop/macOS`, а копия этого кода — гарантированное расхождение. Фаза
делается целиком, одним куском, с зелёными macOS-проверками в конце.

### Задача 1.1: Переезд пакета

**Файлы:**
- Create: `core-swift/Package.swift`
- Move: `desktop/macOS/Sources/SCVPNCore` → `core-swift/Sources/SCVPNCore`
- Move: `desktop/macOS/Tests/SCVPNCoreTests` → `core-swift/Tests/SCVPNCoreTests`
- Modify: `desktop/macOS/Package.swift`
- Modify: `core-swift/Tests/SCVPNCoreTests/ThemeTests.swift:6-15`
- Modify: `desktop/macOS/README.md`

**Interfaces:**
- Produces: SwiftPM-пакет `SCVPNCore` с продуктом-библиотекой `SCVPNCore`,
  платформы `.macOS(.v13)`, `.iOS(.v16)`.

- [ ] **Шаг 1: Перенести файлы**

```bash
mkdir -p core-swift/Sources core-swift/Tests
git mv desktop/macOS/Sources/SCVPNCore core-swift/Sources/SCVPNCore
git mv desktop/macOS/Tests/SCVPNCoreTests core-swift/Tests/SCVPNCoreTests
```

- [ ] **Шаг 2: Создать `core-swift/Package.swift`**

```swift
// swift-tools-version:5.10
// Версия не поднимается до 6.0 по той же причине, что и в macOS-пакете:
// строгая проверка конкурентности ломает код, который намеренно шарит
// состояние между потоками.
import PackageDescription

let package = Package(
    name: "SCVPNCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SCVPNCore", targets: ["SCVPNCore"]),
    ],
    targets: [
        .target(name: "SCVPNCore"),
        .testTarget(name: "SCVPNCoreTests", dependencies: ["SCVPNCore"]),
    ]
)
```

- [ ] **Шаг 3: Починить путь в `ThemeTests`**

Единственная проверка, которая ходит по репозиторию от `#filePath`: она сверяет
палитру с `android/app/src/main/res/values/colors.xml`. Из
`desktop/macOS/Tests/SCVPNCoreTests` до корня было **пять** уровней, из
`core-swift/Tests/SCVPNCoreTests` их три:

```swift
    private func androidColorsXML() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SCVPNCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // core-swift
        let url = repo.appendingPathComponent("android/app/src/main/res/values/colors.xml")
        return try String(contentsOf: url, encoding: .utf8)
    }
```

`RealProfilesTests` чинить **не надо**: она читает
`~/Library/Application Support/SCVPN/profiles.json`, то есть настоящий файл
пользователя, и от расположения исходников не зависит.

- [ ] **Шаг 4: Убедиться, что других таких мест нет**

```bash
grep -rln "#filePath" core-swift/Tests
```
Ожидается ровно один файл — `ThemeTests.swift`. Появился второй — он тоже ходит
по репозиторию и тоже сломан переездом.

- [ ] **Шаг 5: Подключить пакет к macOS-проекту**

В `desktop/macOS/Package.swift`:

```swift
let package = Package(
    name: "SCVPN",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../core-swift"),
    ],
    targets: [
        .target(name: "SCVPNHelperKit", dependencies: [
            .product(name: "SCVPNCore", package: "SCVPNCore"),
        ]),
        .executableTarget(name: "SCVPNHelper", dependencies: ["SCVPNHelperKit"]),
        .executableTarget(name: "SCVPNApp", dependencies: [
            .product(name: "SCVPNCore", package: "SCVPNCore"),
        ]),
        .testTarget(name: "SCVPNHelperTests", dependencies: ["SCVPNHelperKit"]),
    ]
)
```

Таргет `SCVPNCore` и тестовый `SCVPNCoreTests` из этого пакета исчезают: они
переехали.

- [ ] **Шаг 6: Прогнать обе стороны**

Run: `cd core-swift && swift test --skip SystemProxyLiveTests`
Run: `cd desktop/macOS && swift test --skip SystemProxyLiveTests`
Run: `cd desktop/macOS && ./build.sh` — Expected: `Готово: …/SCVPN.app`.

**Сумма проверок обеих команд обязана дать 303** — столько их было до переезда
(факт от 2026-08-16, см. шапку плана). Меньше — значит тестовый таргет потерял
файлы; больше — значит какая-то проверка теперь гоняется дважды.

`SystemProxyLiveTests` пропускается обеими командами намеренно: она правит
системный прокси настоящей машины, и падение посреди неё оставляет чужую
настройку затёртой. Один раз, руками, на своей машине — можно.

- [ ] **Шаг 7: Починить пути в документации**

После переезда всякая ссылка на `Sources/SCVPNCore` внутри `desktop/macOS/`
врёт. Найти:

```bash
grep -rln "Sources/SCVPNCore" README.md docs desktop/macOS/README.md
```

Обновить `desktop/macOS/README.md`: раздел «Структура» (`SCVPNCore` больше не
лежит в пакете macOS) и раздел «Общий код с Windows» — там сформулировано
правило парных правок, и адрес общего кода в нём меняется на
`core-swift/Sources/SCVPNCore/`, а потребителей у него становится три, а не два.
Это единственное место в репозитории, где правило записано: планы переписывания
и `mirror-map.md` удалены в коммите `ab91a65`.

- [ ] **Шаг 8: Коммит**

```bash
git add core-swift desktop/macOS docs && git commit -m "refactor: SCVPNCore переезжает в общий пакет core-swift"
```

### Задача 1.2: Распил платформенного кода `#if os()`

**Файлы:**
- Modify: `core-swift/Sources/SCVPNCore/{CoreDownloader,HelperClient,HelperInstaller,LegacyHelper,RunningApps,SystemProxy,Tun,XrayRunner}.swift`
- Modify: `core-swift/Sources/SCVPNCore/SingboxConfig/{Builder,Validation}.swift`
- Modify: `core-swift/Sources/SCVPNCore/FingerprintProbe.swift`
- Modify: `core-swift/Sources/SCVPNCore/{Paths,HWID}.swift`
- Modify: `core-swift/Tests/SCVPNCoreTests/{RunnerTests,SystemProxyTests,SystemProxyLiveTests,RunningAppsTests,SingboxBuilderTests,ValidationTests,HelperInstallerTests}.swift`
- Modify (частично): `core-swift/Tests/SCVPNCoreTests/{MenuRulesTests,DialogRulesTests}.swift`

**Interfaces:**
- Produces: пакет собирается под iOS. Всё, что на iOS не существует, скрыто
  `#if os(macOS)`; `SplitMode` остаётся общим (он часть формата настроек).

**Что остаётся общим и не трогается:** `Models/*`, `Parsing/*`, `Storage/*`,
`XrayConfig/XrayConfigBuilder.swift`, `TCPPing.swift`, `Theme.swift`,
`ConnectionState.swift`, `SingboxConfig/SplitMode.swift`, а из проверок —
`LinkParserTests`, `ModelTests`, `SubscriptionTests`, `StoreTests`,
`XrayConfigTests`, `RealProfilesTests`, `ThemeTests`, `ConnectionStateTests`,
`Support/Fixtures.swift` (класс `StorageIsolatedTestCase` нужен и iOS-проверкам,
он подменяет `Paths.dataDir` в `setUp`).

- [ ] **Шаг 1: Обернуть macOS-только файлы**

Каждый файл из списка целиком заворачивается:

```swift
#if os(macOS)
import Foundation
// … существующее содержимое без изменений …
#endif
```

Границы `#if` ставятся вокруг всего файла, включая `import`: `import IOKit`
на iOS не существует, и один незакрытый импорт валит сборку целиком.

- [ ] **Шаг 2: Разделить `Paths.swift`**

```swift
public enum Paths {
    #if os(macOS)
    public static var dataDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SCVPN")
    #else
    /// Контейнер приложения. Расширению эти пути не нужны: оно получает
    /// готовый конфиг в providerConfiguration и на диск не ходит.
    public static var dataDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SCVPN")
    #endif

    public static var logDir: URL { dataDir.appendingPathComponent("logs") }
    public static var profilesFile: URL { dataDir.appendingPathComponent("profiles.json") }
    public static var settingsFile: URL { dataDir.appendingPathComponent("settings.json") }

    #if os(macOS)
    // binDir, xrayExe, geoipDat, helperDir, helperSocket и прочее хозяйство
    // демона — как есть, без изменений.
    #endif

    public static func ensureDirs() {
        #if os(macOS)
        for d in [binDir, dataDir, logDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        #else
        for d in [dataDir, logDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        #endif
    }
}
```

На iOS `binDir` и всё, что вокруг ядра на диске, не существует: ядро вшито в
бандл (спецификация, раздел 1).

- [ ] **Шаг 3: Разделить `FingerprintProbe.swift`**

`probeURL`, `fallbackFingerprints`, `candidateFingerprints` — общие, остаются
снаружи. `probeFingerprint` и `findWorkingFingerprint` (они зовут `Process` и
`/usr/bin/curl`) — под `#if os(macOS)`.

- [ ] **Шаг 4: Обернуть macOS-только проверки**

Те же `#if os(macOS)` вокруг тестовых файлов из списка. Проверка не должна
исчезать с macOS — только не компилироваться под iOS.

Два файла заворачиваются **не целиком**, иначе с iOS исчезнут проверки, которые
там работают:

- `MenuRulesTests` — под `#if os(macOS)` уходят
  `test_remove_tun_is_offered_only_when_there_is_something_to_remove` и
  `test_tun_present_and_privileged_are_independent_questions` (обе зовут
  `CoreDownloader` и `HelperInstaller`). `test_every_menu_setting_has_a_default`
  остаётся общей: настройки одни на все платформы.
- `DialogRulesTests` — под `#if os(macOS)` уходят три проверки раздельного
  туннелирования (`buildSingboxConfig`, `validate`, `RunningApps`). Разбор
  ссылок и карточка подписки остаются общими — на iOS эти диалоги те же.

- [ ] **Шаг 5: Собрать под iOS**

Run:
```bash
cd core-swift && xcodebuild build -scheme SCVPNCore -destination 'generic/platform=iOS' -quiet
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Шаг 6: Убедиться, что macOS не сломался**

Run: `cd core-swift && swift test --skip SystemProxyLiveTests` — Expected: PASS,
число проверок то же, что после Задачи 1.1. Уменьшилось — значит `#if` захватил
лишнее: типичная ошибка — завернуть весь `Theme.swift` из-за `CGFloat` в
`HeaderMetrics` (он есть и на iOS) или весь `DialogRulesTests` из-за трёх
macOS-проверок внутри.

- [ ] **Шаг 7: Коммит**

```bash
git add core-swift && git commit -m "refactor: SCVPNCore собирается под iOS"
```

---

## Фаза 2. Каркас iOS (2–3 дня)

### Задача 2.1: Xcode-проект и два таргета

**Файлы:**
- Create: `ios/SCVPN.xcodeproj`
- Create: `ios/SCVPN/Info.plist`, `ios/SCVPN/SCVPN.entitlements`
- Create: `ios/PacketTunnel/Info.plist`, `ios/PacketTunnel/PacketTunnel.entitlements`
- Create: `ios/.gitignore`

- [ ] **Шаг 1:** Создать проект `SCVPN` (iOS App, SwiftUI, Swift, минимум 16.0),
  bundle id `com.scvpn.ios`.
- [ ] **Шаг 2:** Добавить таргет `PacketTunnel` (Network Extension → Packet
  Tunnel Provider), bundle id `com.scvpn.ios.PacketTunnel`.
- [ ] **Шаг 3:** У обоих таргетов — capability `Network Extensions`, галка
  `Packet Tunnel`. App Groups **не включать**.
- [ ] **Шаг 4:** В `ios/SCVPN/Info.plist` добавить `NSCameraUsageDescription`:
  «Камера нужна, чтобы отсканировать QR-код с настройками сервера.» Без него
  сканер QR (Задача 5.5) роняет приложение при первом обращении к камере.
- [ ] **Шаг 5:** `ios/.gitignore`:

```gitignore
Frameworks/
build/
DerivedData/
*.xcuserstate
xcuserdata/
```

- [ ] **Шаг 6:** Собрать и установить на устройство. Expected: приложение
  запускается, пустой экран.
- [ ] **Шаг 7:** Коммит.

### Задача 2.2: Подключить `core-swift` и `Tun2SocksKit`

**Файлы:**
- Modify: `ios/SCVPN.xcodeproj/project.pbxproj` (через Xcode, не руками)

- [ ] **Шаг 1:** File → Add Package Dependencies → Add Local → выбрать
  `core-swift`. Продукт `SCVPNCore` слинковать с **обоими** таргетами.
- [ ] **Шаг 2:** Добавить `Tun2SocksKit` (SwiftPM, по URL) — только к таргету
  `PacketTunnel`.
- [ ] **Шаг 3:** `LibXray.xcframework` из Задачи 0.2 положить в
  `ios/Frameworks/` и слинковать с **обоими** таргетами: расширению он нужен для
  туннеля, приложению — для пинга и подбора отпечатка (спецификация, 6.6).
  Embed: `Do Not Embed` для расширения (оно внутри бандла приложения),
  `Embed & Sign` для приложения.
- [ ] **Шаг 4:** В обоих таргетах написать по одной строке, использующей символ
  из `SCVPNCore` и из `LibXray`, собрать. Expected: `BUILD SUCCEEDED`.
- [ ] **Шаг 5:** Коммит.

### Задача 2.3: `TunnelController` — установка профиля и управление

**Файлы:**
- Create: `ios/SCVPN/Tunnel/TunnelController.swift`
- Test: `ios/SCVPNTests/TunnelControllerTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor
public final class TunnelController: ObservableObject {
    // Своего перечисления состояний нет: ConnectionState уже лежит в
    // SCVPNCore, уже проверен и уже отрисован macOS-версией (раздел 0.5).
    @Published public private(set) var state: ConnectionState = .idle

    /// Ставит или обновляет VPN-профиль. Первый вызов показывает системный
    /// запрос разрешения — это штатный шаг, а не ошибка.
    public func install(config: TunnelConfig, title: String) async throws
    public func start() async throws
    public func stop() async
    /// Спросить расширение о состоянии. nil — расширение не отвечает.
    public func askStatus() async -> ProviderStatus?
}
```

- [ ] **Шаг 1: Реализация**

```swift
import Foundation
import NetworkExtension
import SCVPNCore

@MainActor
public final class TunnelController: ObservableObject {
    private var manager: NETunnelProviderManager?

    private func loadManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        // Профиль ровно один. Лишние — мусор прошлых сборок, он мешает
        // пользователю в Настройках и подлежит удалению, а не игнорированию.
        for extra in all.dropFirst() { try? await extra.removeFromPreferences() }
        let m = all.first ?? NETunnelProviderManager()
        manager = m
        return m
    }

    public func install(config: TunnelConfig, title: String) async throws {
        let m = try await loadManager()
        let proto = NETunnelProviderProtocol()
        // Обязательное поле. Значение произвольное: сервер настоящего
        // подключения живёт внутри конфига Xray.
        proto.serverAddress = title
        proto.providerBundleIdentifier = "com.scvpn.ios.PacketTunnel"
        proto.providerConfiguration = config.asProviderConfiguration()
        m.protocolConfiguration = proto
        m.localizedDescription = "SCVPN"
        m.isEnabled = true
        try await m.saveToPreferences()
        // Перечитать обязательно: после сохранения объект в памяти помечен
        // stale, и startVPNTunnel на нём даёт NEVPNErrorConfigurationInvalid.
        try await m.loadFromPreferences()
    }

    public func start() async throws {
        let m = try await loadManager()
        try m.connection.startVPNTunnel()
    }

    public func stop() async {
        guard let m = manager else { return }
        m.connection.stopVPNTunnel()
    }
}
```

- [ ] **Шаг 2: Подписка на статус**

```swift
    private var observer: NSObjectProtocol?

    public func observeStatus() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.state = ConnectionState(conn.status) }
        }
    }
```

```swift
#if os(iOS)
import NetworkExtension

extension ConnectionState {
    /// Статус от системы — единственный источник правды о туннеле.
    ///
    /// `.tunStuck` тут не появляется никогда и появиться не может: на iOS
    /// туннель снимает сама система, а состояние «просили снять, а он стоит» —
    /// это про macOS-демона и sing-box.
    public init(_ s: NEVPNStatus) {
        switch s {
        case .connected: self = .connected
        case .connecting, .reasserting: self = .connecting
        // «Отключаемся» отдельным состоянием не заводим: экран показывает то же,
        // что при простое, а лишний случай пришлось бы рисовать во всех трёх
        // платформах ради полусекунды.
        case .disconnecting, .disconnected: self = .idle
        case .invalid: self = .error
        default: self = .idle
        }
    }
}
#endif
```

Файл кладётся в `core-swift/Sources/SCVPNCore/Tunnel/ConnectionState+NE.swift` —
рядом с `TunnelProtocol.swift` из Задачи 3.1, а не в приложение: `NEVPNStatus`
нужен и расширению.

Статус приходит от системы, а не считается по таймеру, — свойство
Android-версии, которое обязано сохраниться (спецификация, 6.4).

- [ ] **Шаг 3: Проверка на устройстве**

Кнопка-заглушка ставит профиль и включает пустой туннель. Expected: системный
запрос разрешения при первом `saveToPreferences`, затем VPN в Настройках,
статус в UI меняется `off → connecting → on`.

- [ ] **Шаг 4:** Коммит.

---

## Фаза 3. Расширение (1.5–2 недели)

### Задача 3.1: Протокол «приложение ↔ расширение»

**Файлы:**
- Create: `core-swift/Sources/SCVPNCore/Tunnel/TunnelProtocol.swift`
- Test: `core-swift/Tests/SCVPNCoreTests/TunnelProtocolTests.swift`

**Interfaces:**
- Produces: `TunnelConfig`, `TunnelConfigError`, `ProviderRequest`,
  `ProviderStatus`. Всё под `#if os(iOS)`.

- [ ] **Шаг 1: Написать падающие проверки**

```swift
#if os(iOS)
import XCTest
@testable import SCVPNCore

final class TunnelProtocolTests: XCTestCase {

    private func sample() -> TunnelConfig {
        TunnelConfig(xrayConfigJSON: #"{"outbounds":[]}"#, socksPort: 10808,
                     mtu: 1500, tunAddress: "26.26.26.1",
                     serverName: "Сервер 🇳🇱", logLevel: "warning")
    }

    func test_round_trip_keeps_every_field() throws {
        let restored = try TunnelConfig(providerConfiguration: sample().asProviderConfiguration())
        XCTAssertEqual(restored, sample())
    }

    func test_provider_configuration_holds_only_plist_types() {
        // Система хранит словарь в системных настройках VPN: не-plist значение
        // молча потеряется, и расширение получит конфиг без него.
        for (_, v) in sample().asProviderConfiguration() {
            XCTAssertTrue(v is String || v is NSNumber, "не plist-тип: \(type(of: v))")
        }
    }

    func test_missing_config_is_a_named_error() {
        var raw = sample().asProviderConfiguration()
        raw.removeValue(forKey: "config")
        XCTAssertThrowsError(try TunnelConfig(providerConfiguration: raw)) { e in
            XCTAssertEqual(e as? TunnelConfigError, .missing("config"))
        }
    }

    func test_unicode_name_survives() throws {
        let restored = try TunnelConfig(providerConfiguration: sample().asProviderConfiguration())
        XCTAssertEqual(restored.serverName, "Сервер 🇳🇱")
    }
}
#endif
```

- [ ] **Шаг 2: Запустить, убедиться, что падает**

Run: `cd core-swift && swift test --filter TunnelProtocolTests`
Expected: FAIL — тип `TunnelConfig` не существует. (Проверки под `#if os(iOS)`
на macOS не компилируются; для прогона использовать
`xcodebuild test -scheme SCVPNCore -destination 'platform=iOS Simulator,name=iPhone 15'`
— сеть здесь не нужна, симулятор годится.)

- [ ] **Шаг 3: Реализация**

```swift
#if os(iOS)
import Foundation

/// Единственный канал доставки настроек в расширение.
///
/// App Group — платная capability (спецификация, 6.4), поэтому конфиг едет в
/// `NETunnelProviderProtocol.providerConfiguration`. Ограничение одно:
/// значения обязаны быть property-list-типами, иначе система теряет их молча.
public struct TunnelConfig: Equatable {
    public var xrayConfigJSON: String
    public var socksPort: Int
    public var mtu: Int
    public var tunAddress: String
    public var serverName: String
    public var logLevel: String

    public init(xrayConfigJSON: String, socksPort: Int, mtu: Int,
                tunAddress: String, serverName: String, logLevel: String) {
        self.xrayConfigJSON = xrayConfigJSON
        self.socksPort = socksPort
        self.mtu = mtu
        self.tunAddress = tunAddress
        self.serverName = serverName
        self.logLevel = logLevel
    }

    public func asProviderConfiguration() -> [String: Any] {
        [
            "config": xrayConfigJSON,
            "socksPort": socksPort,
            "mtu": mtu,
            "tunAddress": tunAddress,
            "serverName": serverName,
            "logLevel": logLevel,
        ]
    }

    public init(providerConfiguration raw: [String: Any]) throws {
        func str(_ k: String) throws -> String {
            guard let v = raw[k] as? String else { throw TunnelConfigError.missing(k) }
            return v
        }
        func int(_ k: String) throws -> Int {
            guard let v = raw[k] as? Int else { throw TunnelConfigError.missing(k) }
            return v
        }
        self.init(xrayConfigJSON: try str("config"), socksPort: try int("socksPort"),
                  mtu: try int("mtu"), tunAddress: try str("tunAddress"),
                  serverName: try str("serverName"), logLevel: try str("logLevel"))
    }
}

public enum TunnelConfigError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    public var description: String {
        switch self {
        case .missing(let k): return "в настройках туннеля нет поля «\(k)»"
        }
    }
}

/// Запрос приложения к расширению. Одно значение — одна строка, чтобы
/// сериализация не требовала общего Codable-контракта на обе стороны.
public enum ProviderRequest: String, Codable {
    case status
}

/// Ответ расширения. Логи едут вместе со статусом: отдельный запрос ради
/// сотни строк не нужен.
public struct ProviderStatus: Codable, Equatable {
    public var running: Bool
    public var since: Double?          // uptime-время старта, а не дата
    public var up: UInt64
    public var down: UInt64
    public var lines: [String]

    public init(running: Bool, since: Double?, up: UInt64, down: UInt64, lines: [String]) {
        self.running = running; self.since = since
        self.up = up; self.down = down; self.lines = lines
    }
}
#endif
```

- [ ] **Шаг 4: Проверки зелёные.** Expected: PASS.
- [ ] **Шаг 5: Коммит.**

### Задача 3.2: `XrayBridge` — фасад над LibXray

**Файлы:**
- Create: `ios/Shared/XrayBridge.swift` (в обоих таргетах: приложение — для
  пинга, расширение — для туннеля)

**Interfaces:**
- Produces:

```swift
/// Структура, а не enum: она обязана соответствовать протоколу
/// `DelayMeasuring` (Задача 4.6), а протокол с обычными методами метатипом не
/// удовлетворяется. Состояния у неё нет, экземпляр — просто способ передать
/// реализацию.
struct XrayBridge: DelayMeasuring {
    static func start(configJSON: String) throws
    static func stop()
    /// Задержка в мс или -1. Ядро поднимается и гасится внутри вызова.
    static func measureDelay(configJSON: String, url: String) -> Int

    func measure(configJSON: String, url: String) -> Int {
        Self.measureDelay(configJSON: configJSON, url: url)
    }
}
```

- [ ] **Шаг 1:** Реализовать поверх сигнатур, выписанных в Приложении Д.
  Внутри фасада — единственное место во всём проекте, где встречается имя
  `LibXray`.
- [ ] **Шаг 2:** Ошибки ядра превращать в `XrayBridgeError.start(String)` с
  текстом от ядра: «не запустился» без причины неотлаживаемо на устройстве, куда
  нельзя подключить отладчик.
- [ ] **Шаг 3:** Проверка на устройстве: поднять и погасить ядро десять раз
  подряд из приложения (не из расширения), убедиться, что память не растёт.
  Растёт — это утечка в libXray, и о ней надо знать сейчас, а не в Фазе 7.
- [ ] **Шаг 4:** Коммит.

### Задача 3.3: `TunnelBridge` — мост TUN↔SOCKS

**Файлы:**
- Create: `ios/PacketTunnel/TunnelBridge.swift`

**Interfaces:**
- Produces:

```swift
enum TunnelBridge {
    static func start(socksPort: Int, mtu: Int, tunAddress: String,
                      packetFlow: NEPacketTunnelFlow) throws
    static func stop()
    /// (отправлено, принято) в байтах.
    static func stats() -> (up: UInt64, down: UInt64)
}
```

- [ ] **Шаг 1: Конфиг моста** — дословно тот же YAML, что собирает
  `ScVpnService.buildHevConfig`, плюс потолки из README `hev-socks5-tunnel` ради
  лимита памяти (спецификация, 6.3, пункт 2):

```swift
    static func yaml(socksPort: Int, mtu: Int, tunAddress: String) -> String {
        """
        tunnel:
          mtu: \(mtu)
          ipv4: \(tunAddress)
        socks5:
          port: \(socksPort)
          address: 127.0.0.1
          udp: 'udp'
        misc:
          task-stack-size: 20480
          tcp-buffer-size: 4096
          connect-timeout: 5000
          read-write-timeout: 60000
          log-level: warn
        """
    }
```

`task-stack-size` и `tcp-buffer-size` — это и есть та самая экономия памяти:
значения по умолчанию рассчитаны на десктоп и в 50 МБ вместе с Go-runtime
Xray не помещаются с запасом.

- [ ] **Шаг 2:** Дескриптор туннеля. Способ фиксируется результатом Задачи 0.5;
  если публичного пути нет — KVC, **в одном месте и с комментарием**:

```swift
    /// NEPacketTunnelFlow не отдаёт дескриптор публично. Приём известный и
    /// используется всеми клиентами вне App Store; запасной путь — гонять
    /// пакеты через readPackets/writePackets и сокет-пару (медленнее, но
    /// публично). Риск 3 раздела 11 спецификации живёт ровно здесь.
    private static func fileDescriptor(_ flow: NEPacketTunnelFlow) -> Int32? {
        (flow.value(forKeyPath: "socket.fileDescriptor") as? Int32)
    }
```

- [ ] **Шаг 3:** Проверка на устройстве: трафик идёт, `stats()` растёт.
- [ ] **Шаг 4:** Коммит.

### Задача 3.4: `PacketTunnelProvider` — порядок старта и отката

**Файлы:**
- Create: `ios/PacketTunnel/PacketTunnelProvider.swift`

Порядок — из раздела 6.8 спецификации, и он значим: **ошибка на любом шаге
снимает всё предыдущее**. Половина поднятого туннеля хуже его отсутствия — на
устройстве это выглядит как «интернета нет и выключить нечем».

- [ ] **Шаг 1: Реализация**

```swift
import NetworkExtension
import SCVPNCore
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = RingLog(capacity: 200)
    private var startedAt: Double?

    override func startTunnel(options: [String: NSObject]?) async throws {
        let raw = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration ?? [:]
        let cfg = try TunnelConfig(providerConfiguration: raw)
        log.append("[*] Подключаюсь к «\(cfg.serverName)»")

        // 1) ядро
        try XrayBridge.start(configJSON: cfg.xrayConfigJSON)
        var ok = false
        defer { if !ok { XrayBridge.stop() } }

        // 2) сетевые настройки — и дождаться подтверждения системы
        try await setTunnelNetworkSettings(Self.settings(cfg))

        // 3) мост
        do {
            try TunnelBridge.start(socksPort: cfg.socksPort, mtu: cfg.mtu,
                                   tunAddress: cfg.tunAddress, packetFlow: packetFlow)
        } catch {
            // Настройки снимаем явно: без этого система оставит маршруты на
            // мёртвом туннеле до собственного таймаута.
            try? await setTunnelNetworkSettings(nil)
            throw error
        }

        ok = true
        startedAt = ProcessInfo.processInfo.systemUptime
        log.append("[+] Туннель поднят")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.append("[*] Останавливаюсь: \(reason.rawValue)")
        TunnelBridge.stop()          // обратный порядок
        XrayBridge.stop()
        startedAt = nil
    }

    private static func settings(_ cfg: TunnelConfig) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: cfg.tunAddress)
        let ipv4 = NEIPv4Settings(addresses: [cfg.tunAddress], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        s.ipv4Settings = ipv4
        s.mtu = NSNumber(value: cfg.mtu)
        // DNS те же, что на Android: резолв идёт через ядро, поэтому
        // конкретные адреса важны меньше, чем сам факт перехвата запросов.
        s.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        return s
    }
}
```

- [ ] **Шаг 2: Проверка отката руками.** Подсунуть конфиг с заведомо занятым
  SOCKS-портом (запустить что-то на 10808 нельзя — вместо этого сломать сам
  конфиг Xray, например убрать `outbounds`). Expected: туннель не поднимается,
  ядро не остаётся в памяти, интернет на устройстве работает, VPN в Настройках
  выключен.
- [ ] **Шаг 3: Коммит.**

### Задача 3.5: Кольцевой лог и ответы приложению

**Файлы:**
- Create: `ios/PacketTunnel/RingLog.swift`
- Modify: `ios/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `ios/SCVPN/Tunnel/TunnelController.swift`
- Test: `ios/SCVPNTests/RingLogTests.swift`

Полноценного файла лога у расширения нет намеренно (спецификация, раздел 7,
пункт 4): в лимите памяти и песочнице это роскошь.

- [ ] **Шаг 1: Проверка**

```swift
func test_ring_log_keeps_only_the_last_lines() {
    let log = RingLog(capacity: 3)
    for i in 1...5 { log.append("строка \(i)") }
    XCTAssertEqual(log.snapshot(), ["строка 3", "строка 4", "строка 5"])
}
```

- [ ] **Шаг 2: Реализация** — массив под `NSLock`, `append` выбрасывает голову
  при переполнении. Потолок обязателен: неограниченный лог — это утечка памяти с
  красивым названием.

- [ ] **Шаг 3: Ответ на запрос**

```swift
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let req = try? JSONDecoder().decode(ProviderRequest.self, from: messageData),
              req == .status else { return nil }
        let s = TunnelBridge.stats()
        let status = ProviderStatus(running: startedAt != nil, since: startedAt,
                                    up: s.up, down: s.down, lines: log.snapshot())
        return try? JSONEncoder().encode(status)
    }
```

- [ ] **Шаг 4: Сторона приложения**

```swift
    public func askStatus() async -> ProviderStatus? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              let data = try? JSONEncoder().encode(ProviderRequest.status) else { return nil }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(data) { reply in
                    cont.resume(returning: reply.flatMap {
                        try? JSONDecoder().decode(ProviderStatus.self, from: $0)
                    })
                }
            } catch {
                // Расширение не запущено — это не ошибка, а «нечего спрашивать».
                cont.resume(returning: nil)
            }
        }
    }
```

- [ ] **Шаг 5:** Проверка на устройстве: в UI видны строки лога расширения и
  растущие счётчики.
- [ ] **Шаг 6:** Коммит.

### Задача 3.6: Смена сети и потеря связи

**Файлы:**
- Modify: `ios/PacketTunnel/PacketTunnelProvider.swift`

- [ ] **Шаг 1:** Подписаться на смену пути:

```swift
    private var pathObserver: NSKeyValueObservation?

    private func watchPath() {
        pathObserver = observe(\.defaultPath) { [weak self] provider, _ in
            guard let path = provider.defaultPath else { return }
            self?.log.append("[*] сеть: \(path.status == .satisfied ? "есть" : "нет")")
            // Перезапускать ядро не нужно: Xray переустанавливает соединения
            // сам. Нужно только не притворяться подключёнными, пока сети нет.
            self?.reasserting = (path.status != .satisfied)
        }
    }
```

- [ ] **Шаг 2:** Проверка на устройстве: Wi-Fi → LTE на живом туннеле. Expected:
  соединения восстанавливаются без переподключения вручную; в UI статус
  ненадолго уходит в «переподключение».
- [ ] **Шаг 3:** Авиарежим на 30 секунд и обратно. Expected: то же.
- [ ] **Шаг 4:** Коммит.

### Задача 3.7: Память в бою

- [ ] **Шаг 1:** Повторить замер Задачи 0.4, но на настоящем расширении с
  настоящим сервером и `SCVPNCore` внутри.
- [ ] **Шаг 2:** Сравнить с числами Фазы 0. Разница больше 5 МБ — искать
  причину: `SCVPNCore` (см. раздел 0.2), кольцевой лог, буферы моста.
- [ ] **Шаг 3:** Записать числа в Приложение Г.
- [ ] **Шаг 4:** Час под нагрузкой, замер в начале и в конце. Рост
  `phys_footprint` — утечка; выяснять до Фазы 4, а не после.
- [ ] **Шаг 5:** Коммит (документация).

---

## Фаза 4. Логика приложения (1 неделя)

### Задача 4.1: HWID на iOS

**Файлы:**
- Modify: `core-swift/Sources/SCVPNCore/HWID.swift`
- Create: `core-swift/Sources/SCVPNCore/Keychain.swift`
- Test: `ios/SCVPNTests/HWIDTests.swift`

Контракт менять нельзя (спецификация, 6.5): соль, SHA-256, формат UUID, имена
заголовков — как в `Hwid.kt` и в macOS-версии.

**Interfaces:**
- Produces: `machineSource()` под iOS, `deviceHeaders()` с iOS-значениями,
  `enum Keychain { static func load(_ key: String) -> String?; static func save(_ key: String, _ value: String) }`.

- [ ] **Шаг 1: Проверки**

```swift
func test_hwid_is_stable_across_calls() {
    XCTAssertEqual(deviceID(), deviceID())
}

func test_hwid_looks_like_uuid() {
    let parts = deviceID().split(separator: "-").map(\.count)
    XCTAssertEqual(parts, [8, 4, 4, 4, 12])
}

func test_headers_are_exactly_four_and_named_as_the_panel_expects() {
    let h = deviceHeaders()
    XCTAssertEqual(Set(h.keys), ["x-hwid", "x-device-os", "x-ver-os", "x-device-model"])
    XCTAssertEqual(h["x-device-os"], "iOS")
}

func test_machine_source_survives_container_wipe() {
    // Источник обязан жить в Keychain, а не в контейнере: удаление всех
    // приложений вендора обнуляет identifierForVendor, и пользователь занял
    // бы новый слот в лимите устройств панели.
    let first = machineSource()
    Paths.dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)   // «переустановка»
    XCTAssertEqual(machineSource(), first)
}
```

Проверки Keychain требуют host-приложения: тестовый таргет `SCVPNTests`
настраивается с `Host Application: SCVPN`, иначе доступ к Keychain падает с
`errSecMissingEntitlement`.

- [ ] **Шаг 2:** Запустить, убедиться, что падает.

- [ ] **Шаг 3: Реализация**

```swift
#if os(iOS)
import UIKit

/// Что-нибудь стабильное и уникальное для этого устройства.
///
/// `identifierForVendor` обнуляется, когда пользователь удалил все приложения
/// вендора, поэтому первое же значение кладётся в Keychain и переживает
/// переустановку — иначе каждая переустановка занимает новый слот устройства
/// в панели, ровно та проблема, ради которой HWID и появился.
func machineSource() -> String {
    if let saved = Keychain.load("hwid-source"), !saved.isEmpty { return saved }
    let idfv = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    Keychain.save("hwid-source", idfv)
    return idfv
}

public func deviceHeaders() -> [String: String] {
    [
        "x-hwid": deviceID(),
        "x-device-os": "iOS",
        "x-ver-os": UIDevice.current.systemVersion,
        // Машинный идентификатор (iPhone16,2), а не маркетинговое имя:
        // панели сверяют устройства по нему.
        "x-device-model": machineModel(),
    ]
}

private func machineModel() -> String {
    var info = utsname()
    guard uname(&info) == 0 else { return "iPhone" }
    return withUnsafeBytes(of: &info.machine) { raw in
        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}
#endif
```

`Keychain` — тонкая обёртка над `SecItemAdd`/`SecItemCopyMatching` с
`kSecClass: kSecClassGenericPassword`, сервисом `com.scvpn.ios` и
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: значение нужно расширению и
приложению после перезагрузки до разблокировки, но не должно уезжать в чужой
бэкап.

- [ ] **Шаг 4:** Проверки зелёные.
- [ ] **Шаг 5:** Коммит.

### Задача 4.2: Хранилище и настройки iOS

**Файлы:**
- Modify: `core-swift/Sources/SCVPNCore/Storage/Store.swift`
- Test: `core-swift/Tests/SCVPNCoreTests/StoreTests.swift`

- [ ] **Шаг 1:** `defaultSettings` **не трогать**: формат заморожен, а лишние на
  iOS ключи (`system_proxy`, `split_mode`, `split_apps`, `tun_stack`) обязаны
  переживать круг чтение-запись — иначе перенос `settings.json` с десктопа
  потеряет их.
- [ ] **Шаг 2:** Добавить проверку:

```swift
func test_ios_keeps_desktop_only_keys() {
    var s = loadSettings()
    s["split_apps"] = .array([.string("com.apple.Safari")])
    saveSettings(s)
    XCTAssertEqual(loadSettings()["split_apps"], .array([.string("com.apple.Safari")]))
}
```

- [ ] **Шаг 3:** Убедиться, что `Paths.dataDir` на iOS указывает в контейнер
  (Задача 1.2), файлы создаются, проверки зелёные.
- [ ] **Шаг 4:** Коммит.

### Задача 4.3: Подписки

**Файлы:** ничего нового — `SubscriptionFetcher.swift`, `LinkParser.swift`,
`SubscriptionInfo.swift` переносятся как есть.

- [ ] **Шаг 1:** Прогнать `LinkParserTests`, `SubscriptionTests`, `ModelTests`
  в iOS-таргете:

```bash
cd core-swift && xcodebuild test -scheme SCVPNCore \
  -destination 'platform=iOS Simulator,name=iPhone 15' -quiet
```

Expected: PASS, ровно то же число проверок, что на macOS (за вычетом
macOS-только файлов из Задачи 1.2). Это и есть страховка общего пакета
(спецификация, раздел 10).

- [ ] **Шаг 2:** Проверить на живой подписке с устройства, что заголовки
  доходят: панель отдала серверы, а не заглушку `App not supported`.
- [ ] **Шаг 3:** Коммит.

### Задача 4.4: Конфиг Xray без гео-баз

**Файлы:**
- Modify: `core-swift/Sources/SCVPNCore/XrayConfig/XrayConfigBuilder.swift`
- Test: `core-swift/Tests/SCVPNCoreTests/XrayConfigTests.swift`

**Interfaces:**
- Produces:

```swift
public func buildXrayConfig(
    server: Server, socksPort: Int = defaultSocksPort, httpPort: Int = defaultHTTPPort,
    routeMode: RouteMode = .global, blockAds: Bool = false,
    logPath: String? = nil, logLevel: String = "warning",
    geoAssets: Bool = true                      // ← новый параметр, по умолчанию как было
) throws -> [String: Any]

public enum XrayConfigError: Error, Equatable { case geoRequired(String) }

/// Приватные подсети явным списком — замена `geoip:private` там, где гео-баз нет.
public let privateCIDRs: [String]
```

- [ ] **Шаг 1: Проверки**

```swift
func test_ios_config_has_no_geo_references() throws {
    let cfg = try buildXrayConfig(server: server, geoAssets: false)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
    XCTAssertFalse(json.contains("geoip:"), "в конфиге осталась ссылка на geoip.dat")
    XCTAssertFalse(json.contains("geosite:"), "в конфиге осталась ссылка на geosite.dat")
}

func test_ios_config_still_keeps_private_networks_direct() throws {
    let cfg = try buildXrayConfig(server: server, geoAssets: false)
    let routing = try XCTUnwrap(cfg["routing"] as? [String: Any])
    let rules = try XCTUnwrap(routing["rules"] as? [[String: Any]])
    let direct = rules.first { $0["outboundTag"] as? String == "direct" }
    let ips = try XCTUnwrap(direct?["ip"] as? [String])
    XCTAssertTrue(ips.contains("192.168.0.0/16"))
    XCTAssertTrue(ips.contains("127.0.0.0/8"))
}

func test_rule_order_is_unchanged() throws {
    // Инвариант 3 спецификации: приватные адреса раньше «всё в прокси».
    let cfg = try buildXrayConfig(server: server, geoAssets: false)
    let rules = try XCTUnwrap((cfg["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
    XCTAssertEqual(rules.last?["outboundTag"] as? String, "proxy")
    XCTAssertEqual(rules.first?["outboundTag"] as? String, "direct")
}

func test_bypass_ru_without_geo_is_a_named_error() {
    XCTAssertThrowsError(try buildXrayConfig(server: server,
                                             routeMode: .bypassRU, geoAssets: false)) { e in
        XCTAssertEqual(e as? XrayConfigError, .geoRequired("обход РФ"))
    }
}

func test_macos_config_is_untouched() throws {
    // Существующие проверки macOS-конфига обязаны остаться зелёными: значение
    // geoAssets по умолчанию — true.
    let cfg = try buildXrayConfig(server: server)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
    XCTAssertTrue(json.contains("geoip:private"))
}
```

- [ ] **Шаг 2:** Запустить, убедиться, что падает.

- [ ] **Шаг 3: Реализация**

```swift
/// Приватные и служебные подсети. Список повторяет содержимое `geoip:private`
/// из гео-базы Xray — он нужен там, где базы нет (iOS: расширение живёт в
/// лимите памяти, и десятки мегабайт гео-данных туда не помещаются).
public let privateCIDRs = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24",
    "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
    "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
    "::1/128", "fc00::/7", "fe80::/10",
]

func routing(routeMode: RouteMode, blockAds: Bool, geoAssets: Bool) -> [String: Any] {
    var rules: [[String: Any]] = []

    // 1) реклама в чёрную дыру (по желанию, только с гео-базами)
    if blockAds && geoAssets {
        rules.append(["type": "field", "outboundTag": "block",
                      "domain": ["geosite:category-ads-all"]])
    }

    // 2) локальная сеть и приватные адреса — всегда напрямую
    if geoAssets {
        rules.append(["type": "field", "outboundTag": "direct", "ip": ["geoip:private"]])
        rules.append(["type": "field", "outboundTag": "direct", "domain": ["geosite:private"]])
    } else {
        rules.append(["type": "field", "outboundTag": "direct", "ip": privateCIDRs])
    }

    // 3) режим «обход РФ» — только с гео-базами (см. 0.1)
    if routeMode == .bypassRU && geoAssets {
        rules.append(["type": "field", "outboundTag": "direct",
                      "domain": ["geosite:category-ru", "geosite:yandex",
                                 "geosite:vk", "geosite:mailru"]])
        rules.append(["type": "field", "outboundTag": "direct", "ip": ["geoip:ru"]])
    }

    // 4) всё остальное — в VPN
    rules.append(["type": "field", "outboundTag": "proxy", "network": "tcp,udp"])

    return ["domainStrategy": "IPIfNonMatch", "rules": rules]
}
```

В `buildXrayConfig` — отказ вместо тихой подмены поведения:

```swift
    if !geoAssets {
        if routeMode == .bypassRU { throw XrayConfigError.geoRequired("обход РФ") }
        if blockAds { throw XrayConfigError.geoRequired("блокировка рекламы") }
    }
```

`dns(routeMode:)` получает тот же параметр: без гео-баз запись с
`domains: ["geosite:category-ru"]` не добавляется.

- [ ] **Шаг 4:** Проверки зелёные, macOS-проверки тоже.
- [ ] **Шаг 5:** Коммит.

### Задача 4.5: Пинг серверов

**Файлы:**
- Create: `core-swift/Sources/SCVPNCore/XrayConfig/ProbeConfig.swift`
- Create: `ios/SCVPN/Model/Pinger.swift`
- Test: `core-swift/Tests/SCVPNCoreTests/ProbeConfigTests.swift`

**Interfaces:**
- Produces: `public func buildProbeConfig(server: Server) throws -> String` —
  готовый JSON-текст конфига для замера задержки: один outbound на сервер, без
  инбаундов, без гео-ссылок, `loglevel: none`.

- [ ] **Шаг 1:** Проверка: конфиг разбирается как JSON, содержит ровно один
  outbound, не содержит `geoip:`/`geosite:`.
- [ ] **Шаг 2:** Реализация.
- [ ] **Шаг 3:** `Pinger` в приложении: `XrayBridge.measureDelay` по каждому
  серверу, ограничение параллельности — 4 задачи разом (иначе на списке в
  полсотни серверов приложение поднимет полсотни ядер и его убьёт система):

```swift
        await withTaskGroup(of: (String, Int).self) { group in
            var iterator = servers.makeIterator()
            var inFlight = 0
            // …обычный паттерн «не больше 4 разом»…
        }
```

- [ ] **Шаг 4:** `tcpPing` из `TCPPing.swift` остаётся как запасной путь для
  серверов, до которых замер через ядро не доходит: он на BSD-сокетах и работает
  на iOS без правок.
- [ ] **Шаг 5:** Проверка на устройстве: пинги появляются, приложение не растёт
  в памяти на списке из 50 серверов.
- [ ] **Шаг 6:** Коммит.

### Задача 4.6: Автоподбор TLS-отпечатка

**Файлы:**
- Modify: `core-swift/Sources/SCVPNCore/FingerprintProbe.swift`
- Test: `core-swift/Tests/SCVPNCoreTests/FingerprintProbeTests.swift`

Подбор выполняется **в приложении, не в расширении** (спецификация, 6.6): у
приложения нет лимита в 50 МБ, а перебор — самая прожорливая операция.
Найденный отпечаток фиксируется в `Server` и уезжает в `providerConfiguration`
уже готовым.

**Interfaces:**
- Produces:

```swift
public protocol DelayMeasuring {
    /// Задержка в мс или -1.
    func measure(configJSON: String, url: String) -> Int
}

/// Первый отпечаток, с которым сервер ответил. Ни один не ответил — первый
/// кандидат (поведение `connect.py` дословно).
public func findWorkingFingerprint(
    _ server: Server, override: String = "auto",
    using measurer: DelayMeasuring,
    log: @escaping (String) -> Void = { _ in }
) -> String
```

- [ ] **Шаг 1: Проверки на подделке**

```swift
private struct FakeMeasurer: DelayMeasuring {
    let working: String                     // отпечаток, который «отвечает»
    func measure(configJSON: String, url: String) -> Int {
        // Отпечаток вытаскиваем из самого конфига: так проверяется, что он
        // туда действительно попал, а не только в аргумент функции.
        configJSON.contains("\"fingerprint\":\"\(working)\"") ? 42 : -1
    }
}

func test_candidate_order_is_frozen() {
    var s = Server(); s.security = "reality"
    XCTAssertEqual(candidateFingerprints(s, override: "auto"),
                   ["firefox", "chrome", "safari", "edge", "ios", "randomized"])
}

func test_subscription_fingerprint_goes_first() {
    var s = Server(); s.fingerprint = "chrome"
    XCTAssertEqual(candidateFingerprints(s, override: "auto").first, "chrome")
}

func test_randomized_from_subscription_is_not_treated_as_a_choice() {
    var s = Server(); s.fingerprint = "randomized"
    XCTAssertEqual(candidateFingerprints(s, override: "auto").first, "firefox")
}

func test_explicit_override_is_not_probed() {
    var s = Server(); s.fingerprint = "chrome"
    XCTAssertEqual(findWorkingFingerprint(s, override: "safari",
                                          using: FakeMeasurer(working: "edge")), "safari")
}

func test_first_answering_fingerprint_wins() {
    let s = Server()
    XCTAssertEqual(findWorkingFingerprint(s, using: FakeMeasurer(working: "safari")), "safari")
}

func test_falls_back_to_first_candidate_when_nothing_answers() {
    let s = Server()
    XCTAssertEqual(findWorkingFingerprint(s, using: FakeMeasurer(working: "нет такого")),
                   "firefox")
}
```

- [ ] **Шаг 2:** Запустить, убедиться, что падает.
- [ ] **Шаг 3:** Реализация: перебор `candidateFingerprints`, для каждого —
  `buildProbeConfig` с подменённым `fingerprint`, `measurer.measure`, первый
  положительный ответ возвращается. Тексты в `log` — дословно из существующей
  macOS-версии («Подбираю рабочий TLS-отпечаток…», «Рабочий отпечаток: …»,
  «Ни один отпечаток не прошёл проверку, пробую первый.»).
- [ ] **Шаг 4:** Проверки зелёные.
- [ ] **Шаг 5:** Коммит.

### Задача 4.7: `AppModel` — подключение целиком

**Файлы:**
- Create: `ios/SCVPN/Model/AppModel.swift`
- Test: `ios/SCVPNTests/AppModelTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var servers: [Server]
    @Published private(set) var state: ConnectionState
    @Published private(set) var logLines: [String]
    @Published var selectedKey: String
    @Published private(set) var subscriptionInfo: SubscriptionInfo?

    func connect() async
    func disconnect() async
    func refreshSubscriptions() async
    func pingAll() async
    func add(link: String) throws
}
```

- [ ] **Шаг 1: `connect()` целиком** — порядок важен и повторяет десктоп:

```swift
    func connect() async {
        guard var server = selectedServer() else { return append("[!] Не выбран сервер") }
        state = .connecting

        // 1) отпечаток подбирается здесь, а не в расширении
        let settings = loadSettings()
        let override = settings["tls_fingerprint"]?.stringValue ?? "auto"
        if server.security == "tls" || server.security == "reality" {
            server.fingerprint = findWorkingFingerprint(server, override: override,
                                                        using: XrayBridge(),
                                                        log: append)
            persistFingerprint(server)   // чтобы следующий раз не подбирать заново
        }

        // 2) конфиг собирается здесь же, расширение ничего не строит
        do {
            let cfg = try buildXrayConfig(server: server, socksPort: defaultSocksPort,
                                          routeMode: .global, blockAds: false,
                                          logLevel: "warning", geoAssets: false)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
            let tunnel = TunnelConfig(xrayConfigJSON: json, socksPort: defaultSocksPort,
                                      mtu: 1500, tunAddress: "26.26.26.1",
                                      serverName: server.title, logLevel: "warning")
            try await controller.install(config: tunnel, title: server.title)
            try await controller.start()
        } catch {
            state = .error
            append("[!] \(error)")
        }
    }
```

- [ ] **Шаг 2: Проверка round-trip до устройства**

```swift
func test_connect_builds_a_config_the_extension_can_read() throws {
    let server = Server(proto: "vless", address: "a.b", port: 443, uuid: "u")
    let cfg = try buildXrayConfig(server: server, geoAssets: false)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
    let tunnel = TunnelConfig(xrayConfigJSON: json, socksPort: 10808, mtu: 1500,
                              tunAddress: "26.26.26.1", serverName: "тест",
                              logLevel: "warning")
    let restored = try TunnelConfig(providerConfiguration: tunnel.asProviderConfiguration())
    let obj = try JSONSerialization.jsonObject(with: Data(restored.xrayConfigJSON.utf8))
    XCTAssertNotNil((obj as? [String: Any])?["outbounds"])
}
```

- [ ] **Шаг 3:** Опрос статуса раз в секунду, пока туннель поднят: `askStatus()`
  наполняет `logLines` и счётчики. Когда туннель выключен — таймер не крутится.
- [ ] **Шаг 4:** Проверка на устройстве: подключение до рабочего интернета через
  сервер.
- [ ] **Шаг 5:** Коммит.

---

## Фаза 5. Интерфейс (1.5–2 недели)

Тексты, палитра и состав меню берутся из Android-версии (`MainActivity.kt`) и из
**уже написанных** экранов macOS-версии. Ничего нового не придумывается: три
платформы должны выглядеть и называть вещи одинаково.

Соответствие — по одному файлу на задачу, читать оригинал **до** написания
iOS-версии, а не после:

| Задача | Оригинал macOS | Что переносится |
|---|---|---|
| 5.1 | `SCVPNApp/Views/Theme+SwiftUI.swift` | мост `Palette` → `Color`, `BrandmarkShape` |
| 5.2 | `Views/MainView.swift`, `PowerButton.swift`, `ServerRow.swift` | разметка и подписи |
| 5.3 | `Views/MainMenu.swift` | состав меню за вычетом строки 0.1 и раздела 7 спецификации |
| 5.4 | `Views/AddSheet.swift`, `SubscriptionSheet.swift` | целиком |
| 5.5 | `Views/QRScannerView.swift` | `AVCaptureMetadataOutput`, но `UIViewRepresentable` вместо `NSViewRepresentable` |

`HeaderView.swift` и `WindowAccessor.swift` не переносятся: это шапка окна macOS.

### Задача 5.1: Палитра, тема и знак

**Файлы:**
- Create: `core-swift/Sources/SCVPNCore/UI/PaletteSwiftUI.swift`
- Move: `BrandmarkShape` из `desktop/macOS/Sources/SCVPNApp/Views/Theme+SwiftUI.swift`
  → `core-swift/Sources/SCVPNCore/UI/BrandmarkShape.swift`
- Modify: `desktop/macOS/README.md`

Палитры и геометрии знака писать **не надо**: `Palette` и `Brandmark` уже лежат
в `SCVPNCore/Theme.swift`, а `ThemeTests.test_palette_matches_android_colors_xml`
уже сверяет их с Android и работает на обеих платформах (раздел 0.5).

Остаётся два куска SwiftUI, и оба одинаковы для macOS и iOS — они лежат в
`desktop/macOS/Sources/SCVPNApp/Views/Theme+SwiftUI.swift`:

- `extension Color` с `init(hex:)` и восемью `scvpn*`-цветами из `Palette`;
- `BrandmarkShape` (строка 60) — две касающиеся дуги, раскрытие 255°, круглые
  концы. В комментарии там разобрано, почему углы перевёрнуты относительно Qt;
  этот комментарий переезжает вместе с кодом, иначе знак снова выйдет зеркальным.

`extension Font` не переезжает: `Menlo` и размеры — про десктопное окно, iOS
подбирает свои.

Обе кладутся в общий пакет, а не копируются в iOS-таргет: копия знака — это
знак, который через полгода на двух платформах разный.

- [ ] **Шаг 1:** Перенести `BrandmarkShape` и хелпер `Color(hex:)` в
  `core-swift/Sources/SCVPNCore/UI/`, оставив `import SwiftUI` (он есть на обеих
  платформах; AppKit/UIKit в этих файлах быть не должно).
- [ ] **Шаг 2:** Прогнать macOS: `swift test --skip SystemProxyLiveTests` и
  `./build.sh`. Знак в окне обязан выглядеть ровно как раньше — сверять
  скриншотом до и после, а не памятью.
- [ ] **Шаг 3:** Дописать в `desktop/macOS/README.md`, раздел «Общий код с
  Windows»: `BrandmarkShape` и палитра теперь общие для трёх платформ, и знак
  правится в одном месте.
- [ ] **Шаг 4:** Коммит.

### Задача 5.2: Главный экран

**Файлы:**
- Create: `ios/SCVPN/Views/MainView.swift`, `PowerButton.swift`, `ServerRow.swift`

Состав — как `MainActivity.kt`: кнопка питания, статус, список серверов с
пингами, сведения о подписке (срок, трафик), меню «⋯».

Состояния — `ConnectionState` из `SCVPNCore` (раздел 0.5), включая уже готовые
`title` и `ring` (цвет, толщина, пунктир). `.tunStuck` на iOS не производится
никогда: туннель снимает система. Подписи пинга — `pingLabel`, длительность
сессии — `formatUptime`; всё это тоже уже написано и проверено.

- [ ] **Шаги:** каркас, привязка к `AppModel`, ручная проверка, коммит.

### Задача 5.3: Меню и настройки

**Файлы:**
- Create: `ios/SCVPN/Views/MainMenu.swift`, `SettingsSheet.swift`

Из десктопного меню **не переносятся**: режим системного прокси, выбор
приложений для раздельного туннелирования, «Удалить компоненты TUN…»,
обновление ядра. Переносятся: добавить сервер, добавить подписку, обновить
подписки, пинг всех, настройки, О программе.

В настройках: User-Agent подписки, TLS-отпечаток (`auto` или конкретный),
Kill switch (см. Задачу 8.1 — в v1 пункта нет).

- [ ] **Шаги:** реализовать, проверить, что ни один пункт не ведёт в
  неработающую функцию, коммит.

### Задача 5.4: Диалоги добавления

**Файлы:**
- Create: `ios/SCVPN/Views/AddSheet.swift`, `SubscriptionSheet.swift`

- [ ] **Шаги:** ввод ссылки, вставка из буфера, разбор `LinkParser`, показ
  ошибки `SubscriptionError` целиком (её тексты уже написаны и объясняют
  пользователю, что делать), коммит.

### Задача 5.5: QR

**Файлы:**
- Create: `ios/SCVPN/Views/QRScannerView.swift`, `QRCodeImage.swift`

Сканирование — `AVCaptureSession` + `AVCaptureMetadataOutput` с типом `.qr`.
Генерация — `CIFilter.qrCodeGenerator()`. Сторонних зависимостей нет.

- [ ] **Шаги:** реализовать, проверить на устройстве (в симуляторе камеры нет),
  коммит.

### Задача 5.6: Иконка приложения

**Файлы:**
- Create: `ios/SCVPN/Assets.xcassets/AppIcon.appiconset/*`

Знак уже общий (Задача 5.1). Остаётся иконка: она генерируется из той же
геометрии (`Brandmark` + `BrandmarkShape`), а не рисуется заново — иначе
приложение и его иконка разъедутся.

- [ ] **Шаг 1:** Скрипт рендера `BrandmarkShape` в PNG нужных размеров
  (`ImageRenderer` в SwiftUI, macOS-цель, запуск разово).
- [ ] **Шаг 2:** Сложить в `AppIcon.appiconset`, проверить на устройстве.
- [ ] **Шаг 3:** Коммит.

---

## Фаза 6. Сборка и раздача (2–3 дня)

### Задача 6.1: Скрипт сборки

**Файлы:**
- Create: `ios/build.sh`

```bash
#!/bin/bash
# Сборка SCVPN.ipa. LibXray.xcframework в репозитории нет — см. ios/README.md.
set -euo pipefail
cd "$(dirname "$0")"

[ -d Frameworks/LibXray.xcframework ] || {
  echo "[!] Нет Frameworks/LibXray.xcframework — собери его, см. README"; exit 1; }

xcodebuild -project SCVPN.xcodeproj -scheme SCVPN \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/SCVPN.xcarchive archive

xcodebuild -exportArchive -archivePath build/SCVPN.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/ipa
```

- [ ] **Шаг 1:** Скрипт + `ExportOptions.plist` под выбранный в Задаче 0.1
  способ раздачи (`development`, `ad-hoc` или `app-store` для TestFlight).
- [ ] **Шаг 2:** Прогнать целиком с нуля на чистом клоне.
- [ ] **Шаг 3:** Коммит.

### Задача 6.2: Документация

**Файлы:**
- Create: `ios/README.md`
- Modify: `README.md` (корневой)

`ios/README.md` обязан содержать:

- как собрать `LibXray.xcframework` и куда его положить;
- какой способ подписи выбран и что из этого следует (срок жизни сборки: 7 дней
  / 1 год / 90 дней);
- почему нет режима системного прокси, раздельного туннелирования по
  приложениям, обновления ядра и (в v1) режима «Обход РФ» — со ссылкой на
  разделы спецификации, а не «так вышло»;
- ручная проверка: как убедиться, что трафик действительно идёт через сервер
  (`https://api.ipify.org` до и после).

Корневой README: строка про iOS в таблице платформ и подтверждение, что
телеметрии нет и на iOS.

- [ ] **Шаги:** написать, вычитать, коммит.

---

## Фаза 7. Проверка на устройстве (2–3 дня)

Симулятор не годится ни для одного пункта. Результат каждого — в таблицу
Приложения Г, включая отрицательный.

### Задача 7.1: Чек-лист

- [ ] Подъём и снятие туннеля десять раз подряд.
- [ ] Трафик действительно идёт через сервер: `api.ipify.org` показывает IP
  сервера, а не провайдера.
- [ ] Приложение свёрнуто, экран заблокирован 10 минут — туннель жив.
- [ ] Приложение убито свайпом — туннель жив (это отдельное свойство iOS,
  которого нет у macOS-версии: там смерть приложения снимает туннель).
- [ ] Перезагрузка устройства — туннель снят, приложение поднимается в
  состоянии «выключено», а не «подключено».
- [ ] Авиарежим 30 секунд и обратно.
- [ ] Wi-Fi → LTE на живом туннеле.
- [ ] Час непрерывной работы: `phys_footprint` в конце не выше, чем в начале
  плюс 2 МБ.
- [ ] Расширение убито по памяти намеренно — интернет на устройстве работает,
  битого туннеля не осталось (повтор Задачи 0.6 на настоящем расширении).
- [ ] Переустановка приложения — HWID тот же (Keychain, Задача 4.1). Проверять
  **до** удаления приложения записать значение, после переустановки сверить.
- [ ] Подписка с лимитом устройств не занимает второй слот после переустановки.

### Задача 7.2: Исход

- [ ] **Шаг 1:** Каждый провалившийся пункт — либо задача с номером, либо
  честная строка в `ios/README.md`. Третьего варианта («потом посмотрим») нет.
- [ ] **Шаг 2:** Коммит документации.

---

## Фаза 8. После v1 — по одному решению за раз

Ничего из этой фазы не делается, пока Фаза 7 не закрыта.

### Задача 8.1: Kill switch и автоподключение

`includeAllNetworks = true` даёт «без туннеля нет интернета», `NEOnDemandRule`
— автоподключение. Обе ручки — одна строка каждая, но обе меняют поведение
устройства целиком, и обе способны запереть пользователя без сети. Поэтому:
пункт в настройках, выключено по умолчанию, текст объясняет последствие.
`includeAllNetworks` дополнительно требует перепроверить петлю (Задача 0.5).

### Задача 8.2: Возврат режима «Обход РФ»

Урезанные гео-базы в бандле: только `category-ru`, `yandex`, `vk`, `mailru`,
`geoip:ru`, `private`. Собираются из полных баз скриптом, кладутся в бандл
приложения, путь передаётся ядру. Обязательное условие — повторный замер памяти
из Задачи 3.7 с теми же критериями.

### Задача 8.3: Счётчик трафика

`TunnelBridge.stats()` уже отдаёт байты (Задача 3.3), в `ProviderStatus` они
уже едут. Вопрос только в том, показывать ли: на macOS и Windows такого
счётчика нет. Решение — показывать, единообразие платформ не стоит выброшенной
даром функции; но принять его надо явно, а не по факту наличия поля.

---

## Приложение А. Инварианты спецификации → проверки

| № | Инвариант (спец., раздел 9) | Проверка | Задача |
|---|---|---|---|
| 1 | Формат `profiles.json` и `settings.json` | `RealProfilesTests`, `test_ios_keeps_desktop_only_keys` | 1.1, 4.2 |
| 2 | Контракт HWID: соль, SHA-256, UUID, заголовки | `test_hwid_looks_like_uuid`, `test_headers_are_exactly_four_and_named_as_the_panel_expects` | 4.1 |
| 2 | HWID переживает переустановку | `test_machine_source_survives_container_wipe` + ручная проверка Фазы 7 | 4.1, 7.1 |
| 3 | Порядок правил маршрутизации | `test_rule_order_is_unchanged` | 4.4 |
| 4 | Схемы ссылок `vless/vmess/trojan/ss` и подписки | `LinkParserTests`, `SubscriptionTests` в iOS-таргете | 4.3 |
| 5 | User-Agent `v2rayNG/1.9.5` | `SubscriptionTests` | 4.3 |
| 6 | Никакой телеметрии | ревизия сетевых вызовов в Задаче 6.2 | 6.2 |
| 7 | Сторонние бинарники не коммитятся | `ios/.gitignore`, проверка на чистом клоне | 2.1, 6.1 |

Найдено сверх списка спецификации:

| № | Инвариант | Проверка | Задача |
|---|---|---|---|
| 8 | Конфиг для iOS не ссылается на гео-базы **ни в одном режиме** | `test_ios_config_has_no_geo_references` | 4.4 |
| 9 | Приватные подсети остаются прямыми и без гео-баз | `test_ios_config_still_keeps_private_networks_direct` | 4.4 |
| 10 | `providerConfiguration` состоит только из plist-типов | `test_provider_configuration_holds_only_plist_types` | 3.1 |
| 11 | Ошибка на любом шаге старта снимает всё предыдущее | ручная проверка, Задача 3.4, шаг 2 | 3.4 |
| 12 | Кольцевой лог имеет потолок | `test_ring_log_keeps_only_the_last_lines` | 3.5 |
| 13 | Режим, который не работает, не показывается в меню | ревизия меню, Задача 5.3 | 5.3 |
| 14 | Палитра совпадает с Android | `ThemeTests.test_palette_matches_android_colors_xml` — **уже написана**, после Фазы 1 гоняется и на iOS | 1.2 |
| 15 | Состояния экрана и подписи пинга одни на все платформы | `ConnectionStateTests` — **уже написаны** | 1.2, 5.2 |

№8 — не украшение: без гео-баз сегодняшний конфиг не стартует **в глобальном
режиме тоже**, потому что `geoip:private` стоит в правилах всегда. Это самая
дорогая находка переноса, и она обнаруживается чтением
`XrayConfigBuilder.swift`, а не запуском на устройстве.

№10 — свойство, которого нет ни на одной другой платформе: там конфиг едет
файлом или сокетом, здесь — через системное хранилище настроек VPN, которое
молча теряет не-plist значения. Потеря выглядит как «расширение не видит
конфига», а не как ошибка сериализации.

---

## Приложение Б. Ответы на открытые вопросы спецификации (раздел 12)

| № | Вопрос | Ответ этого плана |
|---|---|---|
| 1 | TrollStore и NE-расширения | Задача 0.1, шаг 5. Отрицательный результат — бесплатного пути нет |
| 2 | Сколько памяти ест Xray в расширении | Задача 0.4: шесть замеров, критерий 40 МБ. Повтор в Задаче 3.7 на настоящем расширении |
| 3 | libXray: gomobile или go/FFI | gomobile (Задача 0.2). Смена меняет один файл — фасад `XrayBridge` (раздел 0.3) |
| 4 | Режим «Обход РФ» на iOS | **В v1 нет** (раздел 0.1). Возврат — Задача 8.2, после повторного замера памяти |
| 5 | Минимальная версия iOS | 16.0, зафиксировано в Global Constraints |
| 6 | Kill switch | В v1 нет, решение принято осознанно. Задача 8.1 описывает, как включить и чем это грозит |
| 7 | Счётчик трафика | Собирается с Задачи 3.3, показывается по решению Задачи 8.3 |

---

## Приложение В. Реестр рисков

| Риск | Признак | Что делать |
|---|---|---|
| Пик памяти расширения выше 40 МБ | Задача 0.4 | Урезать буферы `hev` (Задача 3.3), затем форк libXray с `debug.SetMemoryLimit`. Не помогло — проект не идёт дальше Фазы 0 |
| Entitlement недоступен | Задача 0.1 | Предусловие, а не риск: путь A или проект закрыт |
| KVC-доступ к дескриптору отвалился | Задача 0.5 / обновление iOS | Запасной путь — `readPackets`/`writePackets` + сокет-пара. Обёрнуто в одном месте (Задача 3.3) |
| Петля: трафик ядра идёт в свой же туннель | Задача 0.5, шаг 3 | Нулевая скорость при живом ядре. Проверять до Фазы 3, повторить при включении `includeAllNetworks` (Задача 8.1) |
| Утечка памяти в libXray при повторных стартах | Задача 3.2, шаг 3 | Не поднимать и не гасить ядро в цикле; при пинге — ограничение параллельности (Задача 4.5) |
| Расхождение `core-swift` с Python-версиями | постоянный | Правило парных правок живёт в `desktop/macOS/README.md`, раздел «Общий код с Windows» (карта соответствия удалена в `ab91a65`, суть перенесена туда). Фаза 1, шаг 7 меняет в нём адрес общего кода и добавляет третьего потребителя |
| Пути `#filePath` в проверках после переезда | Задача 1.1, шаги 3–4 | `ThemeTests` ходит по репозиторию от своего файла и после переезда падает. Проверять `grep`, а не глазами: появится вторая такая проверка — сломается так же |
| Срок жизни профиля подписи | раздача | Организационная беда. Записать срок в `ios/README.md` (Задача 6.2), чтобы он не выяснялся в день, когда сборка перестала запускаться |
| Xcode-проект правится руками | любой конфликт в `project.pbxproj` | Все правки таргетов — только через Xcode. Конфликт слияния в `.pbxproj` разрешается повторным добавлением файла, а не редактированием |

---

## Приложение Г. Факты с устройства (заполняется в Фазе 0 и Фазе 7)

| Что | Значение | Когда |
|---|---|---|
| Путь подписи (A/B) | | 0.1 |
| Устройство и версия iOS | | 0.1 |
| NE-расширение стартует | | 0.1 |
| TrollStore: NE работает | | 0.1 |
| Версия libXray / Xray-core | | 0.2 |
| Xray стартует в расширении | | 0.3 |
| Память: после старта ядра | | 0.4 |
| Память: после подъёма моста | | 0.4 |
| Память: под нагрузкой 50 Мбит | | 0.4 |
| Память: 30 минут под нагрузкой | | 0.4 |
| Память: то же с гео-базами | | 0.4 |
| Дескриптор туннеля: публично / KVC | | 0.5 |
| Петли нет | | 0.5 |
| Смерть по памяти не оставляет битого туннеля | | 0.6 |
| Память настоящего расширения под нагрузкой | | 3.7 |
| Час работы: рост footprint | | 3.7, 7.1 |
| HWID пережил переустановку | | 7.1 |

---

## Приложение Д. Фактический API LibXray

**Заполняется в Задаче 0.2, шаг 3.** До заполнения `XrayBridge` не пишется.

| Операция | Сигнатура из заголовка | Формат аргумента | Формат ответа |
|---|---|---|---|
| Запуск ядра с конфигом | | | |
| Остановка | | | |
| Замер задержки | | | |
| Каталог гео-баз | | | |

Ниже — дословная выдержка из `LibXray.objc.h` (или эквивалента), чтобы не
пересобирать фреймворк ради одной сигнатуры:

```objc
// вставить сюда
```
