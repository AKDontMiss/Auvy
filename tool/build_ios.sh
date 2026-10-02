#!/usr/bin/env bash
# Build Auvy for iOS with the keys from .env, the way build_release.ps1 does for
# Android. Without them the build SUCCEEDS and the app cannot reach its backend:
# the Worker host falls back to an unresolvable sentinel and the sign-in gate can
# never return a verdict.
#
#   ./tool/build_ios.sh [profile|release|debug]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-release}"
DEFINES=()

if [[ -f .env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    name="${line%%=*}"
    # Every define is readable inside the app; secrets live on the Worker.
    if [[ "$name" =~ SECRET|PASSWORD|PRIVATE|TOKEN|API_KEY ]]; then
      echo "REFUSING — '$name' looks like a secret, and every define is readable inside the app. Keep it on the Worker." >&2
      exit 1
    fi
    DEFINES+=("--dart-define=${line%$'\r'}")
  done < .env
  echo "Loaded $(( ${#DEFINES[@]} )) key(s) from .env"
else
  echo "WARNING: no .env — the app will build but cannot reach its backend." >&2
fi

# Extra defines from CLI arguments (e.g. ./tool/build_ios.sh release SOME_FLAG=val)
shift || true
for extra in "$@"; do
  [[ -n "$extra" ]] && DEFINES+=("--dart-define=$extra")
done

# Cargokit builds metadata_god's Rust core from source on iOS.
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
# The Rust library (metadata_god) compiles its crates' source paths into its
# panic messages; remapped so the app names no folder on this machine.
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=~"

# NOT `set -x`: the defines carry the keys, and tracing them would print every
# value into the terminal and into any log the build output is piped to.
echo "flutter build ios --$MODE (+${#DEFINES[@]} defines, values not echoed)"
flutter build ios --"$MODE" "${DEFINES[@]}"
