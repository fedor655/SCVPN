# SCVPN для Android

Общее описание проекта и разбор архитектуры — в [README репозитория](../README.md).

## Что нужно доложить перед сборкой

Бинарников в репозитории нет (они большие, а два из трёх ещё и не наши):

| Файл | Куда положить | Откуда взять |
|---|---|---|
| `libv2ray.aar` (~58 МБ) | `app/libs/` | сборка [2dust/AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite) — внутри Xray-core как Go-библиотека (`libgojni.so`) и гео-базы |
| `libhev-socks5-tunnel.so` × 4 ABI | `app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}/` | [heiher/hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) (MIT), готовые лежат в APK [v2rayNG](https://github.com/2dust/v2rayNG) |
| `libscvpnawg.so` × 4 ABI | `app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}/` | собирается из `awg/` этого же репозитория (см. ниже) — AmneziaWG как локальный SOCKS5 |

⚠️ `.so` обязан оставаться доступным по имени класса
`com.v2ray.ang.service.TProxyService` — под это имя он собран, `RegisterNatives`
внутри библиотеки ищет именно этот путь. Поэтому один класс проекта живёт в
чужом пакете, а не в `com.scvpn`.

### `libscvpnawg.so` — AmneziaWG

Это не библиотека, а программа: `scvpn-awg` поднимает туннель AmneziaWG и
отдаёт его как SOCKS5 на `127.0.0.1`, а Xray ходит в этот порт обычным
socks-выходом (`AwgProcess.kt`). Отдельный процесс обязателен — внутри
приложения уже живёт Go-среда из `libv2ray.aar`, а две среды Go в одном
процессе не уживаются.

Имя `lib*.so` и каталог `jniLibs` — не маскировка, а единственный способ:
с Android 10 запускать файлы можно только из каталога нативных библиотек, куда
попадает лишь то, что система считает библиотекой. Отсюда же
`android:extractNativeLibs="true"` в манифесте.

Сборка (нужен Go 1.25+; кросс-компиляция идёт с любой машины):

```bash
cd awg
NDK="$ANDROID_HOME/ndk/<версия>"
TOOL="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"   # на Linux — linux-x86_64
JNI=../android/app/src/main/jniLibs

CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=$TOOL/aarch64-linux-android24-clang \
  go build -trimpath -o $JNI/arm64-v8a/libscvpnawg.so
CGO_ENABLED=1 GOOS=android GOARCH=arm   CC=$TOOL/armv7a-linux-androideabi24-clang \
  go build -trimpath -o $JNI/armeabi-v7a/libscvpnawg.so
CGO_ENABLED=1 GOOS=android GOARCH=386   CC=$TOOL/i686-linux-android24-clang \
  go build -trimpath -o $JNI/x86/libscvpnawg.so
CGO_ENABLED=1 GOOS=android GOARCH=amd64 CC=$TOOL/x86_64-linux-android24-clang \
  go build -trimpath -o $JNI/x86_64/libscvpnawg.so
```

`24` в имени компилятора — это `minSdk` проекта, он же уровень API. NDK нужен
не ради C, а ради компоновщика: без него Go отказывается собирать `android`
для всех архитектур, кроме `arm64` (её одну можно собрать и так —
`CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build`).

Проверить, что получилась именно программа для Android, можно по загрузчику:

```bash
file app/src/main/jniLibs/arm64-v8a/libscvpnawg.so
# ELF ... pie executable, ARM aarch64 ... interpreter /system/bin/linker64
```

`interpreter /lib/ld-linux-*` вместо `/system/bin/linker64` значит, что собрано
под обычный Linux (`GOOS=linux`): на телефоне такой файл не запустится — этого
загрузчика там нет.

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
| `AwgProcess.kt` | запуск `libscvpnawg.so` отдельным процессом: AmneziaWG → SOCKS5 |
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
