#!/usr/bin/env bash
# Build Roomprint, sign it for the App Store and upload it to TestFlight, all from Linux.
#
#   ios/tools/testflight.sh            build, sign, verify, upload
#   ios/tools/testflight.sh --no-upload  stop after making build/Roomprint.ipa
#
# Needs (none of it in git):
#   ~/.config/roomprint/env      ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_FILE (App Store Connect API key)
#   ~/.config/roomprint/signing/ dist.key + dist.cer (Apple Distribution), appstore.mobileprovision
#   xtool (XTOOL, default: xtool on PATH), rcodesign, iTMSTransporter (ITMS)
# The asset catalog comes from the "App icon" GitHub workflow, committed in ios/Icon/compiled/.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ~/.config/roomprint/env; set +a
XTOOL=${XTOOL:-xtool}
ITMS=${ITMS:-iTMSTransporter}
SIGN=~/.config/roomprint/signing
TEAM=VAV24HTM9H
BUNDLE_ID=XTL-VAV24HTM9H.com.p4ulcristian.roomprint   # the App Store Connect app's bundle ID
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)

# SDK the app is compiled against, stamped into Info.plist like Xcode does; App Store
# Connect rejects builds without these. Xcode values: the Xcode that ships this SDK.
SDK_VERSION=26.5
SDK_BUILD=23F81a
XCODE=${XCODE:-2650}
XCODE_BUILD=${XCODE_BUILD:-17F42}

"$XTOOL" dev build --configuration release
rm -rf build && mkdir -p build/Payload
cp -R xtool/Roomprint.app build/Payload/
APP=build/Payload/Roomprint.app

cp Icon/compiled/Assets.car Icon/compiled/*.png "$APP/"
python3 - "$APP/Info.plist" Icon/compiled/partial.plist <<EOF
import plistlib, sys
info_path, partial_path = sys.argv[1], sys.argv[2]
p = plistlib.load(open(info_path, "rb"))
p.update(plistlib.load(open(partial_path, "rb")))   # CFBundleIcons / CFBundleIconName from actool
p.pop("CFBundleIconFile", None)
p.update({
    "CFBundleIdentifier": "$BUNDLE_ID",
    "CFBundleVersion": "$BUILD_NUMBER",
    "UIDeviceFamily": [1],                       # iPhone only (RoomPlan scans need a Pro iPhone anyway)
    "ITSAppUsesNonExemptEncryption": False,      # HTTPS only
    "DTPlatformName": "iphoneos", "DTPlatformVersion": "$SDK_VERSION", "DTPlatformBuild": "$SDK_BUILD",
    "DTSDKName": "iphoneos$SDK_VERSION", "DTSDKBuild": "$SDK_BUILD",
    "DTXcode": "$XCODE", "DTXcodeBuild": "$XCODE_BUILD", "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
})
p.pop("UISupportedInterfaceOrientations~ipad", None)
plistlib.dump(p, open(info_path, "wb"))
EOF

cp "$SIGN/appstore.mobileprovision" "$APP/embedded.mobileprovision"
cat > build/entitlements.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><false/>
  <key>beta-reports-active</key><true/>
</dict></plist>
EOF
openssl x509 -inform der -in "$SIGN/dist.cer" -out build/dist.pem
rcodesign sign --pem-file "$SIGN/dist.key" --pem-file build/dist.pem \
  --entitlements-xml-file build/entitlements.plist "$APP"
rm build/dist.pem
(cd build && zip -qry Roomprint.ipa Payload)
echo "build/Roomprint.ipa: build $BUILD_NUMBER"

[ "${1:-}" = "--no-upload" ] && exit 0
# Transporter finds the key in ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
mkdir -p ~/.appstoreconnect/private_keys
ln -sf "$ASC_KEY_FILE" ~/.appstoreconnect/private_keys/
"$ITMS" -m upload -assetFile build/Roomprint.ipa -apiKey "$ASC_KEY_ID" -apiIssuer "$ASC_ISSUER_ID" -v informational
