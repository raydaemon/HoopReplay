#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/android"
DEVICE_FILE="$ROOT_DIR/data/devices.txt"
DEVICE_SERIAL="${1:-}"
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

if [[ -x /usr/libexec/java_home ]]; then
  if ! JDK_21_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null)"; then
    echo "Error: JDK 21 is not installed." >&2
    exit 1
  fi
  export JAVA_HOME="$JDK_21_HOME"
  export PATH="$JAVA_HOME/bin:$PATH"
elif [[ ! -x "${JAVA_HOME:-}/bin/java" ]]; then
  echo "Error: JAVA_HOME does not point to an installed JDK 21." >&2
  exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: adb is not available. Add Android SDK platform-tools to PATH." >&2
  exit 1
fi

if [[ -z "$DEVICE_SERIAL" ]]; then
  CONNECTED_DEVICES="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
  DEVICE_COUNT="$(printf '%s\n' "$CONNECTED_DEVICES" | awk 'NF { count++ } END { print count + 0 }')"
  if [[ "$DEVICE_COUNT" -eq 1 ]]; then
    DEVICE_SERIAL="$CONNECTED_DEVICES"
  elif [[ "$DEVICE_COUNT" -eq 0 ]]; then
    echo "Error: no authorized Android device is connected." >&2
    exit 1
  else
    if [[ -f "$DEVICE_FILE" ]]; then
      while IFS= read -r PREFERRED_DEVICE; do
        for CONNECTED_DEVICE in $CONNECTED_DEVICES; do
          if [[ "$PREFERRED_DEVICE" == "$CONNECTED_DEVICE" ]]; then
            DEVICE_SERIAL="$PREFERRED_DEVICE"
            break 2
          fi
        done
      done < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$DEVICE_FILE")
    fi
    if [[ -z "$DEVICE_SERIAL" ]]; then
      echo "Error: multiple Android devices are connected, but none match $DEVICE_FILE." >&2
      printf '  %s\n' $CONNECTED_DEVICES >&2
      echo "Add a preferred device serial to $DEVICE_FILE or use: $0 <device-serial>" >&2
      exit 1
    fi
  fi
fi

if [[ -x "$PROJECT_DIR/gradlew" ]]; then
  GRADLE=("$PROJECT_DIR/gradlew")
elif command -v gradle >/dev/null 2>&1; then
  GRADLE=(gradle)
else
  GRADLE_BIN="$(find "$HOME/.gradle/wrapper/dists" -path '*/gradle-*/bin/gradle' -type f 2>/dev/null | sort -V | tail -n 1)"
  if [[ -z "$GRADLE_BIN" ]]; then
    echo "Error: Gradle was not found. Open the project in Android Studio once or add Gradle to PATH." >&2
    exit 1
  fi
  GRADLE=("$GRADLE_BIN")
fi

echo "Building HoopReplay..."
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

echo "Installing on $DEVICE_SERIAL..."
adb -s "$DEVICE_SERIAL" install -r "$APK"

echo "Launching HoopReplay..."
adb -s "$DEVICE_SERIAL" shell am start -n com.hoopreplay.android/com.connectedai.hoopreplay.MainActivity

echo "HoopReplay is running on $DEVICE_SERIAL."
