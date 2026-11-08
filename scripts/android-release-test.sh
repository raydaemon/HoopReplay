#!/usr/bin/env bash
set -euo pipefail

# Build and install a locally signed Release APK for device testing.
# Signing passwords are read from the existing private credentials backup and
# are passed to Gradle only for this process; they are never written to Git.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
DEVICE_SERIAL="${1:-}"
KEYSTORE_FILE="${HOOPREPLAY_KEYSTORE_FILE:-$HOME/GDrive/HoopReplay/hoopreplay.jks}"
CREDENTIALS_FILE="${HOOPREPLAY_CREDENTIALS_FILE:-$HOME/GDrive/HoopReplay/hoopreplay-upload-credentials.txt}"
ADB_BIN="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"

[[ -x "$ADB_BIN" ]] || { echo "Missing adb: $ADB_BIN" >&2; exit 1; }
[[ -f "$KEYSTORE_FILE" ]] || { echo "Missing release keystore: $KEYSTORE_FILE" >&2; exit 1; }
[[ -f "$CREDENTIALS_FILE" ]] || { echo "Missing signing credentials backup: $CREDENTIALS_FILE" >&2; exit 1; }

CONNECTED_DEVICES="$($ADB_BIN devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
if [[ -z "$DEVICE_SERIAL" ]]; then
  DEVICE_SERIAL="$(printf '%s\n' "$CONNECTED_DEVICES" | awk 'NF { count++; first=$1 } END { if (count == 1) print first }')"
fi
[[ -n "$DEVICE_SERIAL" ]] || { echo "Pass the Pixel serial explicitly: $0 <serial>" >&2; exit 1; }

STORE_PASSWORD="$(sed -n 's/^Store password: //p' "$CREDENTIALS_FILE")"
KEY_ALIAS="$(sed -n 's/^Alias: //p' "$CREDENTIALS_FILE")"
KEY_PASSWORD="$(sed -n 's/^Key password: //p' "$CREDENTIALS_FILE")"
[[ -n "$STORE_PASSWORD" && -n "$KEY_ALIAS" && -n "$KEY_PASSWORD" ]] || { echo "Invalid signing credentials backup" >&2; exit 1; }

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
"$ANDROID_DIR/gradlew" -p "$ANDROID_DIR" \
  -PHOOPREPLAY_RELEASE_STORE_FILE="$KEYSTORE_FILE" \
  -PHOOPREPLAY_RELEASE_STORE_PASSWORD="$STORE_PASSWORD" \
  -PHOOPREPLAY_RELEASE_KEY_ALIAS="$KEY_ALIAS" \
  -PHOOPREPLAY_RELEASE_KEY_PASSWORD="$KEY_PASSWORD" \
  :HoopReplay:assembleRelease

APK="$ANDROID_DIR/HoopReplay/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || APK="$ANDROID_DIR/HoopReplay/build/outputs/apk/release/HoopReplay-release.apk"
[[ -f "$APK" ]] || { echo "Release APK not found" >&2; exit 1; }
"$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APK"
"$ADB_BIN" -s "$DEVICE_SERIAL" shell am force-stop com.hoopreplay.android
"$ADB_BIN" -s "$DEVICE_SERIAL" shell monkey -p com.hoopreplay.android 1
echo "Installed and launched signed Release build on $DEVICE_SERIAL"
