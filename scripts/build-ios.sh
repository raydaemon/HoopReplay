#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/ios"
DERIVED_DATA="$PROJECT_DIR/build"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Error: full Xcode is required. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

cd "$PROJECT_DIR"
xcodegen generate

SYNC_XCCONFIG=""
if [[ -f "$ROOT_DIR/web/.env.local" ]]; then
  set -a
  source "$ROOT_DIR/web/.env.local"
  set +a
  [[ "${NEXT_PUBLIC_SUPABASE_URL:-}" == https://* ]] || {
    echo "Error: NEXT_PUBLIC_SUPABASE_URL must use https://" >&2
    exit 1
  }
  SYNC_XCCONFIG="$(mktemp "${TMPDIR:-/tmp}/hoopreplay-sync.XXXXXX.xcconfig")"
  trap 'rm -f "$SYNC_XCCONFIG"' EXIT
  {
    # xcconfig treats // as a comment even inside quotes. $()/ expands to an
    # empty build setting followed by '/', preserving the URL's double slash.
    printf 'HOOPREPLAY_SUPABASE_URL = https:/$()/%s\n' "${NEXT_PUBLIC_SUPABASE_URL#https://}"
    printf 'HOOPREPLAY_SUPABASE_ANON_KEY = %s\n' "${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}"
    printf 'HOOPREPLAY_SYNC_SPACE = %s\n' "${NEXT_PUBLIC_HOOPREPLAY_SYNC_SPACE:-}"
  } > "$SYNC_XCCONFIG"
fi

build_simulator() {
  local config_args=()
  if [[ -n "$SYNC_XCCONFIG" ]]; then
    config_args=(-xcconfig "$SYNC_XCCONFIG")
  fi
  xcodebuild \
    -quiet \
    -project HoopReplay.xcodeproj \
    -scheme HoopReplay \
    -sdk iphonesimulator \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    "${config_args[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

# Xcode may briefly report no destinations immediately after XcodeGen rewrites
# the project, especially when the installed CoreSimulator service is older.
if ! build_simulator; then
  echo "Initial simulator build failed; retrying after project discovery..." >&2
  build_simulator
fi

APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/HoopReplay.app"
OUTPUT="$ROOT_DIR/HoopReplay-ios.app"
[[ -d "$APP" ]] || { echo "Error: iOS app was not generated at $APP" >&2; exit 1; }
rm -rf "$OUTPUT"
cp -R "$APP" "$OUTPUT"
echo "Build complete: $OUTPUT"
