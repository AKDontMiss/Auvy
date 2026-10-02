#!/usr/bin/env bash
# Package the built Runner.app as the IPA a SideStore source points at.
#
# The published IPA must carry no signature: a development-signed app embeds
# the team name, the UDIDs of every device on the provisioning profile, and a
# certificate named after the Apple ID's email address. SideStore re-signs
# every app with the installing user's own Apple ID, so none of that is needed.
#
# Usage:
#   ./tool/build_ios.sh release
#   ./tool/package_sideload_ipa.sh 1.3.0        # -> build/sideload/app-release.ipa
#                                               #    build/sideload/source.json
#
# The final check refuses to leave an IPA behind if any identifier survived.
# It also writes the release's source.json (the SideStore source), with the
# size, version, build and download URL taken from the IPA itself, so none of
# them is copied by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: $0 <version>}"
APP="build/ios/iphoneos/Runner.app"
OUT_DIR="build/sideload"
# The same name every release, like app-release.apk, so the download URL can
# point at the newest release whatever its tag is spelled like.
IPA="$OUT_DIR/app-release.ipa"

[[ -d "$APP" ]] || { echo "no $APP — run ./tool/build_ios.sh release first" >&2; exit 1; }

# The version asked for must be the version built, or SideStore offers an update
# the app then doesn't recognise (and the release tag would lie).
PLIST="$APP/Info.plist"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$PLIST")
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "REFUSING — asked for $VERSION but the built app is $BUILT_VERSION (bump pubspec.yaml and rebuild)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload" "$OUT_DIR"
cp -R "$APP" "$WORK/Payload/Runner.app"
STAGED="$WORK/Payload/Runner.app"

rm -f "$STAGED/embedded.mobileprovision"

# Every Mach-O, deepest first, so a framework is unsigned before its parent.
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    codesign --remove-signature "$f" 2>/dev/null || true
  fi
done < <(find "$STAGED" -type f -print0 | sort -rz)
find "$STAGED" -type d -name _CodeSignature -prune -exec rm -rf {} +

# Debug symbols name the object files they came from, which live in Xcode's
# DerivedData under the build machine's home folder. Only debugging symbols go
# (-S): the symbols frameworks export and the app links against stay.
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    xcrun strip -S "$f" 2>/dev/null || true
  fi
done < <(find "$STAGED" -type f -print0)

# ── Refuse to publish anything that still identifies the builder ────────────
fail=0
if find "$STAGED" -name embedded.mobileprovision | grep -q .; then
  echo "REFUSING — a provisioning profile survived" >&2; fail=1
fi
if find "$STAGED" -type d -name _CodeSignature | grep -q .; then
  echo "REFUSING — a _CodeSignature directory survived" >&2; fail=1
fi
# Any leftover certificate chain names Apple's developer CA.
if grep -rlaq 'Apple Development:\|Apple Worldwide Developer Relations' "$STAGED"; then
  echo "REFUSING — a signing certificate survived in:" >&2
  grep -rla 'Apple Development:\|Apple Worldwide Developer Relations' "$STAGED" >&2
  fail=1
fi
# No path on the build machine. Source paths are remapped at compile time
# (ios/Podfile, RUSTFLAGS in build_ios.sh) and the one Dart path, the project
# folder itself, only disappears when building from a neutral folder: use
# ./tool/release_ios.sh, which does that.
if grep -rlaqF "$HOME/" "$STAGED"; then
  echo "REFUSING — the app still names a folder on this machine ($HOME/…) in:" >&2
  grep -rlaF "$HOME/" "$STAGED" | sed "s#^$STAGED/#  #" | head -20 >&2
  echo "Build releases with ./tool/release_ios.sh <version>." >&2
  fail=1
fi
[[ $fail -eq 0 ]] || exit 1

rm -f "$IPA"
( cd "$WORK" && zip -qry - Payload ) > "$IPA"

SIZE=$(stat -f %z "$IPA")
echo "wrote $IPA"
echo "  size   : $SIZE bytes"
echo "  sha256 : $(shasum -a 256 "$IPA" | cut -d' ' -f1)"

# ── source.json, attached to the same release as the IPA ────────────────────
# Both URLs go through releases/latest/download/, which GitHub redirects to that
# file in the newest release: the source URL people add finds this file, and
# this file finds the IPA beside it, whatever the tag. The tag is the version
# (v1.3.0); a release must raise the version to be offered as an update.
TAG="v$VERSION"
REPO="AKDontMiss/Auvy"
SOURCE="$OUT_DIR/source.json"
python3 - "$SOURCE" "$VERSION" "$BUILD_NUMBER" "$BUNDLE_ID" "$MIN_OS" "$SIZE" "$REPO" "$(basename "$IPA")" <<'PY'
import json, sys, datetime
out, version, build, bundle, min_os, size, repo, ipa = sys.argv[1:]
source = {
    "name": "Auvy",
    "identifier": "com.auvy.source",
    "subtitle": "Music, podcasts, radio and audiobooks.",
    "website": f"https://github.com/{repo}",
    "apps": [{
        "name": "Auvy",
        "bundleIdentifier": bundle,
        "developerName": "Auvy",
        "subtitle": "Music, podcasts, radio and audiobooks.",
        "localizedDescription": "Music, podcasts, radio and audiobooks. "
            "No ads, no tracking. Your library stays on your phone.",
        "iconURL": f"https://raw.githubusercontent.com/{repo}/main/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
        "tintColor": "#53B1E1",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.date.today().isoformat(),
            "downloadURL": f"https://github.com/{repo}/releases/latest/download/{ipa}",
            "size": int(size),
            "minOSVersion": min_os,
        }],
    }],
}
with open(out, "w") as f:
    json.dump(source, f, indent=2)
    f.write("\n")
PY
echo "wrote $SOURCE"
echo "  tag    : $TAG   (the version; the URLs follow the newest release)"
echo "  attach : app-release.ipa, source.json and app-release.apk to that release"
