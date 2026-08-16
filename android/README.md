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

Windows:

```powershell
build_apk.bat
# APK: app\build\outputs\apk\debug\app-debug.apk
```

macOS и Linux:

```bash
./build_apk.sh
```

Путь к APK печатает сам скрипт. **На macOS каталог сборки лежит вне проекта**
(`~/Library/Caches/scvpn-android/`): репозиторий часто живёт в `~/Documents`,
а её синхронизирует iCloud — он плодит внутри `build/` копии вроде
`MainActivity$ServerAdapter 2.dex`, и сборка падает с «Type is defined multiple
times». На Windows и Linux каталог прежний, `app/build/`.

Что нужно на macOS (всё ставится один раз):

```bash
brew install gradle openjdk@21
brew install --cask android-commandlinetools
export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-34" "build-tools;34.0.0"
```

**Нужен именно JDK 21**: AGP 8.6 на JDK 25 не работает, а он в системе может
быть по умолчанию. Скрипт ищет 21-й сам и отказывается, если не нашёл.

Windows-скрипт берёт JDK от Android Studio (JBR 21) и Gradle с `D:\gradle`;
если пути другие — поправь их в `build_apk.bat` или собери из Android Studio.

### Релизная сборка

`assembleRelease` подписывает APK ключом, описанным в `keystore.properties`
(в git не попадает — там пароли):

```properties
storeFile=scvpn-release.jks
storePassword=...
keyAlias=scvpn
keyPassword=...
```

Файл должен быть **без BOM**, иначе первый ключ прочитается как `\ufeffstoreFile`
и сборка упадёт с `path may not be null`. Свой ключ создаётся так:

```powershell
keytool -genkeypair -v -keystore scvpn-release.jks -alias scvpn `
  -keyalg RSA -keysize 4096 -validity 10950
```

Без `keystore.properties` release соберётся неподписанным — установить такой APK
нельзя, но сборка не сломается.

Отличие от debug по существу одно: в release нет `android:debuggable`, то есть к
работающему VPN нельзя подцепиться отладчиком. Обфускация выключена намеренно —
смысл проекта в том, что код видно.

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
PNG в `res/mipmap-*/` нужны только для Android 7 (API 24-25). Они лежат в git
готовыми (mdpi 48 … xxxhdpi 192), Gradle их не генерирует и скрипта, который
их рисует, в проекте нет — знак перерисовывают руками, когда меняется
геометрия.
