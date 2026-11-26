#!/bin/zsh
# Builds build/HandFX-<version>.dmg for other Macs: signed with Developer ID, notarised by Apple
# and stapled, so it opens without warnings. ONNX Runtime ships inside the app.
#
# Notarisation needs your Apple ID credentials saved once in the keychain (it asks for an
# app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials handfx-notary --apple-id <your Apple ID> --team-id <team ID>
#
# --no-notarise stops after the signed DMG.
set -euo pipefail
cd "${0:A:h}"
PROFILE=${NOTARY_PROFILE:-handfx-notary}
./fetch-onnxruntime.sh
TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | awk '/teamID = / {gsub(/[";]/, "", $3); print $3; exit}')
[[ -n "$TEAM_ID" ]] || { echo "No team in Xcode > Settings > Accounts"; exit 1; }
TEAM_ID=$TEAM_ID xcodegen generate --quiet

rm -rf build/HandFX.xcarchive build/export build/dmg
xcodebuild -project HandFX.xcodeproj -scheme HandFXApp -configuration Release -archivePath build/HandFX.xcarchive \
  -allowProvisioningUpdates archive | grep -E '^(\*\*|error:)' || true
[[ -d build/HandFX.xcarchive ]] || { echo "Archive failed"; exit 1; }

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath build/HandFX.xcarchive -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates | grep -E '^(\*\*|error:)' || true
APP=build/export/HandFX.app
[[ -d $APP ]] || { echo "Export failed"; exit 1; }
codesign --verify --deep --strict $APP

VERSION=$(plutil -extract CFBundleShortVersionString raw $APP/Contents/Info.plist)
DMG=build/HandFX-$VERSION.dmg
mkdir -p build/dmg
ditto $APP build/dmg/HandFX.app
ln -s /Applications build/dmg/Applications
rm -f $DMG
hdiutil create -quiet -volname HandFX -srcfolder build/dmg -format UDZO $DMG
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then codesign --sign "$IDENTITY" --timestamp $DMG; fi
echo "Signed: $DMG"

[[ "${1:-}" == --no-notarise ]] && exit 0
xcrun notarytool submit $DMG --keychain-profile $PROFILE --wait
xcrun stapler staple $DMG
spctl --assess --type open --context context:primary-signature --verbose $DMG
echo "Notarised: $DMG"
