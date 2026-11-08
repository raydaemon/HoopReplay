#!/usr/bin/env python3
"""
hoopvision-presence.py - rough playing time from periodic frame samples.

Step 1 (sheets):   python3 scripts/hoopvision-presence.py sheets data/WORKDIR --every 15
    Renders review sheets (WORKDIR/presence/sheet_NNN.jpg) with one row per sample: the play
    area of the frame split into two upscaled halves, labelled with video time and the overlay
    period/clock. Also writes WORKDIR/presence/presence.csv with empty `seen` columns.
Step 2 (review):   fill `seen` with the jersey numbers visible for the team, e.g. "11 13 22".
Step 3 (minutes):  python3 scripts/hoopvision-presence.py minutes data/WORKDIR/presence/presence.csv --out minutes.csv
    A player is on the floor between two sightings closer than --gap seconds of game clock; each
    sighting also counts the half sample interval on both sides. Minutes are game-clock minutes.
    Relative `--out` paths are stored under the repository's data/ directory.
"""
import argparse, csv, json, os, re
from PIL import Image, ImageDraw

FPS = 2; W, H = 1920, 1080
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(REPO_ROOT, "data")

def data_output_path(path):
    if os.path.isabs(path):
        return path
    normalized = os.path.normpath(path)
    if normalized == "data" or normalized.startswith(f"data{os.sep}"):
        return os.path.join(REPO_ROOT, normalized)
    return os.path.join(DATA_DIR, normalized)

def clock_seconds(s):
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", s or "")
    return int(m.group(1)) * 60 + int(m.group(2)) if m else None

def game_time(series, t):
    """(period, clock seconds remaining) for a video time from the per-second overlay readings."""
    best = None
    for s in series:
        if s["period"] and s["clock"] and abs(s["t"] - t) <= 6 and (best is None or abs(s["t"] - t) < abs(best["t"] - t)):
            best = s
    return (best["period"], clock_seconds(best["clock"])) if best else (None, None)

def cmd_sheets(args):
    frames_dir = os.path.join(args.workdir, "frames"); out_dir = os.path.join(args.workdir, "presence"); os.makedirs(out_dir, exist_ok=True)
    import sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import importlib; hv = importlib.import_module("hoopvision")
    rows = json.load(open(os.path.join(args.workdir, "overlay.json")))
    series, _ = hv.overlay_timeline(rows, hv.DEFAULT_OVERLAY)
    n = len([f for f in os.listdir(frames_dir) if f.endswith(".jpg")])
    samples = [i / FPS for i in range(0, n, int(args.every * FPS))]
    csv_rows, tiles = [], []
    for t in samples:
        per, clk = game_time(series, t)
        csv_rows.append(dict(video_time=f"{int(t) // 60:02d}:{int(t) % 60:02d}", t=t, period=per or "", clock=(f"{clk // 60}:{clk % 60:02d}" if clk is not None else ""), seen=""))
        im = Image.open(os.path.join(frames_dir, f"{int(t * FPS) + 1:05d}.jpg")).convert("RGB")
        band = im.crop((0, 120, W, 780))
        for half in (band.crop((0, 0, 960, 660)), band.crop((960, 0, 1920, 660))):
            tile = half.resize((1350, 928), Image.LANCZOS)
            ImageDraw.Draw(tile).text((10, 10), f"{csv_rows[-1]['video_time']}  Q{per or '?'} {csv_rows[-1]['clock']}", fill=(255, 255, 0)); tiles.append(tile)
    per_sheet = 6
    for k in range(0, len(tiles), per_sheet):
        chunk = tiles[k:k + per_sheet]; sheet = Image.new("RGB", (2700, 928 * ((len(chunk) + 1) // 2)))
        for j, tl in enumerate(chunk): sheet.paste(tl, ((j % 2) * 1350, (j // 2) * 928))
        sheet.save(os.path.join(out_dir, f"sheet_{k // per_sheet:03d}.jpg"), quality=80)
    with open(os.path.join(out_dir, "presence.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["video_time", "t", "period", "clock", "seen"]); w.writeheader(); w.writerows(csv_rows)
    print(f"{len(samples)} samples, {(len(tiles) + per_sheet - 1) // per_sheet} sheets -> {out_dir}")

def cmd_minutes(args):
    rows = [r for r in csv.DictReader(open(args.presence)) if r["period"] and r["clock"]]
    # game-clock position in seconds elapsed since tip-off
    period_len = args.period_seconds
    for r in rows:
        r["g"] = (int(r["period"]) - 1) * period_len + (period_len - clock_seconds(r["clock"]))
        r["players"] = set(re.findall(r"\d+", r["seen"]))
    rows.sort(key=lambda r: r["g"])
    players = sorted({p for r in rows for p in r["players"]}, key=int)
    half = args.every / 2
    minutes = {}
    for p in players:
        seen = [r["g"] for r in rows if p in r["players"]]
        total, start, prev = 0.0, None, None
        for g in seen:
            if start is None: start = g
            elif g - prev > args.gap:
                total += (prev - start) + 2 * half; start = g
            prev = g
        if start is not None: total += (prev - start) + 2 * half
        minutes[p] = total / 60
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["PLAYER", "MIN", "sightings"])
        for p in players: w.writerow([f"#{p}", f"{minutes[p]:.1f}", sum(1 for r in rows if p in r["players"])])
    print("team minutes", round(sum(minutes.values()), 1), "(5 players x", len(set(r["period"] for r in rows)), "periods x", period_len // 60, "min =", 5 * len(set(r["period"] for r in rows)) * period_len // 60, ")")
    for p in players: print(f"  #{p}: {minutes[p]:.1f} min")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("sheets"); a.add_argument("workdir"); a.add_argument("--every", type=float, default=15)
    b = sub.add_parser("minutes"); b.add_argument("presence"); b.add_argument("--out", required=True)
    b.add_argument("--every", type=float, default=15, help="sample interval used for the sheets (seconds)")
    b.add_argument("--gap", type=float, default=90, help="max game-clock seconds between sightings of one stint")
    b.add_argument("--period-seconds", type=int, default=420)
    args = ap.parse_args()
    if args.cmd == "minutes":
        args.out = data_output_path(args.out)
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
    cmd_sheets(args) if args.cmd == "sheets" else cmd_minutes(args)

if __name__ == "__main__":
    main()
