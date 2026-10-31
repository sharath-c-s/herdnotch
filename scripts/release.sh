#!/usr/bin/env bash
# Builds HerdNotch, publishes it as a GitHub release on this repo, and bumps the Homebrew cask to match.
#
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
# Needs: Xcode 27 (DEVELOPER_DIR), gh logged in with push access to this repo and the tap, a clean tree on `main`.
# ponytail: runs on the maintainer's Mac; move to GitHub Actions once a hosted runner ships Swift 6.2.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
REPO="${REPO:-sharath-c-s/herdnotch}"
TAP_REPO="${TAP_REPO:-sharath-c-s/homebrew-tap}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "error: working tree is not clean; commit or stash first" >&2; exit 1; }
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || { echo "error: releases are cut from main, current branch is $BRANCH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> build $VERSION"
(cd "$ROOT/HerdNotch" && HERDNOTCH_VERSION="$VERSION" bash build-notch.sh)

ZIP="$WORK/HerdNotch-$VERSION.zip"
ditto -c -k --keepParent "$ROOT/HerdNotch/HerdNotch.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256 $SHA"

echo "==> release v$VERSION on $REPO"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "HerdNotch $VERSION" \
    --notes "Install: brew install ${TAP_REPO%%/*}/tap/herdnotch"

echo "==> bump cask in $TAP_REPO"
gh repo clone "$TAP_REPO" "$WORK/tap" -- --quiet
CASK="$WORK/tap/Casks/herdnotch.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$WORK/tap" commit --quiet -am "herdnotch $VERSION"
git -C "$WORK/tap" push --quiet
# brew reads its local tap clone, which only syncs on auto-update; refresh it so the upgrade sees this release.
LOCAL_TAP="$(brew --repository)/Library/Taps/${TAP_REPO%%/*}/homebrew-${TAP_REPO#*/homebrew-}"
[ -d "$LOCAL_TAP/.git" ] && git -C "$LOCAL_TAP" pull --quiet --ff-only || true
echo "==> done: brew upgrade --cask herdnotch"
