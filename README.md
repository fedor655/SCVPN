# SCVPN

Прозрачный VPN-клиент поверх открытого ядра [Xray-core](https://github.com/XTLS/Xray-core).
Делает то же, что Happ / v2rayTun (подписки, VLESS+Reality и др.), но весь код
обёртки открыт и лежит здесь — видно, что и куда уходит.

| | |
|---|---|
| **Windows** | `desktop/` — Python + PySide6, ядро `xray.exe` рядом |
| **Android** | `android/` — Kotlin, то же ядро внутри процесса (`libv2ray.aar`) |
| **iOS** | пока нет, в планах |

## Что приложение отправляет в сеть (и больше ничего)

1. **Подписку** — запрос на твой URL подписки, только когда ты нажал «Обновить».
2. **VPN-трафик** — через выбранный тобой сервер; этим занимается ядро Xray.
3. **Скачивание ядра** (только Windows) — один раз тянет `xray.exe` + гео-базы с
   официального GitHub (XTLS/Xray-core), а для TUN — `sing-box` (SagerNet) и
   `wintun.dll` (wintun.net).
4. **Проверку соединения** — при автоподборе отпечатка короткий запрос через
   твой же сервер (`api.ipify.org` на Windows, `gstatic.com/generate_204` на Android).

Никакой аналитики, телеметрии, «домашних» серверов и автообновлений нет.
Каждый сетевой вызов видно в коде: `desktop/scvpn/subscription.py`,
`downloader.py`, `connect.py`; `android/.../SubscriptionParser.kt`, `XrayCore.kt`.

---

## Архитектура

Обе версии устроены одинаково: **приложение не шифрует трафик само** — это
делает Xray. Наша задача — разобрать ссылки, собрать ядру конфиг, запустить его
и завернуть в него системный трафик. Отсюда и деление на слои.

```
ссылка/подписка → модель Server → конфиг Xray (JSON) → ядро → сервер
                                                        ↑
                                          системный трафик заводится сюда
```

### Общие слои (одни и те же на обеих платформах)

| Слой | Windows | Android |
|---|---|---|
| Разбор ссылок и подписок | `scvpn/subscription.py` | `SubscriptionParser.kt` |
| Модель сервера | `scvpn/models.py` | `Model.kt` |
| Сборка конфига Xray | `scvpn/xray_config.py` | `XrayConfig.kt` |
| Хранение профилей | `scvpn/storage.py` (JSON в `data/`) | `Prefs.kt` (SharedPreferences) |

Разбор ссылок покрывает `vless://`, `vmess://`, `trojan://`, `ss://` и подписки
(обычный список или base64). Модель `Server` — плоский набор полей ссылки;
из неё собирается секция `outbounds` конфига.

### Чем платформы отличаются — тем, как трафик попадает в ядро

**Windows** (`desktop/`) — ядро отдельным процессом, два способа завести трафик:

```
                    ┌── режим «прокси» ──────────────────────────┐
приложения ─────────┤ системный прокси Windows (реестр)          │
                    │        ↓ 127.0.0.1:HTTP                    │
                    │   xray.exe ── inbound socks+http           │──→ сервер
                    └────────────────────────────────────────────┘

                    ┌── режим «TUN» (нужен админ) ───────────────┐
весь трафик ОС ─────┤ wintun-адаптер ← sing-box.exe              │
                    │        ↓ 127.0.0.1:SOCKS                   │
                    │   xray.exe                                 │──→ сервер
                    └────────────────────────────────────────────┘
```

- `core_runner.py` — запускает и глушит `xray.exe`, читает его лог;
- `sysproxy.py` — правит ключи системного прокси в реестре (без прав админа);
- `tun.py` — поднимает `sing-box`, который создаёт TUN-адаптер и льёт всё
  в SOCKS-инбаунд Xray; требует администратора, поэтому есть перезапуск с UAC;
- `downloader.py` — разовое скачивание ядра и компонентов TUN;
- `connect.py` — автоподбор рабочего TLS-отпечатка (см. ниже);
- `ping.py` — TCP-пинг серверов;
- `paths.py` — все пути в одном месте (`bin/`, `data/`, `%LOCALAPPDATA%\SCVPN`);
- `ui/` — интерфейс: `main_window.py` (экран), `widgets.py` (кнопка и карточки
  списка), `brandmark.py` (фирменный знак), `theme.py` (палитра и стили).

Важное свойство: и системный прокси, и TUN откатываются при закрытии окна и при
падении ядра (`closeEvent`, `_on_state`), чтобы не остаться без интернета.

**Android** (`android/`) — ядро внутри процесса приложения, трафик один способ:

```
весь трафик ОС → VpnService (TUN, fd) → libhev-socks5-tunnel (.so)
                                              ↓ 127.0.0.1:10808 SOCKS
                                        Xray внутри процесса (libv2ray.aar) ──→ сервер
```

- `ScVpnService.kt` — поднимает TUN через `VpnService.Builder`, стартует ядро,
  запускает hev-мост; подъём вынесен в отдельный поток, потому что автоподбор
  отпечатка ходит в сеть, а `onStartCommand` выполняется на главном;
- `XrayCore.kt` — обёртка над `libv2ray.aar` (запуск, остановка, замер задержки);
- `TProxyService.kt` — JNI-обёртка над `libhev-socks5-tunnel.so`. Единственный
  класс в чужом пакете `com.v2ray.ang.service`: под это имя .so был собран,
  `RegisterNatives` ищет именно его;
- `VpnState.kt` — состояние туннеля и его рассылка в экран broadcast-ом, чтобы
  кнопка показывала реальное состояние, а не догадку по таймеру;
- `MainActivity.kt` — единственный экран.

Петля исключена через `addDisallowedApplication(packageName)`: трафик самого
Xray к серверу идёт мимо TUN, иначе он заворачивал бы сам себя.

### Автоподбор TLS-отпечатка

В свежих сборках Xray отпечаток `chrome` шлёт пост-квантовую кривую, которую
часть серверов не понимает, а `randomized` нестабилен. Поэтому перед
подключением клиент быстро пробует firefox/safari/edge/ios и берёт первый
рабочий. На Windows это `connect.py` (можно зафиксировать в меню «Отпечаток
TLS»), на Android — `sanitizeFingerprint()` плюс перебор в `XrayCore.pingServer`.

---

## Сборка

Подробности — в `desktop/README.md` и `android/README.md`. Коротко:

```powershell
# Windows: exe + установщик
cd desktop
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
build.bat            # dist\SCVPN\SCVPN.exe
build_installer.bat  # dist_installer\SCVPN-Setup-*.exe
```

```powershell
# Android: APK
cd android
build_apk.bat        # app\build\outputs\apk\debug\app-debug.apk
```

Сторонние бинарники (`libv2ray.aar`, `libhev-socks5-tunnel.so`, `xray.exe`,
`sing-box.exe`, `wintun.dll`) в репозиторий не кладутся — откуда их взять
написано в README соответствующей папки.

## Фирменный знак

Иконка рисуется кодом, а не хранится картинкой: `desktop/setup/brand.py` —
одна траектория из двух касающихся дуг, обведённая штрихом с круглыми концами.
Из неё делаются `scvpn.ico` (Windows) и запасные `ic_launcher.png` (Android);
на Android основная иконка — векторная адаптивная
(`android/app/src/main/res/drawable/ic_launcher_foreground.xml`), а в интерфейсе
тот же знак рисуется Qt (`desktop/scvpn/ui/brandmark.py`). Геометрия во всех
трёх местах одна и та же, поэтому знак нигде не разъезжается.

## Планы

- [ ] iOS-клиент
- [ ] Свой транспортный протокол
- [ ] Эксперименты со своим ядром вместо Xray

## Лицензии

Обёртка — код этого репозитория. Используемые открытые проекты:
[Xray-core](https://github.com/XTLS/Xray-core) (MPL-2.0),
[sing-box](https://github.com/SagerNet/sing-box) (GPL-3.0),
[hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) (MIT),
[wintun](https://www.wintun.net/) (GPL-2.0).
