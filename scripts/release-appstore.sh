#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/ios"
PLIST="$PROJECT_DIR/HoopReplay/Info.plist"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
export_dir="$PROJECT_DIR/build-account-delete/export-$version-$build"
ipa="$export_dir/HoopReplay.ipa"

if [[ ! -f "$ipa" ]]; then
  echo "Release IPA not found; building $version ($build)..."
  "$ROOT_DIR/scripts/archive-ios-release.sh"
fi

[[ -f "$ipa" ]] || { echo "Error: IPA was not generated: $ipa" >&2; exit 1; }

ipa_info="$(mktemp "${TMPDIR:-/tmp}/hoopreplay-ipa-info.XXXXXX.plist")"
trap 'rm -f "$ipa_info"' EXIT
unzip -p "$ipa" Payload/HoopReplay.app/Info.plist > "$ipa_info"
ipa_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ipa_info")"
ipa_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ipa_info")"
[[ "$ipa_version" == "$version" && "$ipa_build" == "$build" ]] || {
  echo "Error: IPA version $ipa_version ($ipa_build) does not match source $version ($build)" >&2
  exit 1
}

if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_KEY_PATH:-}" && -n "${ASC_API_ISSUER:-}" ]]; then
  echo "Uploading HoopReplay $ipa_version ($ipa_build) to App Store Connect..."
  xcrun altool --upload-app --type ios --file "$ipa" \
    --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER" \
    --p8-file-path "$ASC_API_KEY_PATH"
elif [[ -n "${ASC_USERNAME:-}" && -n "${ASC_APP_PASSWORD:-}" ]]; then
  echo "Uploading HoopReplay $ipa_version ($ipa_build) to App Store Connect..."
  xcrun altool --upload-app --type ios --file "$ipa" \
    --username "$ASC_USERNAME" --password "$ASC_APP_PASSWORD"
else
  echo "IPA is ready: $ipa"
  echo "Set ASC_API_KEY_ID + ASC_API_KEY_PATH + ASC_API_ISSUER, or ASC_USERNAME + ASC_APP_PASSWORD, then rerun." >&2
  exit 2
fi

echo "Upload submitted for HoopReplay $ipa_version ($ipa_build)."
