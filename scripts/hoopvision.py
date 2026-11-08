#!/usr/bin/env python3
"""
hoopvision.py - turn a sideline basketball video into a JSON shot log.

    python3 hoopvision.py GAME.mp4 [--out game.json] [--workdir game.hoopvision] [--sheets]

Relative output paths are stored under the repository's data/ directory.

Pipeline (everything is derived from the video only):
  1. Decode the video sequentially at 2 fps with ffmpeg (seeking with -ss returned wrong
     frames on some stream recordings, so frames are always read in order).
  2. Read the broadcast overlay (team scores, period, clock) with Tesseract every second and
     smooth it into a score timeline.  The overlay lags the game by 5-60 s.
  3. Find the gym LED scoreboard (bright red clock digits) and the rim next to it, then look
     for the orange ball above the rim; consecutive detections form one shot attempt.
  4. Read the guest score on the LED board with nearest-neighbour template matching, using
     the overlay values as labels; this gives the exact moment each guest basket was scored.
  5. Match every shot attempt with a score change (LED first, overlay second) to decide
     made / missed and which team scored.  Player numbers are NOT recognised: with --sheets
     a contact sheet of the seconds before each attempt is rendered for a human (or a vision
     model) to fill in `player`.

Requires: ffmpeg, ffprobe, tesseract on PATH; python packages numpy and Pillow.
"""
import argparse, json, os, re, subprocess, sys
from multiprocessing import Pool
import numpy as np
from PIL import Image, ImageDraw, ImageOps

FPS = 2
W, H = 1920, 1080
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(REPO_ROOT, "data")

def data_output_path(path):
    """Keep generated artifacts under the repository data directory by default."""
    if os.path.isabs(path):
        return path
    normalized = os.path.normpath(path)
    if normalized == "data" or normalized.startswith(f"data{os.sep}"):
        return os.path.join(REPO_ROOT, normalized)
    return os.path.join(DATA_DIR, normalized)

# ---------------------------------------------------------------- overlay (stream graphics)
DEFAULT_OVERLAY = {
    "crop": [490, 930, 940, 90],              # x, y, w, h of the score bar in a 1920x1080 frame
    "fields": {                                # x0, x1 inside the crop, rows 8..82
        "left": [292, 368], "right": [668, 744], "period": [748, 815], "clock": [835, 915]},
    "logo": [12, 92],                          # x range of the left team logo inside the crop
    "logo_blue_threshold": 120,                # left logo mean blue < threshold -> guest team on the left
}

def ffprobe_duration(video):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                          "default=nw=1:nk=1", video], capture_output=True, text=True).stdout
    return float(out.strip())

def extract_frames(video, frames_dir):
    os.makedirs(frames_dir, exist_ok=True)
    if any(f.endswith(".jpg") for f in os.listdir(frames_dir)):
        return sorted(f for f in os.listdir(frames_dir) if f.endswith(".jpg"))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-vf", f"fps={FPS},scale={W}:{H}",
                    "-q:v", "3", os.path.join(frames_dir, "%05d.jpg")], check=True)
    return sorted(f for f in os.listdir(frames_dir) if f.endswith(".jpg"))

def tesseract(img, psm, whitelist, tmp):
    img.save(tmp)
    out = subprocess.run(["tesseract", tmp, "-", "--psm", str(psm), "-c", f"tessedit_char_whitelist={whitelist}"],
                         capture_output=True).stdout
    return out.decode("utf-8", "ignore").strip()

def _ocr_field(img, psm, wl, tmp):
    img = ImageOps.autocontrast(ImageOps.grayscale(img).resize((img.width * 4, img.height * 4), Image.LANCZOS))
    img = ImageOps.expand(img, border=20, fill=img.getpixel((0, 0)))
    return tesseract(img, psm, wl, tmp)

def _overlay_worker(args):
    path, cfg, tmpdir = args
    x, y, w, h = cfg["crop"]
    im = Image.open(path).convert("RGB").crop((x, y, x + w, y + h))
    tmp = os.path.join(tmpdir, f"ov_{os.getpid()}.png")
    out = {}
    for name, (x0, x1) in cfg["fields"].items():
        psm, wl = (8, "0123456789") if name in ("left", "right") else ((7, "0123456789stndrhOT") if name == "period" else (7, "0123456789:"))
        out[name] = _ocr_field(im.crop((x0, 8, x1, 82)), psm, wl, tmp)
    lx0, lx1 = cfg["logo"]
    out["logo"] = list(im.crop((lx0, 10, lx1, 80)).resize((1, 1), Image.BOX).getpixel((0, 0)))
    return out

def read_overlay(frames_dir, frames, cfg, tmpdir, workers):
    items = [(os.path.join(frames_dir, f), cfg, tmpdir) for f in frames[::FPS]]   # once per second
    with Pool(workers) as p:
        rows = p.map(_overlay_worker, items, chunksize=8)
    for i, r in enumerate(rows):
        r["t"] = float(i)
    return rows

def overlay_timeline(rows, cfg):
    """Stable (3 consecutive identical readings) score pairs -> list of changes."""
    def num(s): return int(s) if re.fullmatch(r"\d{1,2}", s or "") else None
    ser = []
    for r in rows:
        l, rt = num(r["left"]), num(r["right"])
        guest_left = r["logo"][2] < cfg["logo_blue_threshold"]
        g, hm = ((l, rt) if guest_left else (rt, l)) if (l is not None and rt is not None) else (None, None)
        p = re.match(r"(\d)(st|nd|rd|th)", r["period"] or ""); p = int(p.group(1)) if p else None
        clk = r["clock"] if re.fullmatch(r"\d{1,2}:\d{2}", r["clock"] or "") else None
        ser.append(dict(t=r["t"], guest=g, home=hm, period=p, clock=clk))
    events, cur, lastp, lastclk = [], None, None, None
    for i in range(len(ser) - 2):
        a, b, c = ser[i], ser[i + 1], ser[i + 2]
        if a["guest"] is None or (a["guest"], a["home"]) != (b["guest"], b["home"]) or (a["guest"], a["home"]) != (c["guest"], c["home"]):
            continue
        if a["period"]: lastp = a["period"]
        if a["clock"]: lastclk = a["clock"]
        if cur != (a["guest"], a["home"]):
            dg = a["guest"] - (cur[0] if cur else 0); dh = a["home"] - (cur[1] if cur else 0)
            if cur and (dg < -3 or dh < -3):      # OCR glitch: a big drop that is undone next
                continue
            events.append(dict(t=a["t"], guest=a["guest"], home=a["home"], period=lastp, clock=lastclk, d_guest=dg, d_home=dh))
            cur = (a["guest"], a["home"])
    return ser, events

# ---------------------------------------------------------------- LED scoreboard, rim, ball
def led(a):
    band = a[150:420]; r, g, b = band[:, :, 0], band[:, :, 1], band[:, :, 2]
    m = (r > 185) & (g < 130) & (b < 120) & ((r - g) > 90)
    ys, xs = np.nonzero(m)
    if len(xs) < 40: return None
    return (int(np.median(xs)), int(np.median(ys)) + 150)

def panel_box(l):
    return None if not l else (l[0] - 100, l[1] - 55, l[0] + 115, l[1] + 75)

def _exclude(m, box, x0=0, y0=0):
    if box:
        bx0, by0, bx1, by1 = box
        m[max(0, by0 - y0):max(0, by1 - y0), max(0, bx0 - x0):max(0, bx1 - x0)] = False
    return m

def rim(a, box=None):
    band = a[180:360]; r, g, b = band[:, :, 0], band[:, :, 1], band[:, :, 2]
    m = (r > 95) & (r < 185) & (g < 45) & (b < 60) & ((r - g) > 65)
    m = _exclude(m, box, 0, 180)
    ys, xs = np.nonzero(m)
    if len(xs) < 15: return None
    h = np.bincount(xs // 20, minlength=97); w = np.convolve(h, np.ones(4), "same"); k = int(np.argmax(w))
    sel = (xs // 20 >= k - 2) & (xs // 20 <= k + 2)
    if sel.sum() < 15: return None
    x = int(np.median(xs[sel]))
    if x < 40 or x > W - 40: return None
    return (x, int(np.median(ys[sel])) + 180)

def ball(a, rx, ry, box=None):
    x0, x1 = max(0, rx - 300), min(W, rx + 300); y0, y1 = max(0, ry - 200), min(H, ry + 110)
    reg = a[y0:y1, x0:x1]; r, g, b = reg[:, :, 0], reg[:, :, 1], reg[:, :, 2]
    m = (r > 125) & (g > 55) & (g < 140) & (b < 95) & ((r - g) > 50) & ((g - b) > 15)
    m = _exclude(m, box, x0, y0)
    ys, xs = np.nonzero(m)
    if len(xs) < 60: return None
    return (int(len(xs)), int(np.median(xs)) + x0, int(np.median(ys)) + y0)

def _scan_worker(path):
    im = Image.open(path).convert("RGB"); a = np.asarray(im).astype(int)
    l = led(a); box = panel_box(l); r = rim(a, box)
    if r is None and l is not None: r = (l[0] + 160, l[1] - 2)
    b = ball(a, r[0], r[1], box) if r else None
    sig = None
    if l:
        lx, ly = l   # guest score digits sit right of the clock digits on this board model
        crop = ImageOps.autocontrast(ImageOps.grayscale(im.crop((lx + 15, ly - 20, lx + 85, ly + 40)))).resize((28, 24), Image.LANCZOS)
        sig = np.asarray(crop).astype(np.uint8).ravel().tolist()
    return dict(led=l, rim=r, ball=b, sig=sig)

def scan(frames_dir, frames, workers):
    with Pool(workers) as p:
        rows = p.map(_scan_worker, [os.path.join(frames_dir, f) for f in frames], chunksize=16)
    for i, r in enumerate(rows): r["t"] = i / FPS
    return rows

def led_guest_timeline(scan_rows, overlay_series):
    """k-NN on the LED guest-score crop, labelled by the overlay guest score, then monotonic smoothing."""
    label_at = {}
    for s in overlay_series:
        if s["guest"] is not None: label_at[int(s["t"])] = s["guest"]
    # a frame is a template only when the overlay value is stable 6 s before and after it
    templates = []
    for r in scan_rows:
        if not r["sig"]: continue
        t = int(r["t"]); vals = {label_at.get(t + d) for d in range(-6, 7)}
        if len(vals) == 1 and None not in vals:
            templates.append((np.asarray(r["sig"], dtype=np.float32), vals.pop()))
    if not templates: return []
    T = np.stack([v for v, _ in templates]); T = (T - T.mean(axis=1, keepdims=True)) / (T.std(axis=1, keepdims=True) + 1e-6)
    labels = np.array([l for _, l in templates])
    reads = []
    for r in scan_rows:
        if not r["sig"]: reads.append(None); continue
        v = np.asarray(r["sig"], dtype=np.float32); v = (v - v.mean()) / (v.std() + 1e-6)
        d = ((T - v) ** 2).sum(axis=1); k = np.argsort(d)[:7]
        vals, counts = np.unique(labels[k], return_counts=True)
        reads.append(int(vals[np.argmax(counts)]))
    # median over +-5 frames, then a change is accepted when a larger value holds for 3 s
    med = []
    for i in range(len(reads)):
        win = [x for x in reads[max(0, i - 5):i + 6] if x is not None]
        med.append(int(np.median(win)) if win else None)
    changes, cur = [], None
    for i, v in enumerate(med):
        if v is None or v == cur: continue
        if cur is not None and v < cur: continue
        need = 6 if (cur is None or v - cur <= 8) else 20     # a big jump must hold for ~10 s
        hold = [x for x in med[i:i + 60] if x is not None][:need]
        if len(hold) < need or any(x != v for x in hold): continue
        changes.append(dict(t=i / FPS, guest=v)); cur = v
    return changes

# ---------------------------------------------------------------- shot attempts
def shot_attempts(scan_rows):
    hits = [r for r in scan_rows if r["ball"] and abs(r["ball"][1] - r["rim"][0]) < 120 and -160 < r["ball"][2] - r["rim"][1] < 40]
    clusters = []
    for r in hits:
        if clusters and r["t"] - clusters[-1][-1]["t"] <= 2.0: clusters[-1].append(r)
        else: clusters.append([r])
    out = []
    for c in clusters:
        mindy = min(r["ball"][2] - r["rim"][1] for r in c)
        if mindy >= -20: continue                       # never above the rim: a pass or a dribble
        out.append(dict(t_start=c[0]["t"], t_end=c[-1]["t"], frames=len(c), min_dy=int(mindy)))
    return out

def score_events(overlay_events, led_changes, guest_name, home_name):
    """One scoring event per overlay change. The overlay supplies the points; for the guest team
    the time is refined with the nearest earlier LED change (the overlay lags 5-60 s)."""
    used, events = set(), []
    def undo(team, points):            # the overlay operator corrected an earlier entry
        for i in range(len(events) - 1, -1, -1):
            if events[i]["team"] == team and events[i]["points"] == points:
                del events[i]; return
    for e in overlay_events:
        if e["d_guest"] < 0: undo(guest_name, -e["d_guest"])
        if e["d_home"] < 0: undo(home_name, -e["d_home"])
        if e["d_guest"] > 0:
            cands = [(c["t"], i) for i, c in enumerate(led_changes) if i not in used and e["t"] - 60 <= c["t"] <= e["t"] + 2]
            if cands:
                t, i = max(cands); used.add(i); events.append(dict(t=t, team=guest_name, points=e["d_guest"], evidence="led", overlay_t=e["t"]))
            else:
                events.append(dict(t=e["t"], team=guest_name, points=e["d_guest"], evidence="overlay", overlay_t=e["t"]))
        if e["d_home"] > 0:
            events.append(dict(t=e["t"], team=home_name, points=e["d_home"], evidence="overlay", overlay_t=e["t"]))
    return events

def classify(shots, events):
    """A shot attempt is 'made' when a scoring event follows it: within 6 s for LED-timed events,
    within 15 s for overlay-timed ones (the overlay lag). Each event is used once."""
    used = set()
    for s in shots:
        s.update(result="missed", team=None, points=0, evidence=None)
        best = None
        for i, e in enumerate(events):
            if i in used: continue
            lo, hi = (s["t_end"] - 1, s["t_end"] + 6) if e["evidence"] == "led" else (s["t_end"], s["t_end"] + 15)
            if lo <= e["t"] <= hi and (best is None or e["t"] < events[best]["t"]): best = i
        if best is not None:
            used.add(best); e = events[best]
            s.update(result="made", team=e["team"], points=e["points"], evidence=e["evidence"], score_time=fmt(e["t"]))
    return shots

# ---------------------------------------------------------------- review sheets
def render_sheet(frames_dir, t, offs, name, cw=700, ch=467):
    tiles = []
    for d in offs:
        i = max(0, int(round((t - d) * FPS)))
        im = Image.open(os.path.join(frames_dir, f"{i + 1:05d}.jpg")).convert("RGB")
        a = np.asarray(im.crop((0, 0, W, 400))).astype(int)
        m = (a[:, :, 0] > 170) & (a[:, :, 1] < 110) & (a[:, :, 2] < 110); ys, xs = np.nonzero(m)
        cx, cy = (int(np.median(xs)), int(np.median(ys))) if len(xs) >= 30 else (W // 2, 150)
        x0 = max(0, min(W - cw, cx - cw * 250 // 900)); y0 = max(0, min(H - ch, cy - ch * 60 // 600))
        tile = im.crop((x0, y0, x0 + cw, y0 + ch)).resize((1350, 900), Image.LANCZOS)
        tt = i / FPS; ImageDraw.Draw(tile).text((10, 10), f"{tt // 60:02.0f}:{tt % 60:04.1f}", fill=(255, 255, 0)); tiles.append(tile)
    rows = (len(tiles) + 1) // 2; out = Image.new("RGB", (2700, 900 * rows))
    for k, tl in enumerate(tiles): out.paste(tl, ((k % 2) * 1350, (k // 2) * 900))
    out.save(name, quality=80)

# ---------------------------------------------------------------- main
def fmt(t): return f"{int(t) // 60:02d}:{t % 60:04.1f}"

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video"); ap.add_argument("--out", default=None); ap.add_argument("--workdir", default=None)
    ap.add_argument("--guest", default="Guest"); ap.add_argument("--home", default="Home")
    ap.add_argument("--overlay-config", default=None, help="JSON file overriding the overlay crop/fields")
    ap.add_argument("--sheets", action="store_true", help="render a review sheet per shot attempt")
    ap.add_argument("--stats-csv", default=None, help="also write a team-level stats CSV (points per period, detected attempts)")
    ap.add_argument("--workers", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()
    video = os.path.abspath(args.video)
    stem = os.path.splitext(os.path.basename(video))[0]
    out_path = data_output_path(args.out) if args.out else os.path.join(DATA_DIR, f"{stem}.hoopvision.json")
    workdir = data_output_path(args.workdir) if args.workdir else os.path.join(DATA_DIR, f"{stem}.hoopvision")
    frames_dir = os.path.join(workdir, "frames"); tmpdir = os.path.join(workdir, "tmp"); os.makedirs(tmpdir, exist_ok=True)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    cfg = dict(DEFAULT_OVERLAY)
    if args.overlay_config: cfg.update(json.load(open(args.overlay_config)))

    duration = ffprobe_duration(video)
    print(f"[1/5] extracting frames at {FPS} fps ({duration:.0f}s) ...", flush=True)
    frames = extract_frames(video, frames_dir)
    print(f"[2/5] reading the broadcast overlay ({len(frames) // FPS} frames) ...", flush=True)
    cache = os.path.join(workdir, "overlay.json")
    if os.path.exists(cache): rows = json.load(open(cache))
    else:
        rows = read_overlay(frames_dir, frames, cfg, tmpdir, args.workers); json.dump(rows, open(cache, "w"))
    series, overlay_events = overlay_timeline(rows, cfg)
    print(f"      {len(overlay_events)} overlay score changes", flush=True)
    print(f"[3/5] scoreboard, rim and ball detection ({len(frames)} frames) ...", flush=True)
    cache = os.path.join(workdir, "scan.json")
    if os.path.exists(cache): scan_rows = json.load(open(cache))
    else:
        scan_rows = scan(frames_dir, frames, args.workers); json.dump(scan_rows, open(cache, "w"))
    print(f"[4/5] LED guest score timeline ...", flush=True)
    led_changes = led_guest_timeline(scan_rows, series)
    print(f"      {len(led_changes)} LED guest score changes", flush=True)
    print(f"[5/5] shot attempts ...", flush=True)
    events = score_events(overlay_events, led_changes, args.guest, args.home)
    shots = classify(shot_attempts(scan_rows), events)
    sheets_dir = os.path.join(workdir, "sheets")
    if args.sheets:
        os.makedirs(sheets_dir, exist_ok=True)
        for s in shots:
            name = os.path.join(sheets_dir, f"shot_{int(s['t_end']):04d}.jpg")
            render_sheet(frames_dir, s["t_end"], [4.0, 3.5, 3.0, 2.5, 2.0, 1.5], name); s["review_sheet"] = name
    made = [s for s in shots if s["result"] == "made"]
    per_period = {}
    for e in overlay_events:
        if e["period"]: per_period[e["period"]] = dict(guest=e["guest"], home=e["home"])
    result = dict(
        video=video, duration_s=round(duration, 1), fps_analyzed=FPS,
        teams=dict(guest=args.guest, home=args.home),
        final_score=dict(guest=overlay_events[-1]["guest"] if overlay_events else None, home=overlay_events[-1]["home"] if overlay_events else None),
        score_at_period_end=per_period,
        overlay_score_changes=[dict(video_time=fmt(e["t"]), t=e["t"], period=e["period"], clock=e["clock"], guest=e["guest"], home=e["home"], d_guest=e["d_guest"], d_home=e["d_home"]) for e in overlay_events],
        led_guest_score_changes=dict(note="experimental: values come from overlay-labelled template matching and may be off; the times are what matter",
                                     changes=[dict(video_time=fmt(c["t"]), t=c["t"], guest=c["guest"]) for c in led_changes]),
        scoring_events=[dict(video_time=fmt(e["t"]), t=e["t"], team=e["team"], points=e["points"], evidence=e["evidence"]) for e in events],
        shots=[dict(video_time=fmt(s["t_end"]), t_start=s["t_start"], t_end=s["t_end"], result=s["result"], team=s["team"], points=s["points"],
                    evidence=s["evidence"], score_time=s.get("score_time"), player=None, review_sheet=s.get("review_sheet")) for s in shots],
        summary=dict(attempts=len(shots), made=len(made), missed=len(shots) - len(made)),
        notes=["player is left null: fill it in from the review sheets", "team is only known for made shots (from the scoreboard); missed shots need the review sheet",
               "the overlay lags the game; LED changes are the accurate timestamps for the guest team"],
    )
    json.dump(result, open(out_path, "w"), indent=1)
    if args.stats_csv:
        stats_csv = data_output_path(args.stats_csv)
        os.makedirs(os.path.dirname(stats_csv), exist_ok=True)
        import csv
        with open(stats_csv, "w", newline="") as f:
            w = csv.writer(f); periods = sorted(per_period)
            w.writerow(["Team", "PTS"] + [f"Q{p}" for p in periods] + ["FGM (detected)", "FGA (team known)", "3PT made", "Scoring events"])
            for side, team in (("guest", args.guest), ("home", args.home)):
                prev, qp = 0, []
                for p in periods: qp.append(per_period[p][side] - prev); prev = per_period[p][side]
                team_shots = [s for s in shots if s["team"] == team]
                w.writerow([team, result["final_score"][side]] + qp + [len([s for s in team_shots if s["result"] == "made"]), len(team_shots),
                            len([s for s in team_shots if s["result"] == "made" and s["points"] == 3]), len([e for e in events if e["team"] == team])])
            w.writerow(["(team unknown)", ""] + [""] * len(periods) + ["", len([s for s in shots if s["team"] is None]), "", ""])
        print("stats csv:", stats_csv)
    print(f"done: {len(shots)} attempts, {len(made)} made -> {out_path}")

if __name__ == "__main__":
    main()
