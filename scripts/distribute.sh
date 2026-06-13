#!/usr/bin/env bash
# Headless App Store distribution for Kioku.
#
# Signing and delivery are split on purpose:
#   - EXPORT/SIGN uses your Xcode-logged-in Apple ID account (account-holder
#     rights), which can cloud-sign the App Store provisioning profile with the
#     distribution cert. An App Store Connect API key with the App Manager role
#     CANNOT cloud-sign (xcodebuild errors "Cloud signing permission error"),
#     so we deliberately do NOT pass the key to exportArchive.
#   - UPLOAD uses the API key via altool, which App Manager is allowed to do.
#
# One-time prerequisites:
#   1. An "Apple Distribution" certificate in the login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Apple Distribution).
#      First run prompts once for the login-keychain password — click "Always Allow".
#   2. An App Store Connect API key (App Manager role) at
#      ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8, plus its Key ID and Issuer ID.
#   3. Bump CURRENT_PROJECT_VERSION in project.pbxproj before each release.
#
# Usage:
#   ASC_KEY_ID=XXXXXXXX ASC_ISSUER_ID=<uuid> scripts/distribute.sh
set -euo pipefail

SCHEME="Kioku"
ARCHIVE="/tmp/Kioku.xcarchive"
EXPORT_DIR="/tmp/Kioku-export"
PLIST="/tmp/ExportOptions.plist"
TEAM_ID="PZ69YU2D7L"

: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect API Key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect Issuer ID}"

echo "==> Archiving Release build…"
rm -rf "$ARCHIVE"
xcodebuild -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLISTEOF

echo "==> Exporting + signing (uses your Xcode account session, not the API key)…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$PLIST" \
  -allowProvisioningUpdates

IPA=$(ls "$EXPORT_DIR"/*.ipa | head -1)
echo "==> Uploading $IPA via API key…"
xcrun altool --upload-app \
  -f "$IPA" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

echo "==> Upload submitted. Check App Store Connect > TestFlight for processing."
