#!/usr/bin/env bash
# Builds HerdNotch, publishes it as a GitHub release, and bumps the Homebrew cask to match.
#
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
# Needs: Xcode 26 (DEVELOPER_DIR), gh logged in with push access to both repos.
# ponytail: runs on the maintainer's Mac; move to GitHub Actions once a hosted runner ships Swift 6.2.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
PUBLIC_REPO="${PUBLIC_REPO:-sharath-c-s/herdnotch}"
TAP_REPO="${TAP_REPO:-sharath-c-s/homebrew-tap}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> build $VERSION"
(cd "$ROOT/BoringHerdBar" && HERDNOTCH_VERSION="$VERSION" bash build-notch.sh)

ZIP="$WORK/HerdNotch-$VERSION.zip"
ditto -c -k --keepParent "$ROOT/BoringHerdBar/HerdNotch.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256 $SHA"

echo "==> sync tracked tree to $PUBLIC_REPO (one commit per release)"
gh repo clone "$PUBLIC_REPO" "$WORK/public" -- --quiet
find "$WORK/public" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git -C "$ROOT" archive HEAD | tar -x -C "$WORK/public"
git -C "$WORK/public" add -A
git -C "$WORK/public" commit --quiet -m "HerdNotch $VERSION" || echo "    (no source changes)"
git -C "$WORK/public" push --quiet

echo "==> release v$VERSION on $PUBLIC_REPO"
gh release create "v$VERSION" "$ZIP" --repo "$PUBLIC_REPO" --title "HerdNotch $VERSION" \
    --notes "Install: brew install ${TAP_REPO%%/*}/tap/herdnotch"

echo "==> bump cask in $TAP_REPO"
gh repo clone "$TAP_REPO" "$WORK/tap" -- --quiet
CASK="$WORK/tap/Casks/herdnotch.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$WORK/tap" commit --quiet -am "herdnotch $VERSION"
git -C "$WORK/tap" push --quiet
echo "==> done: brew upgrade --cask herdnotch"
