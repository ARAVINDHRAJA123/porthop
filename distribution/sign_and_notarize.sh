#!/bin/bash
# Signs PortHop.app with a Developer ID, has Apple notarize it, and staples the ticket, so it opens on any Mac
# without the "unidentified developer" warning. Needs a paid Apple Developer account. Run from the repository root:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=porthop ./distribution/sign_and_notarize.sh
#
# One-time setup: create the "Developer ID Application" certificate in Xcode (Settings > Accounts), then store
# notarization credentials in the keychain:  xcrun notarytool store-credentials porthop --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' certificate name}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the name used with notarytool store-credentials}"
APP=PortHop.app
[ -d "$APP" ] || ./build.sh

# Inside out: every bundled tool, then the app. Hardened runtime and a secure timestamp are required for notarization.
find "$APP/Contents/Helpers" -type f -perm -u+x | while read -r f; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$f"
done
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

ZIP="$(mktemp -d)/PortHop-notarize.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
echo "Signed, notarized and stapled: $APP"
