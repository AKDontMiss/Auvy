#!/usr/bin/env bash
# Build and package an iPhone release: the IPA and its source.json.
#
# Built from a clean checkout of the current commit in a neutral folder, for two
# reasons: a release is exactly what is committed (no stray local edits), and
# the app names no folder on this machine. Flutter compiles the project's own
# location into the app (the generated plugin registrant's path), so building
# in place would ship the home folder's name; package_sideload_ipa.sh refuses
# that.
#
# Usage:
#   ./tool/release_ios.sh 1.3.0      # -> build/sideload/app-release.ipa + source.json
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: $0 <version>   (must match pubspec.yaml)}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "REFUSING — commit or stash your changes first: a release is built from the committed code" >&2
  exit 1
fi

WT=/tmp/auvy-release
git worktree remove --force "$WT" >/dev/null 2>&1 || true
rm -rf "$WT"
git worktree prune   # forgets a checkout whose folder was deleted by hand
git worktree add --detach "$WT" HEAD >/dev/null
trap 'git worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT
echo "building $(git rev-parse --short HEAD) in $WT"

# What git doesn't carry: the build's keys.
[[ -f .env ]] && cp .env "$WT/.env"

( cd "$WT" && ./tool/build_ios.sh release && ./tool/package_sideload_ipa.sh "$VERSION" )

mkdir -p build/sideload
cp "$WT/build/sideload/app-release.ipa" "$WT/build/sideload/source.json" build/sideload/
echo
echo "ready in build/sideload/: app-release.ipa and source.json (version $VERSION)"
