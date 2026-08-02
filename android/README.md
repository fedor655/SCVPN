# SCVPN для Android

Общее описание проекта и разбор архитектуры — в [README репозитория](../README.md).

## Что нужно доложить перед сборкой

Двух сторонних бинарников в репозитории нет (они большие и не наши):

| Файл | Куда положить | Откуда взять |
|---|---|---|
| `libv2ray.aar` (~58 МБ) | `app/libs/` | сборка [2dust/AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite) — внутри Xray-core как Go-библиотека (`libgojni.so`) и гео-базы |
| `libhev-socks5-tunnel.so` × 4 ABI | `app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}/` | [heiher/hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) (MIT), готовые лежат в APK [v2rayNG](https://github.com/2dust/v2rayNG) |

⚠️ `.so` обязан оставаться доступным по имени класса
`com.v2ray.ang.service.TProxyService` — под это имя он собран, `RegisterNatives`
внутри библиотеки ищет именно этот путь. Поэтому один класс проекта живёт в
чужом пакете, а не в `com.scvpn`.

Ещё нужен `local.properties` с путём к SDK (в git не попадает):

```properties
sdk.dir=C:/Users/<ты>/AppData/Local/Android/Sdk
```

## Сборка

```powershell
build_apk.bat
# APK: app\build\outputs\apk\debug\app-debug.apk
```

Скрипт берёт JDK от Android Studio (JBR 21) и Gradle с `D:\gradle`. Если у тебя
пути другие — поправь их в `build_apk.bat` или собери из Android Studio.

## Структура

| Файл | За что отвечает |
|---|---|
| `MainActivity.kt` | единственный экран: кнопка, статус, список серверов |
| `ScVpnService.kt` | `VpnService`: TUN → hev-мост → Xray |
| `XrayCore.kt` | обёртка над ядром: старт, стоп, замер задержки, подбор отпечатка |
| `XrayConfig.kt` | сборка конфига Xray (SOCKS-инбаунд + outbound сервера) |
| `SubscriptionParser.kt` | разбор ссылок и подписок |
| `Model.kt` | модель `Server` |
| `Prefs.kt` | хранение серверов, выбора и пингов |
| `VpnState.kt` | состояние туннеля и его рассылка в экран |
| `v2ray/ang/service/TProxyService.kt` | JNI-обёртка над hev-socks5-tunnel |

## Иконки

Основная — векторная адаптивная: `res/mipmap-anydpi-v26/ic_launcher.xml`
(фон `@color/ic_launcher_background` + `res/drawable/ic_launcher_foreground.xml`).
PNG в `res/mipmap-*/` нужны только для Android 7 (API 24-25) и генерируются
общим с десктопом кодом:

```powershell
python make_launcher_icons.py
```

Скрипт сам найдёт `brand.py` в `../desktop/setup/`.
