# SCVPN для iOS

Нативный клиент на SwiftUI. Общая логика — пакет `core-swift/` (тот же, что у
macOS-версии), туннель — расширение `PacketTunnel` на `NEPacketTunnelProvider`.

## Сборка и запуск

```bash
brew install xcodegen        # один раз
cd ios && xcodegen generate  # пересобрать SCVPN.xcodeproj из project.yml
open SCVPN.xcodeproj
```

`SCVPN.xcodeproj` в репозиторий не коммитится: `project.pbxproj` — машинный файл
с UUID-ключами на тысячи строк, его не правит надёжно ни человек, ни агент, а
конфликт слияния в нём неразрешим. Источник правды — `project.yml`.

Прогон проверок общего кода под iOS:

```bash
cd core-swift && xcodebuild test -scheme SCVPNCore -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## Ядро Xray

Ядро в репозиторий не кладётся — это 312 МБ сторонних бинарников. Скачать
готовую сборку (Go для этого не нужен):

```bash
curl -sSL -o /tmp/libxray.zip \
  https://github.com/XTLS/libXray/releases/latest/download/libxray-apple-cgo.zip
unzip -q /tmp/libxray.zip -d /tmp/libxray
cp -R /tmp/libxray/libxray-apple-cgo/LibXray.xcframework ios/Frameworks/
```

Три вещи, которые стоит знать до того, как что-то сломается:

- **Берётся вариант `cgo`, а не `gomobile`.** У gomobile-сборки в релизах нет,
  её пришлось бы собирать самому, а для этого нужен Go. У cgo-сборки API — две
  функции C (`CGoInvoke`, `CGoFree`), и этого достаточно.
- **Ядро завёрнуто в свой фреймворк `LibXrayKit`.** Иначе Xcode копирует
  заголовки статической библиотеки в общий каталог `include`, туда же кладёт
  свои `hev-socks5-tunnel`, и сборка падает на «Multiple commands produce
  .../include/module.modulemap». Обёртка объявляет две C-функции сама и
  линкует библиотеку флагами, так что чужие заголовки в сборку не попадают.
- **Номер версии API libXray меняется от сборки к сборке.** `XrayBridge`
  определяет её при первом вызове перебором и пробует оба поколения имён полей
  (`xrayJson` / `configJSON`). Проверить, что ядро отвечает, можно на экране
  настроек: строка «Xray» показывает его версию или причину отказа.

Без фреймворка приложение собирается и работает, но туннель честно
отказывается подниматься, а автоподбор отпечатка недоступен.

## Что уже работает

- добавление сервера ссылкой (`vless://`, `vmess://`, `trojan://`, `ss://`),
  вставкой из буфера и сканированием QR (камера — только на устройстве);
- подписки: загрузка, обновление, удаление, заголовки `x-hwid` и остальные три;
- список серверов с TCP-пингом, выбор сервера;
- хранилище `profiles.json` и `settings.json` в контейнере приложения, формат
  тот же, что на macOS и Windows;
- HWID: источник в Keychain, поэтому он переживает переустановку приложения.

## Чего ещё нет

**В симуляторе туннель не проверить вообще.** NetworkExtension там не работает —
это ограничение платформы, а не сборки. Всё, что касается туннеля, проверяется
на физическом устройстве, и для этого нужен профиль подписи с entitlement
`com.apple.developer.networking.networkextension` (Apple Developer Program).

## Чего не будет

- **режим системного прокси** — на iOS его не существует;
- **раздельное туннелирование по приложениям** — per-app VPN только через
  MDM-профиль;
- **обновление ядра без обновления приложения** — iOS не запускает скачанные
  бинарники, ядро вшито в бандл;
- **режим «Обход РФ» и блокировка рекламы** — держатся на гео-базах
  (`geoip.dat`, `geosite.dat`), а расширение туннеля живёт в лимите 50 МБ, куда
  они не помещаются. Поэтому конфиг для iOS собирается с `geoAssets: false`, и
  приватные подсети выписаны явным списком вместо `geoip:private`.

Подробности и обоснования — [docs/ios-port-plan.md](../docs/ios-port-plan.md) и
[docs/ios-implementation-plan.md](../docs/ios-implementation-plan.md).

## Общий код

`core-swift/Sources/SCVPNCore/` — один пакет на macOS и iOS. Платформенное
разделено `#if os(macOS)` / `#if os(iOS)`, а не двумя деревьями файлов: копии
расходятся молча. Правка логики в `desktop/shared/` (Python, Windows) по-прежнему
требует парной правки здесь — см. `desktop/macOS/README.md`, раздел «Общий код
с Windows».
