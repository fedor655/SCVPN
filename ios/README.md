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

## Что уже работает

- добавление сервера ссылкой (`vless://`, `vmess://`, `trojan://`, `ss://`),
  вставкой из буфера и сканированием QR (камера — только на устройстве);
- подписки: загрузка, обновление, удаление, заголовки `x-hwid` и остальные три;
- список серверов с TCP-пингом, выбор сервера;
- хранилище `profiles.json` и `settings.json` в контейнере приложения, формат
  тот же, что на macOS и Windows;
- HWID: источник в Keychain, поэтому он переживает переустановку приложения.

## Чего ещё нет

**Туннель не поднимается.** Не хватает двух сторонних кусков, которые в
репозиторий не кладутся:

1. `LibXray.xcframework` — само ядро. Собирается из
   [XTLS/libXray](https://github.com/XTLS/libXray):

   ```bash
   git clone https://github.com/XTLS/libXray && cd libXray
   python3 build/main.py apple gomobile     # нужен Go
   ```

   Результат положить в `ios/Frameworks/LibXray.xcframework` и добавить в
   `project.yml`. Пока фреймворка нет, `XrayBridge` честно отказывается
   запускать ядро, а не делает вид, что туннель поднят.

2. `Tun2SocksKit` — обёртка над `hev-socks5-tunnel` (та же библиотека, что на
   Android). Добавляется пакетом в `project.yml` к таргету `PacketTunnel`.

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
