#!/usr/bin/env bash
set -euo pipefail

# Usage: release-android.sh [--with-web]
#   --with-web  also redeploy the website (scripts/web-deploy.sh); skipped by default
WITH_WEB=0
for arg in "$@"; do
  case "$arg" in
    --with-web) WITH_WEB=1 ;;
    -h|--help) echo "Usage: $0 [--with-web]"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; echo "Usage: $0 [--with-web]" >&2; exit 1 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
WEB_PAGE="$ROOT_DIR/web/app/download/page.tsx"
RELEASES_JSON="$ROOT_DIR/android/HoopReplay-releases.json"
SUPABASE_PROFILE="${SUPABASE_PROFILE:-$HOME/.supabase/profiles/connectedai.yaml}"
SUPABASE_PROJECT_REF="${SUPABASE_PROJECT_REF:-ugpkignlnssfllfbznlq}"
CREDENTIALS_FILE="${HOOPREPLAY_CREDENTIALS_FILE:-$HOME/GDrive/HoopReplay/hoopreplay-upload-credentials.txt}"
KEYSTORE_FILE="${HOOPREPLAY_KEYSTORE_FILE:-$HOME/GDrive/HoopReplay/hoopreplay.jks}"

if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi
if [[ -z "${ANDROID_SDK_ROOT:-}" && -n "${ANDROID_HOME:-}" ]]; then
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi
if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME" ]]; then
  echo "Android SDK not found. Set ANDROID_HOME or install it at $HOME/Library/Android/sdk." >&2
  exit 1
fi

command -v supabase >/dev/null 2>&1 || { echo "Missing required command: supabase" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "Missing required command: shasum" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "Missing required command: unzip" >&2; exit 1; }
APK_SIGNER=""
for candidate in "$ANDROID_HOME"/build-tools/*/apksigner; do
  [[ -x "$candidate" ]] && APK_SIGNER="$candidate"
done
[[ -n "$APK_SIGNER" ]] || { echo "Missing Android SDK build-tools/apksigner" >&2; exit 1; }
[[ -f "$SUPABASE_PROFILE" ]] || { echo "Missing Supabase profile: $SUPABASE_PROFILE" >&2; exit 1; }
[[ -f "$CREDENTIALS_FILE" ]] || { echo "Missing signing credentials backup: $CREDENTIALS_FILE" >&2; exit 1; }
[[ -f "$KEYSTORE_FILE" ]] || { echo "Missing release keystore: $KEYSTORE_FILE" >&2; exit 1; }

STORE_PASSWORD="$(sed -n 's/^Store password: //p' "$CREDENTIALS_FILE")"
KEY_ALIAS="$(sed -n 's/^Alias: //p' "$CREDENTIALS_FILE")"
KEY_PASSWORD="$(sed -n 's/^Key password: //p' "$CREDENTIALS_FILE")"
[[ -n "$STORE_PASSWORD" && -n "$KEY_ALIAS" && -n "$KEY_PASSWORD" ]] || { echo "Invalid signing credentials backup" >&2; exit 1; }

VERSION_CODE="$(sed -n 's/^[[:space:]]*versionCode = \([0-9][0-9]*\)$/\1/p' "$ANDROID_DIR/HoopReplay/build.gradle.kts")"
VERSION_NAME="$(sed -n 's/^[[:space:]]*versionName = "\([^"]*\)"$/\1/p' "$ANDROID_DIR/HoopReplay/build.gradle.kts")"
[[ -n "$VERSION_CODE" && -n "$VERSION_NAME" ]] || { echo "Unable to read Android version" >&2; exit 1; }

NEXT_VERSION_CODE="$VERSION_CODE"
NEXT_VERSION="$VERSION_NAME"

echo "Building signed Android release APK v$NEXT_VERSION (version code $NEXT_VERSION_CODE)..."
if [[ -x "$ANDROID_DIR/gradlew" ]]; then
  "$ANDROID_DIR/gradlew" -p "$ANDROID_DIR" \
    -PHOOPREPLAY_RELEASE_STORE_FILE="$KEYSTORE_FILE" \
    -PHOOPREPLAY_RELEASE_STORE_PASSWORD="$STORE_PASSWORD" \
    -PHOOPREPLAY_RELEASE_KEY_ALIAS="$KEY_ALIAS" \
    -PHOOPREPLAY_RELEASE_KEY_PASSWORD="$KEY_PASSWORD" \
    :HoopReplay:clean :HoopReplay:assembleRelease
else
  echo "Missing Android Gradle wrapper: $ANDROID_DIR/gradlew" >&2
  exit 1
fi

APK="$ANDROID_DIR/HoopReplay/build/outputs/apk/release/app-release.apk"
if [[ ! -f "$APK" ]]; then
  APK="$ANDROID_DIR/HoopReplay/build/outputs/apk/release/HoopReplay-release.apk"
fi
if [[ ! -f "$APK" ]]; then
  unsigned_apk="$ANDROID_DIR/HoopReplay/build/outputs/apk/release/app-release-unsigned.apk"
  if [[ -f "$unsigned_apk" ]]; then
    echo "Release APK is unsigned. Configure HOOPREPLAY_RELEASE_STORE_FILE, HOOPREPLAY_RELEASE_STORE_PASSWORD, HOOPREPLAY_RELEASE_KEY_ALIAS, and HOOPREPLAY_RELEASE_KEY_PASSWORD in android/local.properties or Gradle properties." >&2
  else
    echo "APK was not generated: $APK" >&2
  fi
  exit 1
fi

# Never publish an unsigned or invalid artifact. APK v2/v3 signatures live in
# the APK signing block, so use the Android SDK verifier rather than jarsigner.
if ! "$APK_SIGNER" verify --verbose "$APK" >/dev/null; then
  echo "Release APK is not signed: $APK" >&2
  echo "Check the release keystore credentials and Gradle signing configuration." >&2
  exit 1
fi

APK_NAME="HoopReplay-$NEXT_VERSION.apk"
APK_SIZE_MB="$(awk -v bytes="$(stat -f '%z' "$APK")" 'BEGIN { printf "%.0f", bytes / 1048576 }')"
APK_SHA256="$(shasum -a 256 "$APK" | awk '{print $1}')"

python3 - "$RELEASES_JSON" "$NEXT_VERSION" "$NEXT_VERSION_CODE" "$APK_SIZE_MB" "$APK_SHA256" "$APK_NAME" <<'PY'
import json
from pathlib import Path
import sys

path, version, version_code, size_mb, sha256, apk_name = sys.argv[1:]
release = {
    "version": version,
    "versionCode": int(version_code),
    "sizeMb": size_mb,
    "minAndroid": "Android 10",
    "sha256": sha256,
    "url": f"https://ugpkignlnssfllfbznlq.supabase.co/storage/v1/object/public/downloads/android/{apk_name}",
}
Path(path).write_text(json.dumps({"latest": release, "releases": [release]}, indent=2) + "\n")
PY

echo "Uploading $APK_NAME to Supabase Storage..."
supabase --profile "$SUPABASE_PROFILE" storage rm "ss:///downloads/android/$APK_NAME" \
  --experimental --project-ref "$SUPABASE_PROJECT_REF" --yes >/dev/null 2>&1 || true
supabase --profile "$SUPABASE_PROFILE" storage cp "$APK" "ss:///downloads/android/$APK_NAME" \
  --experimental --project-ref "$SUPABASE_PROJECT_REF" --content-type application/vnd.android.package-archive \
  --cache-control "public, max-age=3600"
RELEASES_UPLOAD_FILE="${TMPDIR:-/tmp}/HoopReplay-releases-$$.bin"
trap 'rm -f "$RELEASES_UPLOAD_FILE"' EXIT
cp "$RELEASES_JSON" "$RELEASES_UPLOAD_FILE"
supabase --profile "$SUPABASE_PROFILE" storage rm "ss:///downloads/android/HoopReplay-releases.json" \
  --experimental --project-ref "$SUPABASE_PROJECT_REF" --yes >/dev/null 2>&1 || true
supabase --profile "$SUPABASE_PROFILE" storage cp "$RELEASES_UPLOAD_FILE" "ss:///downloads/android/HoopReplay-releases.json" \
  --experimental --project-ref "$SUPABASE_PROJECT_REF" --content-type text/plain \
  --cache-control "public, max-age=60"

if [[ "$WITH_WEB" == 1 ]]; then
  echo "Deploying the website download page to production..."
  "$ROOT_DIR/scripts/web-deploy.sh"
else
  echo "Skipping website deploy (pass --with-web to redeploy)."
fi

echo "Android release published: $APK_NAME"
echo "Version code: $NEXT_VERSION_CODE"
echo "SHA-256: $APK_SHA256"

# Prove the published build installs the way a user gets it: on every connected
# Motorola or Pixel phone, open the download page in Chrome, download the APK,
# and walk the installer; the script fails if the phone does not end up on
# this version code. With no such phone connected it just says so.
echo "Installing from the download page on connected Motorola / Pixel phones..."
"$ROOT_DIR/scripts/android-install-from-web.sh"
