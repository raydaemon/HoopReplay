#!/usr/bin/env bash
set -euo pipefail

# Usage: android-install-from-web.sh [serial ...]
#
# Installs the published Android APK on connected Motorola and Pixel phones the
# way a user would: open the download page in the phone's Chrome, tap the
# download button, accept Chrome's download prompt, open the file, and walk the
# package installer to completion. The installed versionCode is then compared
# with the release the download page advertises, so a green result means the
# whole publish -> download -> install path works.
#
# Without serials, every authorized Motorola or Google (Pixel) device is used;
# with no such phone connected the script exits 0 after saying so, so it can
# run unattended at the end of scripts/release-android.sh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_PAGE="${HOOPREPLAY_DOWNLOAD_PAGE:-https://www.hoopreplay.com/download}"
RELEASES_URL="${HOOPREPLAY_RELEASES_URL:-https://ugpkignlnssfllfbznlq.supabase.co/storage/v1/object/public/downloads/android/HoopReplay-releases.json}"
PACKAGE="com.hoopreplay.android"
MAIN_ACTIVITY="com.connectedai.hoopreplay.MainActivity"
CHROME="com.android.chrome"
TIMEOUT_SECONDS="${HOOPREPLAY_INSTALL_TIMEOUT:-420}"
UNLOCK_WAIT_SECONDS="${HOOPREPLAY_UNLOCK_WAIT:-90}"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"

if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi
ADB="${ANDROID_HOME:-}/platform-tools/adb"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"
[[ -n "$ADB" ]] || { echo "Error: adb was not found. Set ANDROID_HOME or add adb to PATH." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: missing required command: curl" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: missing required command: python3" >&2; exit 1; }

"$ADB" start-server >/dev/null 2>&1 || true

# The download page shows whatever HoopReplay-releases.json calls "latest", so
# that JSON, not the local Gradle file, defines the version a user would get.
read -r EXPECTED_VERSION EXPECTED_CODE < <(
  curl -fsS "$RELEASES_URL" | python3 -c 'import json,sys; d=json.load(sys.stdin)["latest"]; print(d["version"], d["versionCode"])'
)
[[ -n "$EXPECTED_VERSION" && "$EXPECTED_CODE" =~ ^[0-9]+$ ]] || { echo "Error: could not read the latest release from $RELEASES_URL" >&2; exit 1; }
echo "Download page offers HoopReplay $EXPECTED_VERSION (version code $EXPECTED_CODE)."

# Never use "grep -q" on a pipe here: with pipefail, grep exiting on the first
# match kills the producer with SIGPIPE and the pipeline reports failure.
prop() { "$ADB" -s "$1" shell getprop "$2" 2>/dev/null | tr -d '\r'; }

authorized_devices() {
  "$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

DEVICES=()
if (( $# > 0 )); then
  for serial in "$@"; do
    authorized_devices | grep -x "$serial" >/dev/null || { echo "Error: device $serial is not connected and authorized." >&2; exit 1; }
    DEVICES+=("$serial")
  done
else
  while IFS= read -r serial; do
    [[ -n "$serial" ]] || continue
    manufacturer="$(prop "$serial" ro.product.manufacturer | tr '[:upper:]' '[:lower:]')"
    case "$manufacturer" in
      motorola|google) DEVICES+=("$serial") ;;
    esac
  done < <(authorized_devices)
  if (( ${#DEVICES[@]} == 0 )); then
    echo "No connected Motorola or Pixel phone; skipping the download-page install test."
    echo "Connected devices:"
    "$ADB" devices -l | sed '1d;/^$/d' | sed 's/^/  /'
    exit 0
  fi
fi

installed_code() {
  "$ADB" -s "$1" shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r' | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1
}

# The install time changes even when the same version is installed again, so it
# tells a fresh install from a phone that already had this release.
install_time() {
  "$ADB" -s "$1" shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r' | sed -n 's/.*lastUpdateTime=//p' | head -1
}

# Python parser for uiautomator dumps: prints "x y label" for the first element
# (by pattern priority) whose text or content description matches.
UI_PARSER='
import os, re, sys
import xml.etree.ElementTree as ET
data = sys.stdin.read()
start = data.find("<?xml")
if start < 0:
    sys.exit(0)
try:
    root = ET.fromstring(data[start:])
except ET.ParseError:
    sys.exit(0)
nodes = []
for node in root.iter("node"):
    label = node.get("text") or node.get("content-desc") or ""
    if not label.strip():
        continue
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        continue
    nodes.append((label.strip(), (x1 + x2) // 2, (y1 + y2) // 2))
for pattern in sys.argv[1:]:
    rx = re.compile(pattern, re.IGNORECASE)
    for label, x, y in nodes:
        if rx.search(label):
            print(x, y, label)
            sys.exit(0)
if os.environ.get("HOOPREPLAY_INSTALL_DEBUG"):
    print("  [no match] " + " | ".join(label[:40] for label, _, _ in nodes), file=sys.stderr)
'

# Prints "x y label" for the first on-screen element (by priority) whose text or
# content description matches one of the given regexes, or nothing.
find_control() {
  local serial="$1"; shift
  "$ADB" -s "$serial" shell uiautomator dump /sdcard/hoopreplay-ui.xml >/dev/null 2>&1 || return 0
  "$ADB" -s "$serial" exec-out cat /sdcard/hoopreplay-ui.xml 2>/dev/null | python3 -c "$UI_PARSER" "$@"
}

tap() { "$ADB" -s "$1" shell input tap "$2" "$3" >/dev/null 2>&1 || true; }

screen_off() {
  "$ADB" -s "$1" shell dumpsys power 2>/dev/null | tr -d '\r' | grep "mWakefulness=Asleep\|mWakefulness=Dozing" >/dev/null
}

wake_device() {
  local serial="$1"
  # Keep the display on while plugged in so a 30s screen timeout cannot end
  # the flow half way through a dialog; the caller restores the setting.
  "$ADB" -s "$serial" shell svc power stayon usb >/dev/null 2>&1 || true
  if screen_off "$serial"; then
    "$ADB" -s "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    sleep 1
  fi
  # Dismiss a swipe-only lock screen; a PIN, pattern or fingerprint lock needs
  # the user, so say so and wait for them instead of failing straight away.
  if device_locked "$serial"; then
    "$ADB" -s "$serial" shell input keyevent KEYCODE_MENU >/dev/null 2>&1 || true
    sleep 1
  fi
  if device_locked "$serial"; then
    echo "  Unlock the phone to continue (waiting up to ${UNLOCK_WAIT_SECONDS}s)..."
    local waited=0
    while device_locked "$serial" && (( waited < UNLOCK_WAIT_SECONDS )); do
      sleep 3; waited=$(( waited + 3 ))
      if screen_off "$serial"; then "$ADB" -s "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true; fi
    done
    if device_locked "$serial"; then
      echo "  Error: the phone is still locked; unlock it and run scripts/android-install-from-web.sh $serial again." >&2
      return 1
    fi
  fi
}

device_locked() {
  "$ADB" -s "$1" shell dumpsys window 2>/dev/null | tr -d '\r' | grep "mDreamingLockscreen=true" >/dev/null
}

save_screenshot() {
  local serial="$1" name="$2"
  mkdir -p "$ARTIFACTS_DIR"
  "$ADB" -s "$serial" exec-out screencap -p > "$ARTIFACTS_DIR/$name" 2>/dev/null || true
  echo "  Screenshot: $ARTIFACTS_DIR/$name"
}

install_on_device() {
  local serial="$1"
  local model; model="$(prop "$serial" ro.product.model)"
  local before; before="$(installed_code "$serial")"
  local before_time; before_time="$(install_time "$serial")"
  echo "== $model ($serial): installed version code ${before:-none}"

  if ! "$ADB" -s "$serial" shell pm path "$CHROME" >/dev/null 2>&1; then
    echo "  Error: Chrome ($CHROME) is not installed on this device." >&2
    return 1
  fi

  wake_device "$serial" || return 1
  "$ADB" -s "$serial" shell 'rm -f /sdcard/Download/HoopReplay-*.apk' >/dev/null 2>&1 || true
  # Start from a fresh Chrome so no earlier download sheet or installer is left over.
  "$ADB" -s "$serial" shell am force-stop "$CHROME" >/dev/null 2>&1 || true
  "$ADB" -s "$serial" shell am force-stop com.google.android.packageinstaller >/dev/null 2>&1 || true
  "$ADB" -s "$serial" shell am force-stop com.android.packageinstaller >/dev/null 2>&1 || true

  echo "  Opening $DOWNLOAD_PAGE in Chrome..."
  local attempt
  for attempt in 1 2 3; do
    local started
    started="$("$ADB" -s "$serial" shell am start -W -a android.intent.action.VIEW -d "$DOWNLOAD_PAGE" "$CHROME" 2>&1 | tr -d '\r')"
    sleep 3
    if "$ADB" -s "$serial" shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep "topResumedActivity=.*$CHROME/" >/dev/null; then
      break
    fi
    echo "  Chrome is not in the foreground yet (attempt $attempt): ${started##*$'\n'}"
    if (( attempt == 3 )); then
      echo "  Error: could not open Chrome on this device." >&2
      save_screenshot "$serial" "android-install-failed-$serial.png"
      return 1
    fi
    sleep 3
  done

  local deadline=$(( SECONDS + TIMEOUT_SECONDS ))
  local link_tapped_at=-1 downloaded_at=-1 opened_downloads=0 last_step=""
  while (( SECONDS < deadline )); do
    if screen_off "$serial"; then wake_device "$serial" || return 1; fi
    local now; now="$(installed_code "$serial")"
    if [[ "$now" == "$EXPECTED_CODE" && "$(install_time "$serial")" != "$before_time" ]]; then
      echo "  Installed HoopReplay $EXPECTED_VERSION ($EXPECTED_CODE) from the download page."
      "$ADB" -s "$serial" shell am start -n "$PACKAGE/$MAIN_ACTIVITY" >/dev/null 2>&1 || true
      sleep 5
      save_screenshot "$serial" "android-install-$serial.png"
      return 0
    fi

    if (( downloaded_at < 0 )) && "$ADB" -s "$serial" shell 'ls /sdcard/Download/HoopReplay-*.apk' >/dev/null 2>&1; then
      downloaded_at=$SECONDS
      echo "  APK downloaded to the phone."
    fi

    # Chrome's "Open" bar disappears after a few seconds; when it is gone, open
    # the Downloads folder and tap the file there, as the page's steps describe.
    local patterns=()
    if (( downloaded_at < 0 )); then
      patterns+=('^Download APK')
    elif (( ! opened_downloads )) && (( SECONDS - downloaded_at > 8 )) && [[ -z "$(find_control "$serial" '^Open$' '^Install$' '^Update$' '^Settings$' '^More details$' '^Install without scanning$' '^Scan app$')" ]]; then
      echo "  Opening the Downloads folder..."
      "$ADB" -s "$serial" shell am start -a android.intent.action.VIEW_DOWNLOADS >/dev/null 2>&1 || true
      opened_downloads=1
      sleep 3
      continue
    fi
    # Priority order: the package installer and Play Protect, the
    # unknown-sources toggle, Chrome's download prompts (only while the download
    # is pending, because the Files app has a "Download" tab too), then the
    # file in the Downloads folder.
    patterns+=('^Install without scanning$' '^Install anyway$' '^More details$' '^Install$' '^Update$' \
      '^Allow from this source$' '^Settings$' \
      '^Continue$' '^OK$' '^Got it$' '^Open$')
    if (( downloaded_at < 0 )); then
      patterns+=('^Download anyway$' '^Download$')
    else
      patterns+=('^HoopReplay-.*\.apk$')
    fi

    local hit; hit="$(find_control "$serial" "${patterns[@]}")"
    if [[ -z "$hit" ]]; then sleep 2; continue; fi

    local x y label
    x="${hit%% *}"; hit="${hit#* }"; y="${hit%% *}"; label="${hit#* }"
    case "$label" in
      Download\ APK*)
        # Tap the page button once and give the download 20s before retrying.
        if (( link_tapped_at >= 0 )) && (( SECONDS - link_tapped_at < 20 )); then sleep 2; continue; fi
        link_tapped_at=$SECONDS ;;
      Settings)
        # Only the installer's "Settings" button leads to the unknown-sources page.
        if [[ "$last_step" != "Install" && "$last_step" != "Update" && "$last_step" != "Open" && "$last_step" != HoopReplay-* ]]; then sleep 2; continue; fi ;;
    esac
    echo "  Tap: $label"
    tap "$serial" "$x" "$y"
    last_step="$label"
    if [[ "$label" == "Allow from this source" ]]; then
      sleep 1
      "$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
    fi
    sleep 2
  done

  echo "  Error: HoopReplay $EXPECTED_VERSION ($EXPECTED_CODE) was not installed within ${TIMEOUT_SECONDS}s; installed version code is now $(installed_code "$serial")." >&2
  save_screenshot "$serial" "android-install-failed-$serial.png"
  return 1
}

status=0
for serial in "${DEVICES[@]}"; do
  install_on_device "$serial" || status=1
  "$ADB" -s "$serial" shell svc power stayon false >/dev/null 2>&1 || true
done
exit "$status"
