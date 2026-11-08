#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/ios"
DERIVED_DATA="$PROJECT_DIR/build-device"
BUNDLE_ID="com.hoopreplay.ios"
DEVICE_ID="${1:-}"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Error: full Xcode is required." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "Looking for a connected iPhone 13..."
  DEVICE_ID="$(
    xcrun devicectl list devices |
      awk '/iPhone 13([^0-9]|$)/ {
        for (field = 1; field <= NF; field++) {
          if (!device && $field ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{16,}$/) {
            device = $field
          }
        }
      }
      END { print device }'
  )"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "Error: no connected iPhone 13 was found." >&2
  echo "Connect and unlock the phone, enable Developer Mode, or pass its device identifier as the first argument." >&2
  exit 1
fi

BUILD_DEVICE_ID="$(
  xcrun devicectl device info details --device "$DEVICE_ID" |
    awk 'tolower($2) == "udid:" && !udid { udid = $3 }
         END { print udid }'
)"
if [[ -z "$BUILD_DEVICE_ID" ]]; then
  echo "Error: could not determine the Xcode UDID for device $DEVICE_ID." >&2
  exit 1
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  DEVELOPMENT_TEAM="$(
    security find-identity -v -p codesigning 2>/dev/null |
      sed -n 's/.*Developer ID Application: ConnectedAI LLC (\([A-Z0-9]\{10\}\)).*/\1/p'
  )"
fi
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Error: no Apple development team was found. Set DEVELOPMENT_TEAM to its 10-character Team ID." >&2
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
    printf 'HOOPREPLAY_SUPABASE_URL = https:/$()/%s\n' "${NEXT_PUBLIC_SUPABASE_URL#https://}"
    printf 'HOOPREPLAY_SUPABASE_ANON_KEY = %s\n' "${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}"
    printf 'HOOPREPLAY_SYNC_SPACE = %s\n' "${NEXT_PUBLIC_HOOPREPLAY_SYNC_SPACE:-}"
  } > "$SYNC_XCCONFIG"
fi

echo "Building HoopReplay for $BUILD_DEVICE_ID..."
set -- xcodebuild \
  -quiet \
  -project HoopReplay.xcodeproj \
  -scheme HoopReplay \
  -configuration Debug \
  -destination "id=$BUILD_DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates
if [[ -n "$SYNC_XCCONFIG" ]]; then
  set -- "$@" -xcconfig "$SYNC_XCCONFIG"
fi
set -- "$@" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
set -- "$@" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Automatic \
  build
"$@"

APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/HoopReplay.app"
if [[ ! -d "$APP" ]]; then
  echo "Error: iOS app was not generated at $APP" >&2
  exit 1
fi

echo "Installing HoopReplay..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo "Launching HoopReplay..."
for attempt in {1..60}; do
  lock_state="$(xcrun devicectl device info lockState --device "$DEVICE_ID" 2>/dev/null || true)"
  if [[ "$lock_state" == *"passcodeRequired: false"* ]]; then
    break
  fi
  if [[ "$attempt" -eq 1 ]]; then
    echo "Waiting up to 60 seconds for the iPhone to be unlocked..."
  fi
  sleep 1
done

if [[ "$lock_state" != *"passcodeRequired: false"* ]]; then
  echo "Error: the iPhone is still locked. Unlock it and run the script again." >&2
  exit 1
fi
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

echo "HoopReplay is running on the connected iPhone 13."
