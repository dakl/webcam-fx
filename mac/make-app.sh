#!/bin/zsh
# Build HandFX.app with its camera extension and install it in /Applications.
# Signs with the first team in your Xcode accounts; Xcode creates the certificate if needed.
set -euo pipefail
cd "${0:A:h}"
TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | awk '/teamID = / {gsub(/[";]/, "", $3); print $3; exit}')
[[ -n "$TEAM_ID" ]] || { echo "No team in Xcode > Settings > Accounts"; exit 1; }
TEAM_ID=$TEAM_ID xcodegen generate --quiet
xcodebuild -project HandFX.xcodeproj -scheme HandFXApp -configuration Release -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build | grep -E '^(\*\*|error:|warning: .*signing)' || true
APP=build/Build/Products/Release/HandFX.app
[[ -d $APP ]] || { echo "Build failed"; exit 1; }
rm -rf /Applications/HandFX.app
cp -R $APP /Applications/
echo "Installed /Applications/HandFX.app"
