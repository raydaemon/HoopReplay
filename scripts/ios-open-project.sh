#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${PROJECT_ROOT}/ios/HoopReplay.xcodeproj"

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "错误：找不到 Xcode 工程：${PROJECT_PATH}" >&2
  exit 1
fi

open "${PROJECT_PATH}"
