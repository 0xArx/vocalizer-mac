#!/bin/zsh
# Notarizes build/Vocalizer.app with Apple and staples the ticket, so a downloaded copy opens with no warning.
# One-time setup (App Store Connect API key, Developer role or higher):
#   xcrun notarytool store-credentials vocalizer --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer uuid>
# Then: scripts/notarize.sh   (NOTARY_PROFILE overrides the keychain profile name)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Vocalizer.app
PROFILE=${NOTARY_PROFILE:-vocalizer}
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "error: $APP is not signed with a Developer ID Application certificate"; exit 1; }
ZIP=build/Vocalizer-notarize.zip
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)
echo "$OUT"
ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$OUT")
if ! grep -q '"status" *: *"Accepted"' <<<"$OUT"; then
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE"; exit 1
fi
rm -f "$ZIP"
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"
