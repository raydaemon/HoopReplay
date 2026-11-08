#!/usr/bin/env bash
set -euo pipefail

# Deletes every exported report (JSON game exports, statistics PDFs) from
# Downloads/HoopReplay on the device. Pull them first with android-report-pull.sh
# if you still need them.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_FILE="$PROJECT_DIR/data/devices.txt"
DEVICE_SERIAL="${1:-}"
REMOTE_DIR="/sdcard/Download/HoopReplay"

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

if ! adb devices | awk -v serial="$DEVICE_SERIAL" '$1 == serial && $2 == "device" { found = 1 } END { exit !found }'; then
  echo "Error: Android device $DEVICE_SERIAL is not available." >&2
  exit 1
fi

REMOTE_FILES="$(adb -s "$DEVICE_SERIAL" shell "ls -1 $REMOTE_DIR 2>/dev/null" | tr -d '\r')"
if [[ -z "$REMOTE_FILES" ]]; then
  echo "$REMOTE_DIR is already empty on $DEVICE_SERIAL."
  exit 0
fi

DELETED=0
while IFS= read -r REMOTE_FILE; do
  [[ -z "$REMOTE_FILE" ]] && continue
  # adb shell reads stdin, which would swallow the rest of the file list this loop is reading.
  adb -s "$DEVICE_SERIAL" shell rm -f "'$REMOTE_DIR/$REMOTE_FILE'" </dev/null
  # MediaStore keeps serving stale entries until the index drops the deleted row.
  adb -s "$DEVICE_SERIAL" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://$REMOTE_DIR/$REMOTE_FILE'" </dev/null >/dev/null 2>&1 || true
  echo "Deleted $REMOTE_FILE"
  DELETED=$((DELETED + 1))
done <<< "$REMOTE_FILES"

echo "$DELETED file(s) deleted from $REMOTE_DIR on $DEVICE_SERIAL"
