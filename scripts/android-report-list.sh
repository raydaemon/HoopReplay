#!/usr/bin/env bash
set -euo pipefail

# Lists the exported reports (JSON game exports, statistics PDFs) sitting in
# Downloads/HoopReplay on the device, newest last. Read-only.

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

LISTING="$(adb -s "$DEVICE_SERIAL" shell "ls -trl $REMOTE_DIR 2>/dev/null" | tr -d '\r' | awk 'NF > 2 && $1 !~ /^total/')"
if [[ -z "$LISTING" ]]; then
  echo "$REMOTE_DIR is empty or missing on $DEVICE_SERIAL."
  exit 0
fi

echo "$REMOTE_DIR on $DEVICE_SERIAL:"
printf '%s\n' "$LISTING" | awk '{ size = $5; date = $6; time = $7; name = $0; sub(/^([^ ]+ +){7}/, "", name); printf "  %-10s %s %s  %s\n", size, date, time, name }'
printf '%s\n' "$LISTING" | awk 'END { print NR " file(s)" }'
