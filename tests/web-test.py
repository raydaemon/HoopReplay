#!/usr/bin/env python3
"""Playwright end-to-end test for every HoopReplay Web workflow.

Credentials come from data/users.csv (email,password). The test creates
uniquely named temporary data, exercises the UI and Supabase sync, then cleans
up. Passwords are never logged, screenshotted, or written to browser state.

Install once:
    python3 -m pip install -r tests/requirements.txt
    python3 -m playwright install chromium

Run:
    ./tests/web-test.py
    ./tests/web-test.py --base-url https://hoopreplay-tawny.vercel.app
"""

from __future__ import annotations

import argparse
import csv
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

try:
    from playwright.sync_api import (
        Browser,
        BrowserContext,
        Dialog,
        Error as PlaywrightError,
        Locator,
        Page,
        Playwright,
        TimeoutError as PlaywrightTimeoutError,
        sync_playwright,
    )
except ImportError:
    print(
        "Playwright is required. Run: python3 -m pip install -r tests/requirements.txt",
        file=sys.stderr,
    )
    raise SystemExit(2)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_USERS = ROOT / "data" / "users.csv"
DEFAULT_URL = "http://127.0.0.1:3000"
TIMEOUT_MS = 15_000


class TestFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class UserCredential:
    email: str
    password: str


def read_users(path: Path) -> list[UserCredential]:
    if not path.is_file():
        raise TestFailure(f"Credential CSV not found: {path}")
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    users = [
        UserCredential((row.get("email") or "").strip(), row.get("password") or "")
        for row in rows
    ]
    users = [user for user in users if user.email and user.password]
    if not users:
        raise TestFailure(f"{path} must contain non-empty email,password columns")
    return users


def wait_for_server(url: str, timeout_seconds: float = 45) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status < 500:
                    return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.5)
    raise TestFailure(f"Web server did not become ready: {url}")


def start_server(base_url: str, log_path: Path) -> subprocess.Popen[str] | None:
    if not base_url.startswith(("http://127.0.0.1:", "http://localhost:")):
        return None
    try:
        wait_for_server(base_url, timeout_seconds=1)
        return None
    except TestFailure:
        pass
    port = base_url.rsplit(":", 1)[-1].rstrip("/")
    log = log_path.open("w", encoding="utf-8")
    process = subprocess.Popen(
        ["npm", "run", "dev", "--", "--hostname", "127.0.0.1", "--port", port],
        cwd=ROOT / "web",
        text=True,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        wait_for_server(base_url)
    except Exception:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
        raise
    return process


def expect_body(page: Page, text: str, timeout: int = TIMEOUT_MS) -> None:
    page.locator("body").filter(has_text=text).wait_for(state="visible", timeout=timeout)


def body_text(page: Page) -> str:
    return page.locator("body").inner_text()


def wait_for_event_count(page: Page, expected: int, timeout: int = TIMEOUT_MS) -> None:
    counter = page.locator(".viewTabs button").nth(1)
    deadline = time.monotonic() + timeout / 1000
    while time.monotonic() < deadline:
        text = counter.inner_text()
        if text.rstrip().endswith(str(expected)):
            return
        page.wait_for_timeout(50)
    raise TestFailure(f"Expected Play-by-Play {expected}, got {counter.inner_text()!r}")


def confirm_delete(page: Page, trigger: Locator, title: str) -> None:
    trigger.click()
    dialog = page.get_by_role("alertdialog")
    dialog.wait_for(state="visible")
    if dialog.get_by_role("heading").inner_text().casefold() != title.casefold():
        raise TestFailure(f"Unexpected delete dialog: {dialog.get_by_role('heading').inner_text()!r}")
    dialog.get_by_role("button", name="Delete", exact=True).click()
    dialog.wait_for(state="hidden")


def picker_select(page: Page, title: str, choices: Sequence[str]) -> None:
    picker = page.get_by_role("dialog", name=title, exact=True)
    picker.wait_for(state="visible")
    for choice in choices:
        matches = picker.locator(".playerTags button", has_text=choice)
        selected = matches.last
        selected.click()
        if selected.get_attribute("aria-pressed") != "true" or "selected" not in (selected.get_attribute("class") or ""):
            raise TestFailure(f"Player tag did not enter its selected style: {choice}")
    picker.get_by_role("button", name="Confirm").click()
    picker.wait_for(state="hidden")


def picker_cancel(page: Page, title: str) -> None:
    picker = page.get_by_role("dialog", name=title, exact=True)
    picker.wait_for(state="visible")
    picker.get_by_role("button", name="Cancel", exact=True).click()
    picker.wait_for(state="hidden")


def assert_home_away_groups(page: Page, title: str, expected_players: int) -> None:
    picker = page.get_by_role("dialog", name=title, exact=True)
    picker.locator(".playerGroup").first.wait_for(state="visible")
    headings = picker.locator(".playerGroup h3").all_inner_texts()
    if len(headings) != 2 or not headings[0].startswith("HOME ·") or not headings[1].startswith("AWAY ·"):
        raise TestFailure(f"Expected separate HOME/AWAY player groups, got {headings!r}")
    if picker.locator(".playerTags button").count() != expected_players:
        raise TestFailure("Player picker included players outside the two teams in this game")
    labels = picker.locator(".playerTags button").all_inner_texts()
    numbers = [label.split(" ", 1)[0] for label in labels]
    if numbers != ["#11", "#12", "#—", "#—", "#21", "#22"] or "Alpha Reserve" not in labels[2] or "Zebra Reserve" not in labels[3]:
        raise TestFailure(f"Players were not sorted by jersey number: {labels!r}")


def login(page: Page, base_url: str, user: UserCredential) -> None:
    page.goto(base_url, wait_until="networkidle")
    if page.get_by_role("button", name="Account menu").count():
        page.get_by_role("button", name="Account menu").click()
        page.get_by_role("menuitem", name="Sign out").click()
    page.get_by_role("button", name="Sign in", exact=True).click()
    modal = page.locator(".authModal")
    modal.locator('input[type="email"]').fill(user.email)
    modal.locator('input[type="password"]').fill(user.password)
    modal.get_by_role("button", name="Continue").click()

    try:
        page.get_by_role("button", name="Account menu").wait_for(timeout=5_000)
    except PlaywrightTimeoutError:
        message = modal.locator(".authError").inner_text() if modal.locator(".authError").count() else ""
        if "Email not confirmed" in message:
            raise TestFailure("The test account email is not confirmed. Confirm it, then rerun.")
        if "Invalid login credentials" not in message:
            raise TestFailure(f"Login failed: {message or 'unknown authentication error'}")
        modal.locator(".authTabs button").nth(1).click()
        modal.get_by_role("button", name="Continue").click()
        try:
            page.get_by_role("button", name="Account menu").wait_for(timeout=5_000)
        except PlaywrightTimeoutError:
            message = modal.locator(".authError").inner_text() if modal.locator(".authError").count() else ""
            raise TestFailure(
                f"Registration did not create a session: {message or 'confirm the test email, then rerun'}"
            )
    expect_body(page, "Synced")


def open_roster(page: Page) -> None:
    manager = page.locator(".manager")
    if not manager.count() or not manager.is_visible():
        page.locator(".tabNav").get_by_role("button", name="Teams").click()
    manager.wait_for(state="visible")


def open_games(page: Page) -> None:
    if page.locator(".manager").count() and page.locator(".manager").is_visible():
        page.locator(".tabNav").get_by_role("button", name="Games").click()
        page.locator(".manager").wait_for(state="hidden")


def add_team(page: Page, name: str) -> None:
    open_roster(page)
    form = page.locator(".manager form").nth(0)
    form.locator("input").fill(name)
    form.locator("button").click()
    expect_body(page, name)


def add_player(page: Page, team: str, number: str, name: str) -> None:
    form = page.locator(".manager form").nth(1)
    form.locator("select").select_option(label=team)
    form.locator("input.number").fill(number)
    form.locator("input:not(.number)").fill(name)
    form.get_by_role("button", name="Add player").click()
    expect_body(page, name)


def create_game(page: Page, title: str, home: str, away: str) -> None:
    open_games(page)
    page.locator("button.createGame").click()
    modal = page.locator(".formModal")
    modal.get_by_label("Game name", exact=True).fill(title)
    modal.locator(".formGrid label").nth(0).locator("select").select_option(label=home)
    modal.locator(".formGrid label").nth(1).locator("select").select_option(label=away)
    modal.locator(".formGrid label").nth(4).locator("input").fill("2")
    modal.locator(".formGrid label").nth(5).locator("input").fill("1")
    modal.locator(".formGrid label").nth(3).locator("select").select_option("FHD")
    modal.get_by_role("button", name="Create game").click()
    expect_body(page, home)
    expect_body(page, away)
    expect_body(page, "01:00")


def exercise_live_game(page: Page, artifacts: Path) -> None:
    page.get_by_role("button", name="Start game").click()
    expect_body(page, "Start clock")
    page.get_by_role("button", name="Stat Mode", exact=True).click()
    home = page.locator(".liveTeams section").nth(0)
    away = page.locator(".liveTeams section").nth(1)

    recording_errors: list[str] = []

    def handle_recording_dialog(dialog: Dialog) -> None:
        recording_errors.append(dialog.message)
        dialog.accept()

    page.on("dialog", handle_recording_dialog)
    try:
        page.get_by_role("button", name="Record video").click()
        page.get_by_role("button", name="Stop & download video").wait_for(timeout=5_000)
    except PlaywrightTimeoutError as error:
        if any("permission was not granted" in message.lower() for message in recording_errors):
            raise TestFailure("A media stream is required so every test event has a segment") from error
        raise TestFailure("Video recording did not start") from error
    finally:
        page.remove_listener("dialog", handle_recording_dialog)

    home.get_by_role("button", name="Set Lineup").click()
    picker_select(page, "Select Starting Players", ["#11", "#12"])
    away.get_by_role("button", name="Set Lineup").click()
    picker_select(page, "Select Starting Players", ["#21", "#22"])

    home.get_by_role("button", name="Substitute").click()
    substitution = page.get_by_role("dialog", name="Record substitution")
    substitution.wait_for(state="visible")
    lineup = substitution.locator('[aria-label="Team lineup"]')
    outgoing = lineup.locator("button", has_text="#11")
    incoming = lineup.locator("button", has_text="Alpha Reserve")
    if outgoing.get_attribute("aria-pressed") != "true" or incoming.get_attribute("aria-pressed") != "false":
        raise TestFailure("Substitution did not initialize tags from the current lineup")
    outgoing.click()
    incoming.click()
    if outgoing.get_attribute("aria-pressed") != "false" or incoming.get_attribute("aria-pressed") != "true":
        raise TestFailure("Substitution did not toggle check-out and check-in players in one list")
    substitution.get_by_role("button", name="Record Substitution").click()
    substitution.wait_for(state="hidden")

    home.get_by_role("button", name="+2", exact=True).click()
    picker_select(page, "Who made this 2-point shot?", ["#11"])
    picker_select(page, "Who made the assist? (Optional)", ["#12"])
    page.wait_for_timeout(150)
    away.get_by_role("button", name="+3", exact=True).click()
    picker_select(page, "Who made this 3-point shot?", ["#21"])
    picker_select(page, "Who made the assist? (Optional)", ["#22"])
    page.wait_for_timeout(150)
    home.get_by_role("button", name="Miss 2").click()
    picker_select(page, "Who took this shot?", ["#12"])
    assert_home_away_groups(page, "Who got the rebound? (Optional)", 6)
    picker_select(page, "Who got the rebound? (Optional)", ["#21"])
    page.wait_for_timeout(150)
    away.get_by_role("button", name="Miss 3").click()
    picker_select(page, "Who took this shot?", ["#22"])
    picker_cancel(page, "Who got the rebound? (Optional)")
    page.wait_for_timeout(150)

    home.get_by_role("button", name="Free Throw").click()
    picker_select(page, "Who is shooting the free throw?", ["#11"])
    free_throws = page.get_by_role("dialog", name="Record free throws")
    free_throws.get_by_role("button", name="1+1", exact=True).click()
    free_throws.get_by_label("Free throw 1").get_by_role("button", name="✓ +1 Point").click()
    free_throws.get_by_label("Free throw 2").get_by_role("button", name="× Missed").click()
    free_throws.get_by_role("button", name="Record free throws").click()
    assert_home_away_groups(page, "Who got the rebound?", 6)
    picker_select(page, "Who got the rebound?", ["#21"])
    page.wait_for_timeout(150)

    for stat in ("Rebound", "Assist", "Steal", "Block", "Turnover", "Foul"):
        home.get_by_role("button", name=stat, exact=True).click()
        picker_select(page, f"Who recorded this {stat.lower()}?", ["#11"])
    page.wait_for_timeout(150)

    if page.get_by_label("Home score").inner_text() != "3" or page.get_by_label("Away score").inner_text() != "3":
        raise TestFailure("Live scoreboard did not display the current score")
    page.get_by_role("button", name="Live stats", exact=True).click()
    live_stats = page.get_by_role("dialog", name="Live statistics")
    live_stats.wait_for(state="visible")
    expect_body(page, "3 – 3")
    if live_stats.get_by_text("TEAM TOTAL", exact=True).count() != 2:
        raise TestFailure("Live statistics did not show totals for both teams")
    live_stats.get_by_role("button", name="Close live statistics").click()
    live_stats.wait_for(state="hidden")

    page.get_by_role("button", name="Start clock").click()
    page.wait_for_timeout(1_200)
    page.get_by_role("button", name="Pause clock").click()
    page.get_by_role("button", name="Next period").click()
    expect_body(page, "Q2")
    expect_body(page, "01:00")

    video_path = artifacts / "recording.webm"
    with page.expect_download() as download_info:
        page.get_by_role("button", name="Stop & download video").click()
    download_info.value.save_as(video_path)
    if not video_path.is_file():
        raise TestFailure("Browser video recording did not download")

    page.get_by_role("button", name="Record video").wait_for(state="visible")
    page.get_by_role("button", name="Undo").click()
    page.get_by_role("button", name="Save & exit").click()
    page.locator(".liveOverlay").wait_for(state="hidden")
    expect_body(page, "Synced")
    events_after_save = page.locator(".viewTabs button").nth(1).inner_text()
    if not events_after_save.rstrip().split(" ")[-1].isdigit() or int(events_after_save.rsplit(" ", 1)[-1]) < 15:
        raise TestFailure(f"Expected saved live events, got {events_after_save!r}")


def verify_views_and_exports(page: Page, artifacts: Path) -> None:
    page.get_by_role("button", name="Play-by-Play", exact=False).click()
    expect_body(page, "2-point field goal made")
    expect_body(page, "Q1")
    page.get_by_role("button", name="Statistics", exact=True).click()
    expect_body(page, "TEAM TOTAL")

    csv_path = artifacts / "events.csv"
    with page.expect_download() as download_info:
        page.get_by_role("button", name="Export CSV").click()
    download_info.value.save_as(csv_path)
    if "game_clock_ms" not in csv_path.read_text(encoding="utf-8"):
        raise TestFailure("CSV export has the wrong header")

    page.evaluate("window.__printCalled = false; window.print = () => { window.__printCalled = true; }")
    page.get_by_role("button", name="Print / PDF").click()
    if not page.evaluate("window.__printCalled"):
        raise TestFailure("Print / PDF button did not invoke window.print")
    pdf_path = artifacts / "statistics.pdf"
    page.emulate_media(media="print")
    page.pdf(path=str(pdf_path), print_background=True)
    if pdf_path.stat().st_size < 500:
        raise TestFailure("Printable PDF artifact was not generated")
    page.emulate_media(media="screen")

    open_games(page)
    page.get_by_role("button", name="Download").first.click()
    expect_body(page, "Synced")


def cleanup(page: Page, teams: Sequence[str]) -> None:
    if page.locator(".substitutionDialog").is_visible():
        page.get_by_role("button", name="Cancel substitution").click()
    elif page.locator(".freeThrowDialog").is_visible():
        page.get_by_role("button", name="Cancel free throws").click()
    elif page.locator(".playerPicker").is_visible():
        page.get_by_role("button", name="Cancel selection").click()
    if page.locator(".liveOverlay").is_visible():
        page.get_by_role("button", name="End game").click()
        page.locator(".liveOverlay").wait_for(state="hidden")
    if page.locator(".formModal").count():
        page.locator(".formModal .authHeading > button").click()
    matching_games = page.locator(".gameCard", has_text=teams[0]).filter(has_text=teams[1])
    if matching_games.count():
        matching_games.first.click()
        confirm_delete(page, page.get_by_role("button", name="Delete game"), "Delete game?")
    open_roster(page)
    for team in teams:
        button = page.get_by_role("button", name=f"Delete {team}")
        if button.count():
            confirm_delete(page, button, "Delete team?")
    open_games(page)
    page.get_by_role("button", name="Download").first.click()
    expect_body(page, "Synced")


def expect_saved(page: Page) -> None:
    """Surface a failed cloud write here instead of as a timeout on the other device."""
    status = page.locator(".syncStatus").first
    deadline = time.monotonic() + TIMEOUT_MS / 1000
    while time.monotonic() < deadline:
        text = status.inner_text().strip()
        if "failed" in text.casefold():
            raise TestFailure(f"Cloud write failed: {text!r}")
        if "Synced" in text:
            return
        page.wait_for_timeout(100)
    raise TestFailure(f"Cloud write never completed: {status.inner_text().strip()!r}")


def pull_from_cloud(page: Page) -> None:
    open_games(page)
    page.get_by_role("button", name="Download").first.click()
    expect_body(page, "Synced")


def has_team(page: Page, name: str) -> bool:
    open_roster(page)
    return page.get_by_role("button", name=f"Delete {name}", exact=True).count() > 0


def wait_for_team(page: Page, name: str, present: bool, timeout: int = TIMEOUT_MS) -> None:
    deadline = time.monotonic() + timeout / 1000
    while True:
        pull_from_cloud(page)
        if has_team(page, name) == present:
            return
        if time.monotonic() >= deadline:
            state = "appear on" if present else "disappear from"
            raise TestFailure(f"{name!r} did not {state} this device after syncing")
        page.wait_for_timeout(500)


def run_sync_conflict(browser: Browser, base_url: str, user: UserCredential, artifacts: Path, keep_data: bool) -> None:
    """Two devices, one account.

    Regression for silent data loss: sync used to replace the whole account on every save, so a
    device saving a snapshot it had loaded before the other device's team existed deleted that
    team. Deletions are now recorded as tombstones, so absence never means "delete this".
    """
    stamp = f"{int(time.time())}-sync"
    first = f"E2E Device A {stamp}"
    second = f"E2E Device B {stamp}"
    contexts = [new_context(browser, base_url) for _ in range(2)]
    pages = [context.new_page() for context in contexts]
    try:
        for page in pages:
            page.set_default_timeout(TIMEOUT_MS)
            login(page, base_url, user)

        # Both devices now hold the same snapshot; each adds a team without seeing the other's.
        print("  sync: device A adds a team", flush=True)
        add_team(pages[0], first)
        expect_saved(pages[0])
        print("  sync: device B saves a snapshot that predates it", flush=True)
        add_team(pages[1], second)
        expect_saved(pages[1])

        print("  sync: neither team may be deleted by the other's save", flush=True)
        wait_for_team(pages[0], second, True)
        if not has_team(pages[0], first):
            raise TestFailure(f"A stale save from the second device deleted {first!r}")
        wait_for_team(pages[1], first, True)
        if not has_team(pages[1], second):
            raise TestFailure(f"A stale save from the first device deleted {second!r}")

        print("  sync: a recorded deletion reaches the other device", flush=True)
        open_roster(pages[1])
        confirm_delete(pages[1], pages[1].get_by_role("button", name=f"Delete {first}", exact=True), "Delete team?")
        expect_saved(pages[1])
        wait_for_team(pages[0], first, False)
        if not has_team(pages[0], second):
            raise TestFailure(f"Replaying the deletion of {first!r} also removed {second!r}")
        for index, page in enumerate(pages):
            page.screenshot(path=str(artifacts / f"passed-sync-{index}.png"), full_page=True)
    except Exception:
        for index, page in enumerate(pages):
            page.screenshot(path=str(artifacts / f"failed-sync-{index}.png"), full_page=True)
        raise
    finally:
        if not keep_data:
            try:
                cleanup(pages[0], [first, second])
                expect_saved(pages[0])
            except Exception as error:  # noqa: BLE001 - cleanup must never mask the real failure
                print(f"WARNING: sync cleanup failed: {error}", file=sys.stderr)
        for context in contexts:
            context.close()


def run_user(page: Page, base_url: str, user: UserCredential, index: int, artifacts: Path, keep_data: bool) -> None:
    stamp = f"{int(time.time())}-{index}"
    home = f"E2E Home {stamp}"
    away = f"E2E Away {stamp}"
    title = f"E2E Web Game {stamp}"
    authenticated = False
    try:
        print(f"  user {index}: authenticate", flush=True)
        login(page, base_url, user)
        authenticated = True
        print(f"  user {index}: roster", flush=True)
        add_team(page, home)
        add_team(page, away)
        add_player(page, home, "12", f"Home Forward {stamp}")
        add_player(page, home, "11", f"Home Guard {stamp}")
        add_player(page, home, "", f"Zebra Reserve {stamp}")
        add_player(page, home, "", f"Alpha Reserve {stamp}")
        add_player(page, away, "22", f"Away Forward {stamp}")
        add_player(page, away, "21", f"Away Guard {stamp}")
        print(f"  user {index}: create game", flush=True)
        create_game(page, title, home, away)
        print(f"  user {index}: live controls", flush=True)
        exercise_live_game(page, artifacts)
        print(f"  user {index}: views and exports", flush=True)
        verify_views_and_exports(page, artifacts)

        print(f"  user {index}: complete game", flush=True)
        page.get_by_role("button", name="Open live controls").click()
        page.get_by_role("button", name="End game").click()
        page.locator(".liveOverlay").wait_for(state="hidden")
        expect_body(page, "COMPLETED")

        print(f"  user {index}: sign-out persistence", flush=True)
        page.get_by_role("button", name="Sign out").click()
        page.get_by_role("button", name="Sign in", exact=True).wait_for()
        login(page, base_url, user)
        expect_body(page, home)
        expect_body(page, away)
        page.screenshot(path=str(artifacts / f"passed-user-{index}.png"), full_page=True)
    except Exception:
        page.screenshot(path=str(artifacts / f"failed-user-{index}.png"), full_page=True)
        raise
    finally:
        if authenticated and not keep_data:
            print(f"  user {index}: cleanup", flush=True)
            try:
                if not page.get_by_role("button", name="Sign out").count():
                    login(page, base_url, user)
                cleanup(page, [home, away])
            except Exception as error:
                print(f"WARNING: cleanup failed for user {index}: {error}", file=sys.stderr)


def launch_browser(playwright: Playwright, headed: bool) -> Browser:
    options = {
        "headless": not headed,
        "args": ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"],
    }
    try:
        return playwright.chromium.launch(**options)
    except PlaywrightError as error:
        if "Executable doesn't exist" not in str(error):
            raise
        return playwright.chromium.launch(channel="chrome", **options)


def new_context(browser: Browser, base_url: str) -> BrowserContext:
    context = browser.new_context(accept_downloads=True, viewport={"width": 1440, "height": 900})
    origin = base_url.rstrip("/")
    context.grant_permissions(["camera", "microphone"], origin=origin)
    # Chromium's fake capture device is not consistently available on every CI
    # host. Supply a deterministic canvas stream while still exercising the
    # application's real MediaRecorder, stop, and download code paths.
    context.add_init_script(
        """
        (() => {
          const original = navigator.mediaDevices?.getUserMedia?.bind(navigator.mediaDevices);
          if (!original) return;
          navigator.mediaDevices.getUserMedia = async () => {
            const canvas = document.createElement('canvas');
            canvas.width = 640;
            canvas.height = 360;
            const context = canvas.getContext('2d');
            let frame = 0;
            const draw = () => {
              context.fillStyle = frame++ % 2 ? '#ff6b00' : '#080b0f';
              context.fillRect(0, 0, canvas.width, canvas.height);
              requestAnimationFrame(draw);
            };
            draw();
            return canvas.captureStream(30);
          };
        })();
        """
    )
    return context


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--users", type=Path, default=DEFAULT_USERS, help="CSV containing email,password")
    parser.add_argument("--base-url", default=DEFAULT_URL, help="Local or deployed HoopReplay URL")
    parser.add_argument("--headed", action="store_true", help="Show Chromium")
    parser.add_argument("--keep-data", action="store_true", help="Keep generated cloud data for debugging")
    parser.add_argument("--artifacts", type=Path, help="Screenshots/downloads directory")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    users = read_users(args.users.resolve())
    artifacts = args.artifacts.resolve() if args.artifacts else Path(tempfile.mkdtemp(prefix="hoopreplay-web-test-"))
    artifacts.mkdir(parents=True, exist_ok=True)
    server = start_server(args.base_url, artifacts / "next-dev.log")
    print(f"Testing {args.base_url} with {len(users)} user(s); artifacts: {artifacts}")
    try:
        with sync_playwright() as playwright:
            browser = launch_browser(playwright, args.headed)
            try:
                for index, user in enumerate(users, start=1):
                    context = new_context(browser, args.base_url)
                    page = context.new_page()
                    page.set_default_timeout(TIMEOUT_MS)
                    try:
                        run_user(page, args.base_url, user, index, artifacts, args.keep_data)
                        print(f"PASS user {index}: {user.email}")
                    finally:
                        context.close()
                print("Two-device sync", flush=True)
                run_sync_conflict(browser, args.base_url, users[0], artifacts, args.keep_data)
                print("PASS two-device sync")
            finally:
                browser.close()
        return 0
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
    except (TestFailure, PlaywrightTimeoutError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
