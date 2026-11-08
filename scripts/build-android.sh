#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/android"
KEYSTORE_FILE="${HOOPREPLAY_KEYSTORE_FILE:-$HOME/GDrive/HoopReplay/hoopreplay.jks}"
CREDENTIALS_FILE="${HOOPREPLAY_CREDENTIALS_FILE:-$HOME/GDrive/HoopReplay/hoopreplay-upload-credentials.txt}"

[[ -f "$KEYSTORE_FILE" ]] || { echo "Error: missing release keystore: $KEYSTORE_FILE" >&2; exit 1; }
[[ -f "$CREDENTIALS_FILE" ]] || { echo "Error: missing signing credentials backup: $CREDENTIALS_FILE" >&2; exit 1; }

STORE_PASSWORD="$(sed -n 's/^Store password: //p' "$CREDENTIALS_FILE")"
KEY_ALIAS="$(sed -n 's/^Alias: //p' "$CREDENTIALS_FILE")"
KEY_PASSWORD="$(sed -n 's/^Key password: //p' "$CREDENTIALS_FILE")"
[[ -n "$STORE_PASSWORD" && -n "$KEY_ALIAS" && -n "$KEY_PASSWORD" ]] || { echo "Error: invalid signing credentials backup" >&2; exit 1; }

if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi
if [[ -z "${ANDROID_SDK_ROOT:-}" && -n "${ANDROID_HOME:-}" ]]; then
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi

if [[ ! -x "${JAVA_HOME:-}/bin/java" ]] && [[ -x /usr/libexec/java_home ]]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  export JAVA_HOME
fi

if [[ -x "$PROJECT_DIR/gradlew" ]]; then
  GRADLE=("$PROJECT_DIR/gradlew")
elif command -v gradle >/dev/null 2>&1; then
  GRADLE=(gradle)
else
  GRADLE_CACHE="${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper/dists"
  GRADLE_BIN="$(find "$GRADLE_CACHE" -path '*/gradle-8.13/bin/gradle' -type f 2>/dev/null | head -n 1)"
  if [[ -z "$GRADLE_BIN" ]]; then
    GRADLE_BIN="$(find "$GRADLE_CACHE" -path '*/gradle-*/bin/gradle' -type f 2>/dev/null | sort -V | tail -n 1)"
  fi
  if [[ -z "$GRADLE_BIN" ]]; then
    echo "Error: Gradle was not found. Open the project in Android Studio once or add Gradle to PATH." >&2
    exit 1
  fi
  GRADLE=("$GRADLE_BIN")
fi

echo "Building HoopReplay debug APK..."
"${GRADLE[@]}" -p "$PROJECT_DIR" \
  -PHOOPREPLAY_RELEASE_STORE_FILE="$KEYSTORE_FILE" \
  -PHOOPREPLAY_RELEASE_STORE_PASSWORD="$STORE_PASSWORD" \
  -PHOOPREPLAY_RELEASE_KEY_ALIAS="$KEY_ALIAS" \
  -PHOOPREPLAY_RELEASE_KEY_PASSWORD="$KEY_PASSWORD" \
  :HoopReplay:assembleDebug

APK="$PROJECT_DIR/HoopReplay/build/outputs/apk/debug/app-debug.apk"
if [[ ! -f "$APK" ]]; then
  APK="$PROJECT_DIR/HoopReplay/build/outputs/apk/debug/HoopReplay-debug.apk"
fi
if [[ ! -f "$APK" ]]; then
  echo "Error: debug APK was not generated." >&2
  exit 1
fi

OUTPUT_APK="$ROOT_DIR/app-debug.apk"
cp "$APK" "$OUTPUT_APK"

echo "Build complete: $OUTPUT_APK"
