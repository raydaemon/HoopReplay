#!/usr/bin/env bash
set -euo pipefail

# Downloads everything the app exported to Downloads/HoopReplay on the device
# (JSON game exports, statistics PDFs) into the repository's data/reports folder.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_FILE="$PROJECT_DIR/data/devices.txt"
DEVICE_SERIAL="${1:-}"
OUTPUT_DIR="${2:-$PROJECT_DIR/data/reports}"
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
      echo "Add a preferred device serial to $DEVICE_FILE or use: $0 <device-serial> [output-dir]" >&2
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
  echo "Error: $REMOTE_DIR is empty or missing on $DEVICE_SERIAL." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
PULLED=0
while IFS= read -r REMOTE_FILE; do
  [[ -z "$REMOTE_FILE" ]] && continue
  adb -s "$DEVICE_SERIAL" pull "$REMOTE_DIR/$REMOTE_FILE" "$OUTPUT_DIR/$REMOTE_FILE" >/dev/null
  echo "Pulled $REMOTE_FILE"
  PULLED=$((PULLED + 1))
done <<< "$REMOTE_FILES"

echo "$PULLED file(s) saved to $OUTPUT_DIR"
