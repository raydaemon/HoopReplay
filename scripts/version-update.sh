#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADLE_FILE="$ROOT_DIR/android/HoopReplay/build.gradle.kts"
IOS_PLIST="$ROOT_DIR/ios/HoopReplay/Info.plist"
# xcodegen regenerates Info.plist from project.yml, so the iOS version lives in both.
IOS_PROJECT="$ROOT_DIR/ios/project.yml"

usage() {
  echo "Usage: scripts/version-update.sh [version]" >&2
  echo "Without a version, stamps today's build: (year-2020).month.DDNN, e.g. 6.10.0601 is 2026-10-06 build 01." >&2
  exit 1
}

[[ $# -le 1 ]] || usage
[[ -f "$GRADLE_FILE" ]] || { echo "Missing Gradle file: $GRADLE_FILE" >&2; exit 1; }
[[ -f "$IOS_PLIST" ]] || { echo "Missing iOS Info.plist: $IOS_PLIST" >&2; exit 1; }
[[ -f "$IOS_PROJECT" ]] || { echo "Missing iOS project.yml: $IOS_PROJECT" >&2; exit 1; }

version_code="$(sed -n 's/^[[:space:]]*versionCode = \([0-9][0-9]*\)$/\1/p' "$GRADLE_FILE")"
current_version="$(sed -n 's/^[[:space:]]*versionName = "\([^"]*\)"$/\1/p' "$GRADLE_FILE")"
[[ "$version_code" =~ ^[0-9]+$ && -n "$current_version" ]] || { echo "Unable to read current Android version" >&2; exit 1; }

ios_version="$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' "$IOS_PLIST")"
ios_build="$(sed -n '/CFBundleVersion/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' "$IOS_PLIST")"
[[ -n "$ios_version" && -n "$ios_build" ]] || { echo "Unable to read current iOS version" >&2; exit 1; }

version_number() {
  local major minor patch
  IFS=. read -r major minor patch <<< "$1"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || return 1
  echo $((major * 1000000 + minor * 10000 + 10#$patch))
}

# Both platforms always ship the same version; start from whichever one is ahead.
android_number="$(version_number "$current_version")" || { echo "Android version is not numeric semver: $current_version" >&2; exit 1; }
ios_number="$(version_number "$ios_version" || echo 0)"
base_version="$current_version"
(( ios_number > android_number )) && base_version="$ios_version"

if [[ $# -eq 1 ]]; then
  next_version="$1"
else
  # Date-stamped: the patch is DDNN, NN counting today's builds from 01.
  today="$(( $(date +%Y) - 2020 )).$(date +%-m)"
  day="$(date +%d)"
  IFS=. read -r major minor patch <<< "$base_version"
  seq=1
  if [[ "$major.$minor" == "$today" && ${#patch} -eq 4 && "${patch:0:2}" == "$day" ]]; then
    seq=$((10#${patch:2:2} + 1))
  fi
  next_version="$today.$day$(printf '%02d' "$seq")"
fi

[[ "$next_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Version must use numeric major.minor.patch format: $next_version" >&2
  exit 1
}

IFS=. read -r next_major next_minor next_patch <<< "$next_version"
next_code=$((next_major * 1000000 + next_minor * 10000 + 10#$next_patch))

if [[ "$next_version" == "$current_version" && "$next_code" == "$version_code" && "$next_version" == "$ios_version" && "$next_code" == "$ios_build" ]]; then
  echo "Android and iOS are already $next_version ($next_code); no changes made." >&2
  exit 1
fi
(( next_code >= android_number && next_code >= ios_number )) || {
  echo "Version $next_version is older than the current Android $current_version or iOS $ios_version" >&2
  exit 1
}

sed -i '' \
  -e "s/versionCode = $version_code/versionCode = $next_code/" \
  -e "s/versionName = \"$current_version\"/versionName = \"$next_version\"/" \
  "$GRADLE_FILE"

sed -i '' \
  -e "/CFBundleShortVersionString/{n;s#<string>[^<]*</string>#<string>$next_version</string>#;}" \
  -e "/CFBundleVersion/{n;s#<string>[^<]*</string>#<string>$next_code</string>#;}" \
  "$IOS_PLIST"
sed -i '' \
  -e "s/^\([[:space:]]*CFBundleShortVersionString:\).*/\1 \"$next_version\"/" \
  -e "s/^\([[:space:]]*CFBundleVersion:\).*/\1 \"$next_code\"/" \
  "$IOS_PROJECT"

echo "Android version updated: $current_version ($version_code) -> $next_version ($next_code)"
echo "iOS version updated: $ios_version ($ios_build) -> $next_version ($next_code)"
