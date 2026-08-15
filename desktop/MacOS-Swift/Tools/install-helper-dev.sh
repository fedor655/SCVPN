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

sudo install -d -o root -g wheel -m 755 /usr/local/libexec
sudo install -o root -g wheel -m 755 "$BIN" /usr/local/libexec/scvpn-helper
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
sudo launchctl bootout system/com.scvpn.helper 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.scvpn.helper.plist

echo "Поставлен. Дальше:"
echo "  cd ../MacOS && SCVPN_ASSUME_HELPER=1 venv/bin/python run.py"
