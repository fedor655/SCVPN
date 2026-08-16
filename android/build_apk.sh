#!/bin/bash
# Сборка APK SCVPN на macOS и Linux — то же, что делает build_apk.bat на
# Windows. Wrapper'а в репозитории нет, поэтому берётся системный gradle.
set -euo pipefail
cd "$(dirname "$0")"

# JDK 21: AGP 8.6 не работает на более новых. Порядок поиска — от явного
# JAVA_HOME к тому, что ставит brew, и к JDK от Android Studio.
if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in /opt/homebrew/opt/openjdk@21 \
                   /usr/lib/jvm/java-21-openjdk \
                   "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    [ -x "$candidate/bin/java" ] && export JAVA_HOME="$candidate" && break
  done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "[!] Нет JDK 21. brew install openjdk@21"; exit 1; }

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[ -d "$ANDROID_HOME/platforms" ] || {
  echo "[!] Нет Android SDK в $ANDROID_HOME."
  echo "    brew install --cask android-commandlinetools"
  echo "    sdkmanager --sdk_root=\$ANDROID_HOME 'platform-tools' 'platforms;android-34' 'build-tools;34.0.0'"
  exit 1
}

[ -f app/libs/libv2ray.aar ] || { echo "[!] Нет app/libs/libv2ray.aar — см. README"; exit 1; }
[ -f app/src/main/jniLibs/arm64-v8a/libhev-socks5-tunnel.so ] || {
  echo "[!] Нет libhev-socks5-tunnel.so — см. README"; exit 1; }

gradle assembleDebug --no-daemon "$@"

# На macOS каталог сборки унесён из проекта — см. комментарий в build.gradle.kts.
APK="$HOME/Library/Caches/scvpn-android/app/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || APK="app/build/outputs/apk/debug/app-debug.apk"
echo "APK: $APK"
