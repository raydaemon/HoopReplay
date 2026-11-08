#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/version-update.sh"
"$SCRIPT_DIR/build-android.sh"
"$SCRIPT_DIR/build-ios.sh"
