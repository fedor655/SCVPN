#!/bin/bash
# Ставит Swift-демона обычным LaunchDaemon — только на время Фазы 2, пока
# бандла с SMAppService ещё нет. В релизе демона ставит SMAppService, и этот
# скрипт вместе с Фазой 2 уходит.
#
# Python-приложение проверяет установку сравнением содержимого своего plist с
# тем, что лежит на диске (helper/install.py::installed). Здесь plist другой —
# ProgramArguments указывает на Swift-бинарник, — поэтому приложение надо
# запускать с SCVPN_ASSUME_HELPER=1, см. раздел 0.3 плана.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$PWD/.build/arm64-apple-macosx/release/SCVPNHelper"
[ -x "$BIN" ] || { echo "сначала: swift build -c release --arch arm64"; exit 1; }

# Снять прежнюю службу ДО подмены файлов и дождаться, пока launchd её отпустит.
# bootout возвращается, не дожидаясь ухода процесса, а у службы ExitTimeOut 40:
# bootstrap, поданный сразу следом, влетает в ещё живую регистрацию и получает
# «Bootstrap failed: 5: Input/output error». Ждём исчезновения по print.
if sudo launchctl print system/com.scvpn.helper >/dev/null 2>&1; then
  echo "снимаю прежнюю службу…"
  sudo launchctl bootout system/com.scvpn.helper 2>/dev/null || true
  for _ in $(seq 1 60); do
    sudo launchctl print system/com.scvpn.helper >/dev/null 2>&1 || break
    sleep 1
  done
  if sudo launchctl print system/com.scvpn.helper >/dev/null 2>&1; then
    echo "[!] прежняя служба не снялась за 60 с. Посмотри: sudo launchctl print system/com.scvpn.helper"
    exit 1
  fi
fi

sudo install -d -o root -g wheel -m 755 /usr/local/libexec
sudo install -o root -g wheel -m 755 "$BIN" /usr/local/libexec/scvpn-helper
# Ad-hoc подпись и снятие xattr: launchd отказывается поднимать бинарник с
# карантином, а SPM кладёт продукт сборки неподписанным — build.sh подписывает
# только копию внутри бандла, до которой здесь дела нет.
sudo xattr -cr /usr/local/libexec/scvpn-helper
sudo codesign --force --sign - /usr/local/libexec/scvpn-helper
sudo tee /Library/LaunchDaemons/com.scvpn.helper.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.scvpn.helper</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/scvpn-helper</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ExitTimeOut</key><integer>40</integer>
  <key>StandardErrorPath</key><string>/var/log/scvpn-helper.log</string>
  <key>StandardOutPath</key><string>/var/log/scvpn-helper.log</string>
</dict></plist>
PLIST
sudo chown root:wheel /Library/LaunchDaemons/com.scvpn.helper.plist
sudo chmod 644 /Library/LaunchDaemons/com.scvpn.helper.plist
sudo xattr -c /Library/LaunchDaemons/com.scvpn.helper.plist 2>/dev/null || true

# Служба могла остаться помеченной disabled от прошлых снятий — из этого
# состояния bootstrap отвергается, и понять почему по коду ошибки нельзя.
sudo launchctl enable system/com.scvpn.helper 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.scvpn.helper.plist

# Проверяем не код возврата bootstrap, а факт: сокет появился. RunAtLoad
# поднимает демона сразу, сокет он открывает первым делом.
for _ in $(seq 1 20); do
  [ -S /var/run/scvpn-helper.sock ] && break
  sleep 0.5
done
if [ -S /var/run/scvpn-helper.sock ]; then
  ls -l /var/run/scvpn-helper.sock
  echo "Поставлен. Дальше:"
  echo "  cd ../MacOS && SCVPN_ASSUME_HELPER=1 venv/bin/python run.py"
else
  echo "[!] сокета нет. Лог демона:"
  sudo tail -20 /var/log/scvpn-helper.log
  exit 1
fi
