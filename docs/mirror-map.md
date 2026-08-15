# Карта соответствия: Python ↔ Swift

**Зачем этот файл.** До переписывания `desktop/shared/` был один код на Windows
и macOS: парсеры ссылок и подписок, модели, конфиг Xray, хранилище, интерфейс.
Теперь macOS живёт на Swift, и **каждая правка логики делается дважды**. Это не
разовая цена, а постоянный налог: со временем реализации разойдутся молча, и
заметит это пользователь, а не автор правки.

Правило простое:

> Правка в `desktop/shared/` требует парной правки в
> `desktop/MacOS-Swift/Sources/SCVPNCore/`. Правка в `desktop/MacOS/helper/` —
> парной в `Sources/SCVPNHelperKit/`.

Ниже — что чему соответствует. Если файла нет в паре, это отмечено явно: значит
поведение либо переехало, либо исчезло осознанно.

## Общая логика

| Python | Swift | Заметки |
|---|---|---|
| `shared/models.py` | `SCVPNCore/Models/Server.swift` | `protocol` → поле `proto`, ключ на диске прежний |
| `shared/storage.py` | `SCVPNCore/Storage/Store.swift`, `Models/Subscription.swift` | настройки — словарь, не структура |
| `shared/subinfo.py` | `SCVPNCore/Models/SubscriptionInfo.swift` | |
| `shared/subscription.py` | `SCVPNCore/Parsing/LinkParser.swift`, `SubscriptionFetcher.swift`, `Base64.swift` | |
| `shared/xray_config.py` | `SCVPNCore/XrayConfig/XrayConfigBuilder.swift` | порядок правил маршрутизации значим |
| `shared/core_runner.py` | `SCVPNCore/XrayRunner.swift`, `TCPPing.swift` | |
| `shared/ping.py` | `SCVPNCore/TCPPing.swift` | неблокирующий `connect` + `poll` вместо `settimeout` |
| `shared/connect.py` | `SCVPNCore/FingerprintProbe.swift` | проба через `/usr/bin/curl -x`, не `URLSession` |
| `MacOS/native/paths.py` | `SCVPNCore/Paths.swift` | нет вилки «из исходников / собранное» |
| `MacOS/native/hwid.py` | `SCVPNCore/HWID.swift` | IOKit напрямую вместо разбора `ioreg` |
| `MacOS/native/sysproxy.py` | `SCVPNCore/SystemProxy.swift` | |
| `MacOS/native/downloader.py` | `SCVPNCore/CoreDownloader.swift` | распаковка `/usr/bin/unzip` |
| `MacOS/native/tun.py` | `SCVPNCore/HelperClient.swift`, `Tun.swift` | |
| `MacOS/native/apps.py` | `SCVPNCore/RunningApps.swift` | `NSWorkspace` вместо разбора `ps` |
| `MacOS/helper/config.py` | `SCVPNCore/SingboxConfig/Validation.swift`, `Builder.swift` | |
| `MacOS/helper/daemon.py` | `SCVPNHelperKit/` целиком | разнесён по файлам по ответственностям |
| `MacOS/helper/install.py` | `SCVPNCore/HelperInstaller.swift`, `LegacyHelper.swift` | `SMAppService` вместо osascript |

## Интерфейс

| Python | Swift | Заметки |
|---|---|---|
| `shared/ui/theme.py` | `SCVPNCore/Theme.swift`, `SCVPNApp/Views/Theme+SwiftUI.swift` | палитра строками в Core, чтобы сверяться с Android |
| `shared/ui/brandmark.py` | `SCVPNApp/Views/Theme+SwiftUI.swift` (`BrandmarkShape`) | углы перевёрнуты обратно из Qt в PIL-систему |
| `shared/ui/widgets.py` | `SCVPNApp/Views/PowerButton.swift`, `ServerRow.swift`, `SCVPNCore/ConnectionState.swift` | состояния и подписи пинга вынесены в Core |
| `shared/ui/main_window.py` | `SCVPNApp/AppModel.swift`, `Views/MainView.swift`, `MainMenu.swift`, `HeaderView.swift` | |
| `shared/ui/add_dialog.py` | `SCVPNApp/Views/AddSheet.swift` | |
| `shared/ui/split_dialog.py` | `SCVPNApp/Views/SplitTunnelSheet.swift` | |
| `shared/ui/subscription_dialog.py` | `SCVPNApp/Views/SubscriptionSheet.swift` | |
| `shared/ui/qr_scanner.py` | `SCVPNApp/Views/QRScannerView.swift` | `AVCaptureMetadataOutput`, opencv не нужен |
| `shared/ui/workers.py` | — | `Task` и `@Published`, отдельного типа нет |
| `MacOS/native/titlebar.py` | `SCVPNApp/Views/WindowAccessor.swift` | AppKit напрямую вместо `ctypes` |

## Чего в Swift-версии нет намеренно

| Что | Почему |
|---|---|
| `paths.HELPER_CODE_DIR` | код демона внутри бандла, копировать некуда |
| `/Library/LaunchDaemons/com.scvpn.helper.plist` | plist едет в бандле, ставит `SMAppService` |
| Проверка расположения бандла (TCC) | Фаза 0 показала: ограничения нет, баг был свойством способа запуска |
| `opencv-python-headless`, `qrcode` | заменены на `AVFoundation` и `CoreImage` |

## Что проверками **не** прикрыто

Три проверки Python-версии сверяли контракт между платформами интроспекцией
модулей: `test_tun_contract_matches_windows`,
`test_native_contract_covers_both_platforms`,
`test_tun_stop_returns_bool_on_both_platforms`. После разделения языков держать
этот контракт нечем — интроспекция Python не видит Swift.

Значит расхождение реализаций поймает только этот файл и внимательность автора
правки. Если появится способ проверять контракт автоматически (сверка форматов
на диске общими фикстурами, например) — это лучшее вложение времени из
доступных.

## Общие форматы, которые обязаны совпадать побайтно

Их расхождение — не «разные реализации», а испорченные данные пользователя:

- `profiles.json` — имена ключей `Server`, включая `protocol`, `alter_id`,
  `public_key`, `short_id`, `spider_x`, `allow_insecure`, `ws_path`, `ws_host`,
  `grpc_service`;
- `settings.json` — имена и умолчания, включая `hwid` и неизвестные ключи,
  которые обязаны переживать круг чтение-запись;
- `Server.key()` — формат `протокол://секрет@адрес:порт/сеть/безопасность`,
  он лежит в `settings.json` как `selected_key`;
- HWID — соль `scvpn-hwid-v1` и формат UUID из хеша: смена любого означает новый
  слот в лимите устройств у каждого пользователя;
- протокол сокета демона целиком;
- палитра — она же в `android/app/src/main/res/values/colors.xml`, сверяется
  проверкой `test_palette_matches_android_colors_xml`.
