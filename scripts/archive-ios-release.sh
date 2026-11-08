#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/ios"
PLIST="$PROJECT_DIR/HoopReplay/Info.plist"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
archive_path="$PROJECT_DIR/build-account-delete/HoopReplay-$version-$build.xcarchive"
export_path="$PROJECT_DIR/build-account-delete/export-$version-$build"

# A release without the Supabase settings cannot sign in, sync, or delete an account.
[[ -f "$ROOT_DIR/web/.env.local" ]] || { echo "Error: web/.env.local is required for the Supabase settings" >&2; exit 1; }
set -a
source "$ROOT_DIR/web/.env.local"
set +a
[[ "${NEXT_PUBLIC_SUPABASE_URL:-}" == https://* && -n "${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}" ]] || {
  echo "Error: NEXT_PUBLIC_SUPABASE_URL (https://) and NEXT_PUBLIC_SUPABASE_ANON_KEY must be set" >&2
  exit 1
}
sync_xcconfig="$(mktemp "${TMPDIR:-/tmp}/hoopreplay-sync.XXXXXX.xcconfig")"
trap 'rm -f "$sync_xcconfig"' EXIT
{
  printf 'HOOPREPLAY_SUPABASE_URL = https:/$()/%s\n' "${NEXT_PUBLIC_SUPABASE_URL#https://}"
  printf 'HOOPREPLAY_SUPABASE_ANON_KEY = %s\n' "$NEXT_PUBLIC_SUPABASE_ANON_KEY"
  printf 'HOOPREPLAY_SYNC_SPACE = %s\n' "${NEXT_PUBLIC_HOOPREPLAY_SYNC_SPACE:-}"
} > "$sync_xcconfig"

rm -rf "$archive_path" "$export_path"
xcodebuild \
  -project "$PROJECT_DIR/HoopReplay.xcodeproj" \
  -scheme HoopReplay \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -xcconfig "$sync_xcconfig" \
  -allowProvisioningUpdates \
  archive

app_plist="$archive_path/Products/Applications/HoopReplay.app/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :HOOPREPLAY_SUPABASE_URL' "$app_plist")" == https://* ]] || {
  echo "Error: the archived app has no Supabase URL" >&2
  exit 1
}

cat > "$export_path.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>538QL62JD5</string>
<key>uploadSymbols</key><true/>
<key>uploadBitcode</key><false/>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

# Without a signed-in Xcode account the distribution certificate and profile come from
# App Store Connect through the API key, so pass it when it is configured.
auth_flags=()
if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_KEY_PATH:-}" && -n "${ASC_API_ISSUER:-}" ]]; then
  auth_flags=(-authenticationKeyPath "$ASC_API_KEY_PATH" -authenticationKeyID "$ASC_API_KEY_ID" -authenticationKeyIssuerID "$ASC_API_ISSUER")
fi
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_path.plist" \
  -allowProvisioningUpdates "${auth_flags[@]}"

rm -f "$export_path.plist"
echo "Release archive: $archive_path"
echo "Release IPA: $export_path/HoopReplay.ipa"
