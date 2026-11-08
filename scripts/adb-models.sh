#!/bin/zsh

set -euo pipefail

SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB_BIN="$SDK_DIR/platform-tools/adb"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/adb_models.sh            Show model info for every connected device
  ./scripts/adb_models.sh --serials  Print only the serial of each connected device

Lists all devices currently visible to adb together with their product model,
manufacturer, product name and Android version. Devices that are not in the
"device" state (unauthorized, offline, recovery) are reported as such.
USAGE
}

SERIALS_ONLY=0

while (( $# > 0 )); do
  case "$1" in
    --serials)
      SERIALS_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "$ADB_BIN" ]]; then
  if command -v adb >/dev/null 2>&1; then
    ADB_BIN="$(command -v adb)"
  else
    echo "adb was not found at $ADB_BIN or in PATH." >&2
    exit 1
  fi
fi

"$ADB_BIN" start-server >/dev/null 2>&1 || true

lines=("${(@f)$("$ADB_BIN" devices | sed '1d' | sed '/^[[:space:]]*$/d')}")

if (( ${#lines[@]} == 0 )); then
  echo "No connected Android devices found." >&2
  exit 1
fi

getprop() {
  local serial="$1" prop="$2" value
  value="$("$ADB_BIN" -s "$serial" shell getprop "$prop" 2>/dev/null | tr -d '\r' | head -1)"
  [[ -z "$value" ]] && value="-"
  print -r -- "$value"
}

if (( SERIALS_ONLY )); then
  for line in "${lines[@]}"; do
    [[ -z "$line" ]] && continue
    serial="${line%%[[:space:]]*}"
    state="${line##*[[:space:]]}"
    [[ "$state" == "device" ]] && print -r -- "$serial"
  done
  exit 0
fi

printf '%-20s %-10s %-22s %-16s %-22s %-8s\n' \
  "SERIAL" "STATE" "MODEL" "MANUFACTURER" "PRODUCT" "ANDROID"

for line in "${lines[@]}"; do
  [[ -z "$line" ]] && continue
  serial="${line%%[[:space:]]*}"
  state="${line##*[[:space:]]}"

  if [[ "$state" != "device" ]]; then
    printf '%-20s %-10s %-22s %-16s %-22s %-8s\n' \
      "$serial" "$state" "-" "-" "-" "-"
    continue
  fi

  model="$(getprop "$serial" ro.product.model)"
  manufacturer="$(getprop "$serial" ro.product.manufacturer)"
  product="$(getprop "$serial" ro.product.name)"
  release="$(getprop "$serial" ro.build.version.release)"

  printf '%-20s %-10s %-22s %-16s %-22s %-8s\n' \
    "$serial" "$state" "$model" "$manufacturer" "$product" "$release"
done
