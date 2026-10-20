#!/bin/zsh
# Publishes the version in Resources/Info.plist: builds, signs and notarizes it (package-release.sh), signs the
# zip for Sparkle, creates the GitHub release, adds it to website/appcast.xml, deploys the website, commits.
#   scripts/publish.sh "Fixed X
#   Added Y"            (one change per line; shown in the update window and the release notes)
# Needs: .signing/release.env (GITHUB_TOKEN, VERCEL_TOKEN), .signing/sparkle-private.key, Developer ID + notary key.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES=${1:?usage: scripts/publish.sh "release notes, one change per line"}
source .signing/release.env
REPO=0xArx/vocalizer-mac
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
SPARKLE=${SPARKLE_BIN:-$HOME/Developer/vendor/sparkle-2.10.0/bin}
if [[ ! -x $SPARKLE/sign_update ]]; then
  mkdir -p "$SPARKLE/.." && curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz | tar -xJ -C "$SPARKLE/.."
fi
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/$REPO/releases/tags/v$VER)
[[ $CODE == 404 ]] || { echo "error: v$VER is already released (HTTP $CODE); bump CFBundleShortVersionString and CFBundleVersion first"; exit 1; }

scripts/package-release.sh
ZIP=build/Vocalizer-macOS.zip
SIG=$("$SPARKLE/sign_update" --ed-key-file .signing/sparkle-private.key "$ZIP")
URL="https://github.com/$REPO/releases/download/v$VER/Vocalizer-macOS.zip"

BODY=$(python3 -c 'import json,sys; v,n=sys.argv[1:]; print(json.dumps({"tag_name":"v"+v,"target_commitish":"main","name":"Vocalizer "+v,
  "body":"\n".join("- "+l.strip().lstrip("-").strip() for l in n.splitlines() if l.strip())+"\n\nSigned and notarized. Apple silicon, macOS 14.2 or later. Vocalizer updates itself; new installs: https://getvocalizer.com"}))' "$VER" "$NOTES")
ID=$(curl -fsS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/$REPO/releases -d "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
curl -fsS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" -H "Content-Type: application/zip" --data-binary @"$ZIP" \
  "https://uploads.github.com/repos/$REPO/releases/$ID/assets?name=Vocalizer-macOS.zip" >/dev/null
# Only announce the update once the download is really there.
curl -fsSIL -o /dev/null "$URL"

python3 tools/appcast.py website/appcast.xml "$BUILD" "$VER" "$URL" "$SIG" "$NOTES"
(cd website && npx -y vercel@latest deploy --prod --yes --token "$VERCEL_TOKEN" >/dev/null 2>&1)
curl -fsS https://getvocalizer.com/appcast.xml | grep -q "<sparkle:version>$BUILD<" && echo "appcast live: $VER ($BUILD)"

git add website/appcast.xml Resources/Info.plist
git -c user.name=0xArx -c user.email=34143289+0xArx@users.noreply.github.com commit -qm "Release $VER" || true
echo "published Vocalizer $VER: https://github.com/$REPO/releases/tag/v$VER (push the commit)"
