#!/usr/bin/env python3
"""Rebuild web/i18n/en.json from every t("...") key in the Web, Android and iOS code.

Usage: scripts/i18n-keys.py [--check] [extra keys file]
Keys reached through variables (status labels, play labels) cannot be found by scanning, so they live in
web/i18n/dynamic-keys.txt, one per line, and are merged in. --check exits 1 when en.json is out of date.
"""
import json, re, sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ROOT = REPO / "web"
SOURCES = [
    (ROOT / "app", "*.tsx"), (ROOT / "components", "*.tsx"), (ROOT / "lib", "*.ts"),
    (REPO / "android/HoopReplay/src/main", "*.kt"), (REPO / "ios/HoopReplay", "*.swift"),
]
KEY_RE = re.compile(r'''\bt\(\s*(?:"((?:[^"\\]|\\.)+)"|'((?:[^'\\]|\\.)+)')''')

def keys():
    found = set()
    for path in (p for folder, pattern in SOURCES for p in folder.rglob(pattern)):
        for match in KEY_RE.finditer(path.read_text()):
            raw = match.group(1) or match.group(2)
            if "$" in raw or "\\(" in raw:  # Kotlin/Swift template, not a static key
                continue
            found.add(re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), raw))
    extra = ROOT / "i18n" / "dynamic-keys.txt"
    if extra.exists():
        found.update(line.strip() for line in extra.read_text().splitlines() if line.strip() and not line.startswith("#"))
    return {k: k for k in sorted(found)}

if __name__ == "__main__":
    current = keys()
    target = ROOT / "i18n" / "en.json"
    text = json.dumps(current, ensure_ascii=False, indent=2) + "\n"
    if "--check" in sys.argv:
        sys.exit(0 if target.exists() and target.read_text() == text else 1)
    target.write_text(text)
    print(f"{len(current)} keys -> {target}")
