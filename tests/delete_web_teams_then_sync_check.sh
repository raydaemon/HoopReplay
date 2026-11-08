#!/usr/bin/env bash
# Deletes teams on Web, pulls on Android with the "Download" button, and checks
# that both platforms end up with the same team count.
#
# Usage: tests/delete_web_teams_then_sync_check.sh [options]
#   --device SERIAL    Android device to drive (default: the usual selection rules)
#   --base-url URL     HoopReplay Web URL (default: http://127.0.0.1:3000)
#   --email EMAIL      Account from data/users.csv (default: the first usable row)
#   --count N          Teams to delete on Web (default: 2)
#
# Requires: adb, python3 with Playwright (tests/requirements.txt), sqlite3, and a
# debuggable HoopReplay build on the device (the team count is read from its
# database with `run-as`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_FILE="$ROOT_DIR/data/devices.txt"
USERS_FILE="$ROOT_DIR/data/users.csv"
PACKAGE="com.connectedai.hoopreplay"
DEVICE_SERIAL=""
BASE_URL="http://127.0.0.1:3000"
EMAIL=""
DELETE_COUNT=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_SERIAL="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --count) DELETE_COUNT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; exit 2 ;;
  esac
done

for TOOL in adb python3 sqlite3; do
  command -v "$TOOL" >/dev/null 2>&1 || { echo "Error: $TOOL is not available." >&2; exit 1; }
done
[[ -f "$USERS_FILE" ]] || { echo "Error: $USERS_FILE not found." >&2; exit 1; }

# Device selection: an explicit serial wins, then a single connected device, then
# the first entry of data/devices.txt that is currently connected.
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
      echo "Pass a serial explicitly: $0 --device <device-serial>" >&2
      exit 1
    fi
  fi
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hoopreplay-sync-check.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

adb_sh() { adb -s "$DEVICE_SERIAL" "$@"; }

# uiautomator dumps on this Compose app are flaky: dump to a file, read it back,
# and retry until the XML actually contains nodes.
dump_ui() {
  local xml attempt
  for attempt in 1 2 3; do
    adb_sh shell uiautomator dump /sdcard/hoopreplay-ui.xml >/dev/null 2>&1 || true
    xml="$(adb_sh exec-out cat /sdcard/hoopreplay-ui.xml 2>/dev/null | awk '{ gsub(/></, ">\n<"); print }')"
    if printf '%s' "$xml" | grep -q '<node'; then
      printf '%s\n' "$xml"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Capture first, then match: `dump_ui | grep -q` exits early and pipefail turns the
# resulting SIGPIPE into a false negative.
has_text() {
  local xml
  xml="$(dump_ui)" || return 1
  printf '%s' "$xml" | grep -qF "\"$1\""
}

node_center() {
  dump_ui | grep -F "\"$1\"" | head -n 1 |
    sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\].*/\1 \2 \3 \4/p' |
    awk 'NF == 4 { print int(($1 + $3) / 2), int(($2 + $4) / 2) }'
}

tap_text() {
  local coords
  coords="$(node_center "$1")"
  [[ -n "$coords" ]] || return 1
  adb_sh shell input tap $coords
}

# Counts rows in the app's own database. WAL means the newest writes may live in
# the -wal file, so pull all three parts before querying.
android_team_count() {
  local part
  for part in "" "-wal" "-shm"; do
    adb_sh exec-out run-as "$PACKAGE" cat "databases/hoopreplay.db${part}" \
      > "$WORK_DIR/hoopreplay.db${part}" 2>/dev/null || true
  done
  [[ -s "$WORK_DIR/hoopreplay.db" ]] || {
    echo "Error: could not read databases/hoopreplay.db from $PACKAGE." >&2
    echo "Install a debuggable build (scripts/android-run.sh) so run-as works." >&2
    return 1
  }
  sqlite3 "$WORK_DIR/hoopreplay.db" "SELECT COUNT(*) FROM team;"
}

echo "Device:   $DEVICE_SERIAL"
echo "Web:      $BASE_URL"

echo
echo "1/4 Making sure Android is signed in…"
launch_app() {
  adb_sh shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 4
}

# Gets back to the game list by restarting the app rather than tapping "Back":
# blind taps land on game rows and can open the "Delete game?" dialog.
ensure_game_list() {
  has_text "Download" && return 0
  echo "Not on the game list; restarting the app…"
  adb_sh shell am force-stop "$PACKAGE"
  sleep 1
  launch_app
  has_text "Download"
}

adb_sh shell pidof "$PACKAGE" >/dev/null || launch_app
ensure_game_list || { echo "Error: could not reach the HoopReplay game list." >&2; exit 1; }

# The Cloud sync card reads "Signed in" once the account is connected.
if has_text "Signed in"; then
  echo "Already signed in."
else
  "$ROOT_DIR/.claude/skills/android-login/scripts/android-login.sh" "$DEVICE_SERIAL" ${EMAIL:+"$EMAIL"}
  ensure_game_list || { echo "Error: could not reach the HoopReplay game list." >&2; exit 1; }
  has_text "Signed in" || { echo "Error: the Android app is still signed out." >&2; exit 1; }
fi

echo
echo "2/4 Deleting $DELETE_COUNT team(s) on Web…"
cat > "$WORK_DIR/delete_teams.py" <<'PYTHON'
"""Signs in to HoopReplay Web, deletes N teams, and reports the resulting count."""

from __future__ import annotations

import csv
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError, sync_playwright

ROOT = Path(sys.argv[1])
BASE_URL = sys.argv[2]
WANTED_EMAIL = sys.argv[3]
DELETE_COUNT = int(sys.argv[4])
LOG_PATH = Path(sys.argv[5])
TIMEOUT_MS = 15_000


class Failure(RuntimeError):
    pass


def read_user() -> tuple[str, str]:
    with (ROOT / "data" / "users.csv").open(newline="", encoding="utf-8-sig") as handle:
        for row in csv.DictReader(handle):
            email = (row.get("email") or "").strip()
            password = row.get("password") or ""
            if not email or not password:
                continue
            if WANTED_EMAIL and email != WANTED_EMAIL:
                continue
            return email, password
    raise Failure("no usable credentials in data/users.csv" + (f" for {WANTED_EMAIL}" if WANTED_EMAIL else ""))


def wait_for_server(url: str, timeout_seconds: float) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status < 500:
                    return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.5)
    raise Failure(f"Web server did not become ready: {url}")


def start_server():
    if not BASE_URL.startswith(("http://127.0.0.1:", "http://localhost:")):
        return None
    try:
        wait_for_server(BASE_URL, 1)
        return None
    except Failure:
        pass
    port = BASE_URL.rsplit(":", 1)[-1].rstrip("/")
    log = LOG_PATH.open("w", encoding="utf-8")
    process = subprocess.Popen(
        ["npm", "run", "dev", "--", "--hostname", "127.0.0.1", "--port", port],
        cwd=ROOT / "web", text=True, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
    )
    try:
        wait_for_server(BASE_URL, 90)
    except Exception:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
        raise
    return process


def login(page, email: str, password: str) -> None:
    """Signs in unless the session is already authenticated (the account avatar is showing)."""
    page.goto(BASE_URL, wait_until="networkidle")
    page.wait_for_selector(".account, .authActions", timeout=30_000)
    if not page.locator(".avatarButton").count():
        page.locator(".authActions").get_by_role("button", name="Sign in", exact=True).click()
        modal = page.locator(".authModal")
        modal.locator('input[type="email"]').fill(email)
        modal.locator('input[type="password"]').fill(password)
        modal.get_by_role("button", name="Continue").click()
        try:
            page.locator(".avatarButton").wait_for(timeout=20_000)
        except PlaywrightTimeoutError:
            error = modal.locator(".authError")
            raise Failure(f"sign-in failed: {error.inner_text() if error.count() else 'unknown error'}")
    expect_synced(page)


def expect_synced(page) -> None:
    """Surfaces a failed cloud write here instead of as a missing deletion on Android."""
    # The sync status lives on the Games tab, so leave whichever tab we were on.
    page.locator(".tabNav button", has_text="Games").click()
    status = page.locator(".syncStatus").first
    status.wait_for(state="visible")
    deadline = time.monotonic() + TIMEOUT_MS / 1000
    while time.monotonic() < deadline:
        text = status.inner_text().strip()
        if "failed" in text.casefold():
            raise Failure(f"cloud sync failed: {text!r}")
        if "Synced" in text:
            return
        page.wait_for_timeout(100)
    raise Failure(f"cloud sync never completed: {status.inner_text().strip()!r}")


def open_teams(page) -> None:
    page.locator(".tabNav button", has_text="Teams").click()
    page.locator(".manager").wait_for(state="visible")


def team_names(page) -> list[str]:
    """Names come from the per-team delete button, whose aria-label is exactly the name."""
    open_teams(page)
    labels = page.locator('.roster h3 button[aria-label^="Delete "]').evaluate_all(
        "nodes => nodes.map(node => node.getAttribute('aria-label').slice('Delete '.length))"
    )
    return [label for label in labels]


def team_count(page) -> int:
    return len(team_names(page))


def delete_team(page, name: str) -> bool:
    """Deletes one team. Returns False when the app refuses (team used by a game)."""
    open_teams(page)
    page.get_by_role("button", name=f"Delete {name}", exact=True).click()
    dialog = page.get_by_role("alertdialog")
    dialog.wait_for(state="visible")
    title = dialog.locator("#confirm-title").inner_text().strip()
    if title.casefold() != "delete team?":
        # "Unable to Delete Team" — acknowledge and leave the team in place.
        dialog.get_by_role("button", name="OK", exact=True).click()
        dialog.wait_for(state="hidden")
        return False
    dialog.get_by_role("button", name="Delete", exact=True).click()
    dialog.wait_for(state="hidden")
    return True


def main() -> int:
    email, password = read_user()
    server = start_server()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                context = browser.new_context(viewport={"width": 1440, "height": 900})
                page = context.new_page()
                page.set_default_timeout(TIMEOUT_MS)
                login(page, email, password)

                before = team_names(page)
                if len(before) < DELETE_COUNT:
                    raise Failure(
                        f"only {len(before)} team(s) on Web; need at least {DELETE_COUNT} to delete"
                    )
                deleted: list[str] = []
                for name in list(before):
                    if len(deleted) == DELETE_COUNT:
                        break
                    # A team's own line renders once per roster card; skip duplicates.
                    if name in deleted:
                        continue
                    if delete_team(page, name):
                        deleted.append(name)
                        expect_synced(page)
                if len(deleted) < DELETE_COUNT:
                    raise Failure(
                        f"deleted only {len(deleted)} of {DELETE_COUNT} team(s); the rest are used by games"
                    )
                after = team_count(page)
                print(json.dumps({"email": email, "before": len(before), "deleted": deleted, "after": after}))
                return 0
            finally:
                browser.close()
    finally:
        if server and server.poll() is None:
            os.killpg(server.pid, signal.SIGTERM)
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Failure, PlaywrightTimeoutError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
PYTHON

python3 "$WORK_DIR/delete_teams.py" "$ROOT_DIR" "$BASE_URL" "$EMAIL" "$DELETE_COUNT" \
  "$WORK_DIR/next-dev.log" | tee "$WORK_DIR/web-result.json"
WEB_JSON="$(tail -n 1 "$WORK_DIR/web-result.json")"
WEB_AFTER="$(printf '%s' "$WEB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["after"])')"

echo
echo "3/4 Tapping Download on Android…"
ANDROID_BEFORE="$(android_team_count)"
echo "Android teams before Download: $ANDROID_BEFORE"

ensure_game_list || { echo "Error: the Download button is not visible on the game list." >&2; exit 1; }

tap_text "Download" || { echo "Error: could not tap Download." >&2; exit 1; }

# The button reads "…" while syncing; wait for it to settle back to "Download".
SYNC_DONE=0
for _ in $(seq 1 30); do
  sleep 2
  if has_text "Download"; then
    SYNC_DONE=1
    break
  fi
done
[[ "$SYNC_DONE" -eq 1 ]] || { echo "Error: the Download sync did not finish in time." >&2; exit 1; }
sleep 2

echo
echo "4/4 Comparing team counts…"
ANDROID_AFTER="$(android_team_count)"

echo "Web teams:     $WEB_AFTER"
echo "Android teams: $ANDROID_AFTER"

if [[ "$WEB_AFTER" == "$ANDROID_AFTER" ]]; then
  echo "PASS: both platforms show $WEB_AFTER team(s) after deleting $DELETE_COUNT on Web."
  exit 0
fi

echo "FAIL: Web has $WEB_AFTER team(s) but Android has $ANDROID_AFTER after Download." >&2
echo "Deleted on Web: $WEB_JSON" >&2
exit 1
