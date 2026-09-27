#!/usr/bin/env bash
# Headless App Store distribution for Kioku: preflight → bump build number → archive → export →
# upload → tag. Run from a clean `main`.
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
#
# Usage:
#   ASC_KEY_ID=XXXXXXXX ASC_ISSUER_ID=<uuid> scripts/distribute.sh [--version X.Y] [--no-upload]
#     --version X.Y  also set the marketing version (CFBundleShortVersionString)
#     --no-upload    stop after exporting the .ipa: no upload, no commit, no tag
#                    (the build-number bump is reverted), for checking signing/export
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Kioku"
PBXPROJ="Kioku.xcodeproj/project.pbxproj"
TEAM_ID="PZ69YU2D7L"
# Persistent locations: /tmp is purged by macOS, and the deploy command's derived data is
# already warm for Release after a `/deploy --release`.
DERIVED="$HOME/Library/Caches/kioku-build"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Kioku.xcarchive"
EXPORT_DIR="$OUT/export"
PLIST="$OUT/ExportOptions.plist"

NEW_VERSION=""
UPLOAD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) NEW_VERSION="$2"; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$UPLOAD" = 1 ]; then
  : "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect API Key ID}"
  : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect Issuer ID}"
fi

echo "==> Preflight…"
BRANCH="$(git branch --show-current)"
[ "$BRANCH" = "main" ] || { echo "Release from main (on '$BRANCH')." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree not clean." >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not at origin/main — pull or push first." >&2; exit 1; }
bash scripts/ensure_dictionary.sh
bash scripts/ensure_handwriting_model.sh
bash scripts/validate_invariants.sh

# Every target and configuration carries its own copy of these settings; keep them in lockstep.
OLD_BUILD="$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBXPROJ" | grep -o '[0-9]*$')"
NEW_BUILD=$((OLD_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/" "$PBXPROJ"
if [ -n "$NEW_VERSION" ]; then
  sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $NEW_VERSION;/" "$PBXPROJ"
fi
VERSION="$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$PBXPROJ" | grep -o '[0-9.]*$')"
echo "==> Version $VERSION ($NEW_BUILD), was build $OLD_BUILD"

# Restores the project file when the run stops before the bump is committed, so a failed or
# --no-upload run never leaves a stray version change behind.
revert_bump() { git checkout -- "$PBXPROJ"; }
trap revert_bump EXIT

echo "==> Archiving Release build…"
mkdir -p "$OUT"
rm -rf "$ARCHIVE"
xcodebuild -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
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
if [ "$UPLOAD" = 0 ]; then
  echo "==> Exported $IPA (--no-upload: build-number bump reverted, nothing committed)."
  exit 0
fi

echo "==> Uploading $IPA via API key…"
xcrun altool --upload-app \
  -f "$IPA" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

# The upload is accepted, so this build number is spent: record it on main and tag it.
trap - EXIT
TAG="v$VERSION-$NEW_BUILD"
git commit -q -m "chore(release): $VERSION ($NEW_BUILD)" -- "$PBXPROJ"
git tag "$TAG"
git push -q origin main "$TAG"

echo "==> Uploaded $VERSION ($NEW_BUILD), tagged $TAG. Check App Store Connect > TestFlight for processing."
