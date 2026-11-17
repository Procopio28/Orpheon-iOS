#!/bin/bash
# Builds an unsigned Orpheon.ipa (for fake-signing on a jailbroken device).
#   ./build_ipa.sh            -> Orpheon.ipa
# Needs Xcode 14 or newer on a Mac. If `ldid` is installed the app is fake-signed with it.
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild \
  -project LiteSpotify.xcodeproj \
  -scheme LiteSpotify \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  clean build

APP="build/Build/Products/Release-iphoneos/Orpheon.app"
[ -d "$APP" ] || { echo "Build did not produce $APP"; exit 1; }

rm -rf Payload Orpheon.ipa
mkdir Payload
cp -R "$APP" Payload/

if command -v ldid >/dev/null 2>&1; then
  ldid -S Payload/Orpheon.app/Orpheon
  echo "Fake-signed with ldid."
else
  echo "ldid not found: the IPA is unsigned (sign it with your jailbreak's installer, or 'ldid -S')."
fi

zip -qry Orpheon.ipa Payload
rm -rf Payload
echo "Wrote $(pwd)/Orpheon.ipa"
