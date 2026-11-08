#!/usr/bin/env python3
"""Run the NBA Finals Q1 Android instrumentation scenario and verify its PDF."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from typing import Sequence, Union


ROOT = Path(__file__).resolve().parents[1]
ANDROID_DIR = ROOT / "android"
TMP_DIR = ROOT / "tmp"
DEFAULT_DEVICE = "38261FDJG001D1"
DEFAULT_TEST_CLASS = "com.connectedai.hoopreplay.NbaFinalsFirstQuarterTest"
EXPECTED_STEPS = 75


class TestFailure(RuntimeError):
    pass


def command_path(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise TestFailure(f"Required command is not available: {name}")
    return path


def run(
    command: Sequence[Union[str, Path]],
    *,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    normalized = [str(value) for value in command]
    result = subprocess.run(
        normalized,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if check and result.returncode:
        detail = f"\n{result.stdout.strip()}" if capture and result.stdout else ""
        raise TestFailure(f"Command failed ({result.returncode}): {' '.join(normalized)}{detail}")
    return result


def find_gradle() -> Union[Path, str]:
    wrapper = ANDROID_DIR / "gradlew"
    if wrapper.exists() and os.access(wrapper, os.X_OK):
        return wrapper
    if installed := shutil.which("gradle"):
        return installed

    gradle_root = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle"))
    distributions = gradle_root / "wrapper" / "dists"
    preferred = sorted(distributions.glob("**/gradle-8.13/bin/gradle"))
    candidates = preferred or sorted(distributions.glob("**/gradle-*/bin/gradle"))
    if not candidates:
        raise TestFailure("Gradle was not found")
    return candidates[-1]


def ensure_device(adb: str, serial: str) -> None:
    output = run([adb, "devices"], capture=True).stdout
    connected = {
        fields[0]
        for line in output.splitlines()[1:]
        if len(fields := line.split()) >= 2 and fields[1] == "device"
    }
    if serial not in connected:
        raise TestFailure(f"Android device {serial} is not connected or authorized")


def stream_instrumentation(adb: str, serial: str, test_class: str, output_path: Path) -> str:
    command = [
        adb,
        "-s",
        serial,
        "shell",
        "am",
        "instrument",
        "-w",
        "-e",
        "class",
        test_class,
        "com.connectedai.hoopreplay.test/androidx.test.runner.AndroidJUnitRunner",
    ]
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=1,
    )
    captured: list[str] = []
    with output_path.open("w", encoding="utf-8") as output:
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            output.write(line)
            captured.append(line)
    status = process.wait()
    text = "".join(captured)
    if status or "OK (1 test)" not in text:
        raise TestFailure("NBA instrumentation test failed")
    return text


def collect_steps(process: subprocess.Popen[str], step_log: Path) -> None:
    with step_log.open("w", encoding="utf-8") as output:
        assert process.stdout is not None
        for line in process.stdout:
            marker = line.find("NBA_STEP ")
            if marker >= 0:
                output.write(line[marker:])
                output.flush()


def latest_pdf_on_device(adb: str, serial: str) -> str:
    result = run(
        [
            adb,
            "-s",
            serial,
            "shell",
            "sh",
            "-c",
            "ls -t /sdcard/Download/HoopReplay/HoopReplay_*_statistics.pdf 2>/dev/null | head -n 1",
        ],
        capture=True,
        check=False,
    )
    return result.stdout.strip().replace("\r", "")


def verify_pdf(pdf_output: Path, render_dir: Path) -> int:
    pdfinfo = command_path("pdfinfo")
    pdftoppm = command_path("pdftoppm")
    info = run([pdfinfo, pdf_output], capture=True).stdout
    print(info, end="" if info.endswith("\n") else "\n")
    match = re.search(r"^Pages:\s+(\d+)\s*$", info, re.MULTILINE)
    pages = int(match.group(1)) if match else 0
    if pages < 2:
        raise TestFailure("Expected a statistics PDF with at least 2 pages")

    render_dir.mkdir(parents=True, exist_ok=True)
    for rendered_page in render_dir.glob("page-*.png"):
        rendered_page.unlink()
    run([pdftoppm, "-png", pdf_output, render_dir / "page"])
    rendered_pages = len(list(render_dir.glob("page-*.png")))
    if rendered_pages != pages:
        raise TestFailure(f"Rendered {rendered_pages} of {pages} PDF pages")
    return pages


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", nargs="?", default=DEFAULT_DEVICE, help="adb device serial")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    adb = command_path("adb")
    ensure_device(adb, args.device)
    gradle = find_gradle()
    test_class = os.environ.get("TEST_CLASS", DEFAULT_TEST_CLASS)
    pdf_output = Path(os.environ.get("PDF_OUTPUT", ROOT / "HoopReplay_statistics_sample.pdf"))
    step_log = Path(os.environ.get("STEP_LOG", TMP_DIR / "nba-final-2026-g1-q1-steps.log"))
    instrument_output = TMP_DIR / "nba-final-2026-g1-q1-instrumentation.log"
    render_dir = TMP_DIR / "pdfs" / "nba-final-2026-g1-q1"

    print("Building app and NBA instrumentation test...")
    run([gradle, "-p", ANDROID_DIR, ":app:assembleDebug", ":app:assembleDebugAndroidTest"])
    app_apk = ANDROID_DIR / "app/build/outputs/apk/debug/app-debug.apk"
    test_apk = ANDROID_DIR / "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    for apk in (app_apk, test_apk):
        if not apk.is_file():
            raise TestFailure(f"APK not found: {apk}")

    print("Installing without clearing existing HoopReplay data...")
    run([adb, "-s", args.device, "install", "-r", app_apk])
    run([adb, "-s", args.device, "install", "-r", "-t", test_apk])
    run([adb, "-s", args.device, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
    run([adb, "-s", args.device, "shell", "wm", "dismiss-keyguard"])
    run([adb, "-s", args.device, "shell", "am", "force-stop", "com.connectedai.hoopreplay"])
    run([adb, "-s", args.device, "shell", "am", "force-stop", "com.connectedai.hoopreplay.test"])

    TMP_DIR.mkdir(parents=True, exist_ok=True)
    run([adb, "-s", args.device, "logcat", "-c"])
    logcat = subprocess.Popen(
        [adb, "-s", args.device, "logcat", "-v", "brief", "HoopReplayNBA:I", "*:S"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=1,
    )
    log_thread = threading.Thread(target=collect_steps, args=(logcat, step_log), daemon=True)
    log_thread.start()
    print(f"Running {test_class}...")
    try:
        stream_instrumentation(adb, args.device, test_class, instrument_output)
    finally:
        logcat.terminate()
        try:
            logcat.wait(timeout=3)
        except subprocess.TimeoutExpired:
            logcat.kill()
            logcat.wait()
        log_thread.join(timeout=3)

    actual_steps = sum(1 for line in step_log.read_text(encoding="utf-8").splitlines() if line.startswith("NBA_STEP "))
    if actual_steps != EXPECTED_STEPS:
        raise TestFailure(f"Expected {EXPECTED_STEPS} chronological play steps, logged {actual_steps}")

    device_pdf = latest_pdf_on_device(adb, args.device)
    if not device_pdf:
        raise TestFailure("Statistics PDF was not found on the device")
    pdf_output.parent.mkdir(parents=True, exist_ok=True)
    run([adb, "-s", args.device, "pull", device_pdf, pdf_output])
    verify_pdf(pdf_output, render_dir)

    print(f"NBA test passed. Statistics PDF: {pdf_output}")
    print(f"Rendered PDF pages: {render_dir}")
    print(f"Chronological step log ({actual_steps} steps): {step_log}")


if __name__ == "__main__":
    try:
        main()
    except (TestFailure, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
