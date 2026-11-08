#!/usr/bin/env python3
"""
hoopvision-stats.py - box score CSV from a reviewed hoopvision shot log.

    python3 scripts/hoopvision-stats.py game.json --out box-score.csv          # hoopvision JSON with `player` filled in
    python3 scripts/hoopvision-stats.py reviewed-shot-log.csv --out box-score.csv [--final Miller=63,Crittenden=32]

Relative output paths are stored under the repository's data/ directory.

A hoopvision JSON is enough on its own: shots carry team / result / points / player and the
final score is inside it. The CSV form is for logs reviewed outside the JSON; its columns are
    video_time, team, player, result, shot, confidence, note
`result` is made / miss / FT / shot / made? / miss?; `shot` is free text such as
"2PT layup", "3PT", "FT 1 of 2 made", "FT 2 made", "2PT (+1 FT after, and-one)".

Output columns (NBA box-score layout, one TEAM column added):
    TEAM, PLAYER, MIN, FGM, FGA, FG%, 3PM, 3PA, 3P%, FTM, FTA, FT%, OREB, DREB, REB, AST, STL, BLK, TO, PF, PTS, +/-
MIN, rebounds, assists, steals, blocks, turnovers, fouls and +/- are left empty (not derivable from
the video pipeline). Players whose number could not be read are pooled into one "Unknown" row per team.
"""
import argparse, csv, math, os, re, collections

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(REPO_ROOT, "data")

def data_output_path(path):
    if os.path.isabs(path):
        return path
    normalized = os.path.normpath(path)
    if normalized == "data" or normalized.startswith(f"data{os.sep}"):
        return os.path.join(REPO_ROOT, normalized)
    return os.path.join(DATA_DIR, normalized)

def parse_player(p):
    """'#11 Alexander Fong?' -> (11, 'Alexander Fong'); '#13 tip' -> (13, '#13'); 'unknown (...)' -> (None, 'Unknown')."""
    m = re.match(r"#(\d+)\s*([^?(,]*)", p or "")
    if not m: return None, "Unknown"
    words = m.group(2).strip().split()
    name = " ".join(words) if words and all(w[:1].isupper() for w in words) else f"#{m.group(1)}"
    return int(m.group(1)), name

def apply(row, st):
    kind = (row["result"] or "").strip(); shot = (row["shot"] or "").lower()
    three = shot.startswith("3pt")
    extra = 2 if re.search(r"x2|two |\+ ?tip|\+ #\d+ tip|then .* tip|second attempt", shot + " " + (row["note"] or "").lower()) else 1
    if kind in ("made", "made?") and row.get("points"):        # JSON input: points are known exactly
        pts = int(row["points"]); st["PTS"] += pts
        if pts == 1: st["FTA"] += 1; st["FTM"] += 1
        else:
            st["FGA"] += 1; st["FGM"] += 1
            if pts == 3: st["3PA"] += 1; st["3PM"] += 1
        return
    if kind in ("made", "made?"):
        st["FGA"] += 1; st["FGM"] += 1; st["PTS"] += 3 if three else 2
        if three: st["3PA"] += 1; st["3PM"] += 1
        if "+1 ft" in shot or "+3 on scoreboard" in shot: st["FTA"] += 1; st["FTM"] += 1; st["PTS"] += 1
        if extra == 2: st["FGA"] += 1                         # a missed tip in the same row
    elif kind in ("miss", "miss?", "shot"):
        st["FGA"] += extra
        if three: st["3PA"] += extra
    elif kind.startswith("FT"):
        m = re.search(r"ft (\d) of (\d)", shot)
        if m: made, att = int(m.group(1)), int(m.group(2))
        else:
            m = re.search(r"ft (\d) made", shot) or re.search(r"\+(\d)", shot)
            if m: made = att = int(m.group(1))
            else:
                m = re.search(r"x(\d)", shot); att = int(m.group(1)) if m else 1; made = 0
        st["FTA"] += att; st["FTM"] += made; st["PTS"] += made
    if (row["confidence"] or "").strip() == "low" or "?" in (row["player"] or ""): st["low"] += 1

def pct(m, a): return f"{100 * m / a:.1f}" if a else ""

def estimated_minutes(keys, stats, team_minutes):
    """Allocate team minutes from video-visible offensive involvement.

    This is intentionally a rough fallback for videos where substitutions and jersey numbers
    cannot be tracked reliably. The square-root weighting prevents one frequent shooter from
    absorbing an unrealistic share, while the baseline gives every identified player time.
    """
    player_keys = [k for k in keys if k[1] is not None]
    if not player_keys:
        return {}
    weights = {
        k: math.sqrt(1.0 + stats[k]["FGA"] + 0.44 * stats[k]["FTA"])
        for k in player_keys
    }
    total_weight = sum(weights.values())
    raw = {k: team_minutes * weights[k] / total_weight for k in player_keys}
    max_minutes = team_minutes / 5
    while any(value > max_minutes for value in raw.values()):
        excess = sum(max(0.0, value - max_minutes) for value in raw.values())
        raw = {k: min(value, max_minutes) for k, value in raw.items()}
        eligible = [k for k, value in raw.items() if value < max_minutes]
        eligible_weight = sum(weights[k] for k in eligible)
        if not eligible or not eligible_weight:
            break
        for k in eligible:
            raw[k] += excess * weights[k] / eligible_weight
    rounded = {k: min(round(v, 1), max_minutes) for k, v in raw.items()}
    # Keep the displayed player values equal to exactly five players times game duration.
    delta = round(team_minutes - sum(rounded.values()), 1)
    anchor = max((k for k in player_keys if rounded[k] + delta <= max_minutes), key=lambda k: raw[k])
    rounded[anchor] = round(rounded[anchor] + delta, 1)
    return rounded

def estimated_plus_minus(minutes, margin, game_minutes):
    """Rough individual +/- proxy normalized to five times the final score margin."""
    if not minutes or not game_minutes:
        return {}
    raw = {k: margin * value / game_minutes for k, value in minutes.items()}
    rounded = {k: int(round(value)) for k, value in raw.items()}
    delta = 5 * margin - sum(rounded.values())
    if delta:
        anchor = max(minutes, key=minutes.get)
        rounded[anchor] += delta
    return rounded

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shot_log", help="hoopvision JSON (players filled in) or a reviewed shot-log CSV")
    ap.add_argument("--out", required=True)
    ap.add_argument("--final", help="final score for the 'Unattributed' rows when the input is a CSV, e.g. Miller=63,Crittenden=32")
    ap.add_argument("--periods", type=int, default=4, help="period count used by rough MIN estimation (default: 4)")
    ap.add_argument("--period-minutes", type=float, default=8, help="minutes per period used by rough MIN estimation (default: 8)")
    args = ap.parse_args()
    args.out = data_output_path(args.out)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    finals = {}
    if args.final:
        finals = {k: int(v) for k, v in (part.split("=") for part in args.final.split(","))}
    if args.shot_log.lower().endswith(".json"):
        import json; g = json.load(open(args.shot_log))
        finals = {g["teams"]["guest"]: g["final_score"]["guest"], g["teams"]["home"]: g["final_score"]["home"]}
        rows = []
        for s in g["shots"]:
            kind = "made" if s["result"] == "made" else "miss"
            shot = ("3PT" if s.get("points") == 3 else "2PT")
            rows.append(dict(team=s.get("team") or "(team unknown)", player=s.get("player") or "", result=kind, shot=shot, confidence="", note="", points=s.get("points") or 0))
        for e in g.get("scoring_events", []):        # baskets / free throws with no detected attempt
            if not any(sh.get("score_time") == e["video_time"] and sh.get("team") == e["team"] for sh in g["shots"]):
                rows.append(dict(team=e["team"], player="", result="FT" if e["points"] == 1 else "made", shot=("FT 1 made" if e["points"] == 1 else ("3PT" if e["points"] == 3 else "2PT")), confidence="", note="scoring event without a detected attempt", points=e["points"]))
    else:
        rows = list(csv.DictReader(open(args.shot_log, encoding="utf-8")))
    stats = collections.OrderedDict()
    for r in rows:
        team = (r["team"] or "").rstrip("?").strip()
        if not team or team == "-": continue
        no, name = parse_player(r["player"])
        key = (team, no, name)
        st = stats.setdefault(key, collections.Counter())
        if key[1] is not None and key[2].startswith("#"):        # merge '#13 tip' style rows into the numbered player
            named = [k for k in stats if k[0] == team and k[1] == no and not k[2].startswith("#")]
            if named: st = stats[named[0]]; del stats[key]
        apply(r, st)
    teams = list(dict.fromkeys(k[0] for k in stats))
    # NBA box-score layout. MIN is a rough video-activity estimate; the remaining non-shooting
    # columns cannot be derived from scoreboard and ball tracking and stay empty.
    cols = ["TEAM", "PLAYER", "MIN", "FGM", "FGA", "FG%", "3PM", "3PA", "3P%", "FTM", "FTA", "FT%",
            "OREB", "DREB", "REB", "AST", "STL", "BLK", "TO", "PF", "PTS", "+/-"]
    def line(team, player, minutes, plus_minus, c):
        return [team, player, minutes, c["FGM"], c["FGA"], pct(c["FGM"], c["FGA"]), c["3PM"], c["3PA"], pct(c["3PM"], c["3PA"]),
                c["FTM"], c["FTA"], pct(c["FTM"], c["FTA"]), "", "", "", "", "", "", "", "", c["PTS"], plus_minus]
    low_conf = collections.Counter()
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(cols)
        for team in teams:
            keys = sorted((k for k in stats if k[0] == team), key=lambda k: (k[1] is None, k[1] or 0))
            team_minutes = 5 * args.periods * args.period_minutes
            game_minutes = args.periods * args.period_minutes
            minutes = estimated_minutes(keys, stats, team_minutes)
            opponents = [name for name in teams if name != team and name in finals]
            margin = finals[team] - finals[opponents[0]] if team in finals and opponents else 0
            plus_minus = estimated_plus_minus(minutes, margin, game_minutes)
            total = collections.Counter()
            for k in keys:
                s = stats[k]; total.update(s); low_conf[team] += s["low"]
                label = k[2] if k[1] is None else (f"#{k[1]} {k[2]}" if not k[2].startswith("#") else k[2])
                w.writerow(line(team, label, f"{minutes[k]:.1f}" if k in minutes else "0.0", plus_minus.get(k, 0), s))
            if team in finals and finals[team] is not None and finals[team] > total["PTS"]:
                w.writerow([team, "Unattributed (unclear plays)", "0.0"] + [""] * 17 + [finals[team] - total["PTS"], 0])
                total["PTS"] = finals[team]
            w.writerow(line(team, "Team Total", f"{team_minutes:.1f}", margin, total))
            print(f"{team}: {total['PTS']} pts, FG {total['FGM']}/{total['FGA']}, 3P {total['3PM']}/{total['3PA']}, FT {total['FTM']}/{total['FTA']}, low-confidence rows {low_conf[team]}")
    print("wrote", args.out)

if __name__ == "__main__":
    main()
