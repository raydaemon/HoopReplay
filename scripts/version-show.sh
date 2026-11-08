#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_FILE="$ROOT_DIR/android/HoopReplay/build.gradle.kts"
IOS_FILE="$ROOT_DIR/ios/HoopReplay/Info.plist"

[[ -f "$ANDROID_FILE" ]] || { echo "Missing Android Gradle file: $ANDROID_FILE" >&2; exit 1; }
[[ -f "$IOS_FILE" ]] || { echo "Missing iOS Info.plist: $IOS_FILE" >&2; exit 1; }

android_code="$(sed -n 's/^[[:space:]]*versionCode = \([0-9][0-9]*\)$/\1/p' "$ANDROID_FILE")"
android_name="$(sed -n 's/^[[:space:]]*versionName = "\([^"]*\)"$/\1/p' "$ANDROID_FILE")"
ios_name="$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' "$IOS_FILE")"
ios_code="$(sed -n '/CFBundleVersion/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' "$IOS_FILE")"

[[ -n "$android_code" && -n "$android_name" ]] || { echo "Unable to read Android version" >&2; exit 1; }
[[ -n "$ios_name" && -n "$ios_code" ]] || { echo "Unable to read iOS version" >&2; exit 1; }

echo "Android: $android_name ($android_code)"
echo "iOS:     $ios_name ($ios_code)"
