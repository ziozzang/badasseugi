#!/bin/zsh
# Build + publish a GitHub release that the in-app updater picks up.
#   scripts/release.sh 0.2.0 ["release notes"]
# Assets: <prefix>_<version>_macos_arm64.zip (zipped .app) + SHA256SUMS  (same scheme as ziozzang/sugyeol)
# Token: $GITHUB_TOKEN, or GITHUB_TOKEN=… in ~/env. Never printed; passed to curl via a 0600 header file.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh X.Y.Z [notes]}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
PLIST=Resources/Info.plist
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
REPO=$(pb "Print :UpdateRepo"); PREFIX=$(pb "Print :UpdateAssetPrefix"); NAME=$(pb "Print :CFBundleName")
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean — commit first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "tag v$VERSION already exists" >&2; exit 1; }

TOKEN="${GITHUB_TOKEN:-$(grep -E '^(export )?GITHUB_TOKEN=' ~/env 2>/dev/null | head -1 | sed -E "s/^(export )?GITHUB_TOKEN=//; s/^[\"']//; s/[\"']\$//")}"
[[ -n "$TOKEN" ]] || { echo "GITHUB_TOKEN not set" >&2; exit 1; }
HDR=$(mktemp); PASS=$(mktemp); ASK=$(mktemp); chmod 600 "$HDR" "$PASS"; chmod 700 "$ASK"
trap 'rm -f "$HDR" "$PASS" "$ASK"' EXIT
printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$TOKEN" > "$HDR"
printf '%s' "$TOKEN" > "$PASS"; printf '#!/bin/sh\ncat "%s"\n' "$PASS" > "$ASK"   # git push over https without exposing the token
unset TOKEN
gitpush() { GIT_ASKPASS="$ASK" GIT_TERMINAL_PROMPT=0 git -c credential.helper= push "$@"; }

# Notes: argument, or commit subjects since the previous tag.
PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
NOTES="${2:-$(git log --pretty='- %s' ${PREV:+$PREV..}HEAD | grep -v '^- Release v' || true)}"

echo "▶ $NAME v$VERSION → $REPO"
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :CFBundleVersion $(( $(pb 'Print :CFBundleVersion') + 1 ))"
./build.sh release

mkdir -p dist
ZIP="${PREFIX}_${VERSION}_macos_arm64.zip"
rm -f "dist/$ZIP" dist/SHA256SUMS
ditto -c -k --sequesterRsrc --keepParent "build/$NAME.app" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > SHA256SUMS && cat SHA256SUMS)

git add "$PLIST"
git commit -q -m "Release v$VERSION" ${COMMIT_TRAILER:+-m "$COMMIT_TRAILER"}
git tag -a "v$VERSION" -m "v$VERSION"
gitpush -q origin HEAD "v$VERSION"

BODY=$(NOTES="$NOTES" VERSION="$VERSION" NAME="$NAME" python3 -c '
import json, os
print(json.dumps({"tag_name": "v"+os.environ["VERSION"], "name": os.environ["NAME"]+" v"+os.environ["VERSION"],
                  "body": os.environ["NOTES"], "draft": False, "prerelease": False}))')
REL=$(curl -sS -H @"$HDR" -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY")
ID=$(echo "$REL" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
[[ -n "$ID" ]] || { echo "release creation failed: $REL" >&2; exit 1; }
for f in "$ZIP" SHA256SUMS; do
  TYPE=$([[ $f == *.zip ]] && echo application/zip || echo text/plain)
  curl -sS -H @"$HDR" -H "Content-Type: $TYPE" --data-binary @"dist/$f" \
    "https://uploads.github.com/repos/$REPO/releases/$ID/assets?name=$f" \
    | python3 -c 'import json,sys; a=json.load(sys.stdin); print("  uploaded", a.get("name"), a.get("size"), a.get("state") or a)'
done
echo "✓ https://github.com/$REPO/releases/tag/v$VERSION"
