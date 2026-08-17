#!/usr/bin/env bash
# Сборка scvpn-awg под все платформы, куда его кладёт приложение.
#
# CGO выключен намеренно: без него кросс-компиляция идёт с любой машины и не
# тянет ни clang, ни NDK, а бинарник получается самодостаточным.
set -euo pipefail
cd "$(dirname "$0")"

out="${1:-dist}"
mkdir -p "$out"

go test ./...

build() { # GOOS GOARCH имя_файла
    echo "  $3"
    CGO_ENABLED=0 GOOS="$1" GOARCH="$2" \
        go build -trimpath -ldflags "-s -w" -o "$out/$3" .
}

echo "Собираю в $out/"
build darwin  arm64 scvpn-awg-darwin-arm64
build darwin  amd64 scvpn-awg-darwin-amd64
build windows amd64 scvpn-awg-windows-amd64.exe
# Android исполняет только то, что лежит в папке нативных библиотек и названо
# lib*.so — отсюда имя, у которого с библиотекой общего лишь расширение.
build android arm64 libscvpnawg-arm64-v8a.so

# Остальные ABI Android Go собирает только через внешний линковщик, то есть с
# NDK. Ставить NDK обязательным условием сборки незачем: arm64 покрывает всё,
# что выпущено с 2016 года, а эмулятор и старые устройства нужны редко. Без
# NDK эти ABI просто не собираются, и приложение честно скажет, что туннель
# на этом устройстве недоступен.
ndk_cc() { # GOARCH -> путь к clang из NDK, пусто если нет
    local triple
    case "$1" in
        arm)   triple=armv7a-linux-androideabi21 ;;
        386)   triple=i686-linux-android21 ;;
        amd64) triple=x86_64-linux-android21 ;;
    esac
    local root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
    [ -n "$root" ] || return 0
    local cc
    for cc in "$root"/toolchains/llvm/prebuilt/*/bin/"$triple"-clang; do
        [ -x "$cc" ] && { echo "$cc"; return 0; }
    done
}

build_ndk() { # GOARCH имя_файла
    local cc
    cc="$(ndk_cc "$1")"
    if [ -z "$cc" ]; then
        echo "  $2 — пропущено (нет NDK; задай ANDROID_NDK_HOME)"
        return 0
    fi
    echo "  $2"
    CGO_ENABLED=1 CC="$cc" GOOS=android GOARCH="$1" \
        go build -trimpath -ldflags "-s -w" -o "$out/$2" .
}

build_ndk arm   libscvpnawg-armeabi-v7a.so
build_ndk 386   libscvpnawg-x86.so
build_ndk amd64 libscvpnawg-x86_64.so

# Универсальный бинарник macOS — приложение одно на обе архитектуры.
if command -v lipo >/dev/null 2>&1; then
    lipo -create -output "$out/scvpn-awg" \
        "$out/scvpn-awg-darwin-arm64" "$out/scvpn-awg-darwin-amd64"
    echo "  scvpn-awg (universal)"
fi

echo
echo "Готово. Положить на место:"
echo "  macOS:   cp $out/scvpn-awg ~/Library/Application\\ Support/SCVPN/bin/"
echo "  Windows: скопировать $out/scvpn-awg-windows-amd64.exe в bin\\scvpn-awg.exe"
echo "  Android: разложить libscvpnawg-*.so по app/src/main/jniLibs/<ABI>/libscvpnawg.so"
