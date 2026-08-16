#!/bin/bash
# Сборка SCVPN.ipa. Ядро (LibXray.xcframework) в репозитории нет — как его
# добыть, написано в README.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "[!] Нет xcodegen: brew install xcodegen"; exit 1; }
[ -d Frameworks/LibXray.xcframework ] || {
  echo "[!] Нет Frameworks/LibXray.xcframework — см. README, раздел «Ядро Xray»"; exit 1; }

xcodegen generate

# ExportOptions зависит от способа раздачи (development / ad-hoc / app-store) и
# от команды разработчика, поэтому в git не кладётся: у каждого он свой.
[ -f ExportOptions.plist ] || {
  echo "[!] Нет ExportOptions.plist. Пример:"
  cat <<'SAMPLE'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>method</key><string>development</string>
      <key>teamID</key><string>XXXXXXXXXX</string>
      <key>signingStyle</key><string>automatic</string>
    </dict></plist>
SAMPLE
  exit 1; }

xcodebuild -project SCVPN.xcodeproj -scheme SCVPN \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/SCVPN.xcarchive archive

xcodebuild -exportArchive -archivePath build/SCVPN.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/ipa

echo "IPA: ios/build/ipa/SCVPN.ipa"
