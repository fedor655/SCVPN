#!/bin/bash
# Собрать и поставить SCVPN на подключённый iPhone.
#
# По умолчанию — БЕЗ расширения туннеля. Причина: расширению нужен
# entitlement com.apple.developer.networking.networkextension, а бесплатный
# Apple ID (Personal Team) его не выдаёт — профиль просто не выпустится, и
# сборка упадёт. Без расширения приложение ставится и работает целиком, кроме
# самого подключения: серверы, подписки, пинг, настройки, перенос профилей.
#
# С платным Apple Developer Program: ./run-on-device.sh --tunnel
set -euo pipefail
cd "$(dirname "$0")"

TEAM="${SCVPN_TEAM:-}"
BUNDLE="${SCVPN_BUNDLE_ID:-}"
WITH_TUNNEL=0
[ "${1:-}" = "--tunnel" ] && WITH_TUNNEL=1

[ -n "$TEAM" ] || {
  echo "[!] Не задан SCVPN_TEAM — идентификатор команды разработчика."
  echo "    Посмотреть: security find-identity -v -p codesigning"
  echo "    Он в скобках: «Apple Development: почта (XXXXXXXXXX)»"
  exit 1; }
[ -n "$BUNDLE" ] || {
  echo "[!] Не задан SCVPN_BUNDLE_ID."
  echo "    Возьми свой, например: com.<фамилия>.scvpn"
  echo "    Apple требует, чтобы идентификатор не был занят чужим приложением."
  exit 1; }

# Каталог сборки — вне проекта. Репозиторий часто лежит в ~/Documents, а её
# синхронизирует iCloud: он вешает на файлы расширенные атрибуты, и подпись
# падает с «resource fork, Finder information, or similar detritus not allowed».
DERIVED="${SCVPN_DERIVED:-$HOME/Library/Caches/scvpn-ios}"

command -v xcodegen >/dev/null || { echo "[!] brew install xcodegen"; exit 1; }
[ -d Frameworks/LibXray.xcframework ] || {
  echo "[!] Нет ядра: Frameworks/LibXray.xcframework — см. README"; exit 1; }

SPEC=project.yml
if [ "$WITH_TUNNEL" = "0" ]; then
  # Вырезаем таргет расширения: без платного аккаунта он не подпишется.
  SPEC=.project-notunnel.yml
  python3 - "$SPEC" <<'PY'
import sys, re
spec = open("project.yml").read()
# Убираем сам таргет и зависимость приложения на него.
spec = re.sub(r"\n  PacketTunnel:\n(?:.*\n)*?(?=\n  \w|\nschemes:)", "\n", spec)
spec = spec.replace("      - target: PacketTunnel\n", "")
open(sys.argv[1], "w").write(spec)
PY
  echo "[i] Сборка без расширения туннеля (бесплатный Apple ID)."
else
  echo "[i] Сборка с расширением — нужен платный Apple Developer Program."
fi

xcodegen generate --spec "$SPEC" >/dev/null

DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/available/ {print $(NF-1); exit}')"
[ -n "$DEVICE" ] || { echo "[!] iPhone не найден. Подключи кабелем и разреши доверие."; exit 1; }

xcodebuild build -project SCVPN.xcodeproj -scheme SCVPN \
  -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates

APP="$DERIVED/Build/Products/Debug-iphoneos/SCVPN.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" || true
echo "Готово. Первый запуск: Настройки → Основные → VPN и управление устройством → доверять разработчику."
