#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_FILE="${2:-${PROJECT_ROOT}/artifacts/ios-screenshot.png}"
DEVICE_ID="${1:-}"

if [[ -z "${DEVICE_ID}" ]]; then
  if command -v idevice_id >/dev/null 2>&1; then
    DEVICE_ID="$(idevice_id -l | head -n 1)"
  fi
  if [[ -z "${DEVICE_ID}" ]]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null | awk '$0 ~ /connected|available \(paired\)/ { print $3 }' | head -n 1)"
  fi
fi

if [[ -z "${DEVICE_ID}" ]]; then
  echo "错误：没有找到可用的已配对 iOS 设备。" >&2
  echo "用法：$0 <设备标识> [输出文件]" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")"

# Xcode 15+ / iOS 17+ uses the Cryptex Developer Disk Image.  The legacy
# libimobiledevice screenshotr service is not available with that image, so
# prefer Apple's CoreDevice command and only fall back for older toolchains.
if xcrun devicectl device capture screenshot \
  --device "${DEVICE_ID}" \
  --destination "${OUTPUT_FILE}"; then
  :
elif command -v idevicescreenshot >/dev/null 2>&1; then
  echo "警告：devicectl 截图失败，尝试旧版 idevicescreenshot。" >&2
  idevicescreenshot -u "${DEVICE_ID}" "${OUTPUT_FILE}"
else
  echo "错误：devicectl 截图失败，且未找到 idevicescreenshot。" >&2
  echo "请确认设备已连接、已信任本机并开启 Developer Mode。" >&2
  exit 1
fi

if [[ ! -s "${OUTPUT_FILE}" ]]; then
  echo "错误：截图未生成：${OUTPUT_FILE}" >&2
  exit 1
fi

echo "截图已保存：${OUTPUT_FILE}"
open -R "${OUTPUT_FILE}"
