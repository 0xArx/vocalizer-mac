#!/bin/zsh
# Notarizes build/Vocalizer.app with Apple and staples the ticket, so a downloaded copy opens with no warning.
# One-time setup (App Store Connect API key, Developer role or higher), either:
#   xcrun notarytool store-credentials vocalizer --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer uuid>
# or a .signing/notary.env with NOTARY_KEY=<path to .p8>, NOTARY_KEY_ID=..., NOTARY_ISSUER=...
# Then: scripts/notarize.sh   (NOTARY_PROFILE overrides the keychain profile name)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Vocalizer.app
PROFILE=${NOTARY_PROFILE:-vocalizer}
# An App Store Connect API key can be used directly instead of the keychain profile
# (NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER; .signing/notary.env is read when present, never committed).
[[ -f .signing/notary.env ]] && source .signing/notary.env
if [[ -n "${NOTARY_KEY:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  AUTH=(--keychain-profile "$PROFILE")
fi
# (read into a variable first: with pipefail, grep -q closing the pipe early would fail codesign)
SIG=$(codesign -dvv "$APP" 2>&1)
[[ $SIG == *"Authority=Developer ID Application"* ]] \
  || { echo "error: $APP is not signed with a Developer ID Application certificate"; exit 1; }
ZIP=build/Vocalizer-notarize.zip
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
OUT=$(xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait --output-format json)
echo "$OUT"
ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$OUT")
if ! grep -q '"status" *: *"Accepted"' <<<"$OUT"; then
  xcrun notarytool log "$ID" "${AUTH[@]}"; exit 1
fi
rm -f "$ZIP"
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"
