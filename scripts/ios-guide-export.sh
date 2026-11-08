#!/usr/bin/env bash
# Exports the GuideTourUITests screenshot attachments from an .xcresult bundle into
# docs/user_guide_ios/, rotating landscape captures (@LR / @LL suffix) upright.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT="${1:?usage: $0 <path.xcresult> [output dir]}"
OUT="${2:-$ROOT_DIR/docs/user_guide_ios}"
TMP="$(mktemp -d)"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$TMP" >/dev/null
mkdir -p "$OUT"
python3 - "$TMP" "$OUT" <<'PY'
import json, os, re, shutil, subprocess, sys
tmp, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(tmp, "manifest.json")))
count = 0
for test in manifest:
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName") or att.get("exportedFileName", "")
        base = os.path.splitext(name)[0]
        base = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", base)
        base = re.sub(r"_\d+$", "", base)
        if not base[:2].isdigit(): continue
        rotate = None
        if base.endswith("@LR"): base, rotate = base[:-3], "90"
        elif base.endswith("@LL"): base, rotate = base[:-3], "270"
        elif base.endswith("@PU"): base, rotate = base[:-3], "180"
        src = os.path.join(tmp, att["exportedFileName"])
        dst = os.path.join(out, base + ".png")
        shutil.copy(src, dst)
        # XCUIScreen sometimes hands back landscape captures already upright and sometimes as
        # portrait pixels; only the latter need turning.
        info = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", dst], check=True, capture_output=True, text=True).stdout
        dims = dict((k.strip(), v.strip()) for k, v in (line.split(": ", 1) for line in info.strip().splitlines() if ": " in line))
        portrait = int(dims.get("pixelHeight", 0)) > int(dims.get("pixelWidth", 0))
        if rotate and portrait: subprocess.run(["sips", "-r", "270", dst], check=True, capture_output=True)
        subprocess.run(["sips", "-Z", "1600", dst], check=True, capture_output=True)
        count += 1
print(f"exported {count} screenshots to {out}")
PY
rm -rf "$TMP"
