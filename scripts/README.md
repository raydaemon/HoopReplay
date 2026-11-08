# hoopvision (video stats)

`hoopvision.py` reads a sideline basketball video and writes a JSON shot log.

```bash
python3 scripts/hoopvision.py "game.mp4" --guest Miller --home Crittenden --sheets
```

Requirements: `ffmpeg`, `ffprobe`, `tesseract` on `PATH`; `pip install numpy pillow`.
A 31-minute 1080p video takes about 8 minutes on an M-series Mac (frame extraction, overlay OCR,
scoreboard/ball detection, LED template matching). Generated files are written beneath `data/` by
default. Relative `--out`, `--workdir`, and `--stats-csv` paths are also placed under `data/`.

## What it detects

| Step | Source | Output |
|---|---|---|
| Broadcast overlay OCR | score bar at the bottom of the stream | score timeline with period and clock (lags the game 5-60 s) |
| Gym LED scoreboard | red clock digits next to the backboard | exact moments the guest score changes (template matching labelled by the overlay) |
| Rim + ball detection | deep-red rim, orange ball above it | every shot attempt (`t_start`, `t_end`) |
| Classification | score change within 8 s after the attempt | `made` / `missed`, team and points for made shots |
| `--sheets` | six zoomed frames before each attempt | `review_sheet` image to identify the shooter |

## What it does not do

- Jersey numbers are not recognised. `player` is always `null`; fill it in from the review sheets
  (a person or a vision model).
- The team of a missed shot is unknown.
- The home score on the LED board is not read (on the sample game the scorer under-counted it
  for a half and corrected it later, so the overlay is used for the home team).
- Both baskets in a gym may carry identical LED boards; the tool does not tell the ends apart.

## Overlay layout

The default crop and field boxes match the stream this was built on (score bar at
x=490,y=930,w=940,h=90 in a 1920x1080 frame). Pass `--overlay-config layout.json` with any of
`crop`, `fields`, `logo`, `logo_blue_threshold` to adapt to another stream.

## Notes learned on the sample game

- Seek-based frame grabs (`ffmpeg -ss`) returned wrong frames on the stream recording; frames are
  always decoded sequentially.
- The overlay operator sometimes batches several baskets into one entry, so `d_guest`/`d_home`
  can be larger than 3; the LED timeline splits them.

## Output JSON

```
teams, final_score, score_at_period_end
overlay_score_changes[]   video_time, period, clock, guest, home, d_guest, d_home
led_guest_score_changes   experimental LED template-matching timeline (times are useful, values may be off)
scoring_events[]          one per basket / free throw: video_time, team, points, evidence (led|overlay)
shots[]                   every attempt: video_time, t_start, t_end, result (made|missed), team, points,
                          score_time, player (null), review_sheet
summary                   attempts / made / missed
```

Scoring events sum to the final score. Only attempts whose ball was seen above the rim appear in
`shots`, so free throws and baskets hidden by players usually show up as scoring events without a
matching shot.

## Samples

- `../data/20260903-miller-crittenden.hoopvision.json` - raw tool output for the sample game.
- `../data/20260903-miller-crittenden-reviewed-shot-log.csv` - the same game after a human
  review of the sheets (player, made/missed, confidence, notes).

## Stats CSVs

Team level (automatic, from the video alone):

```bash
python3 scripts/hoopvision.py game.mp4 --guest Miller --home Crittenden --stats-csv team-stats.csv
```

Player level (after the shot log has been reviewed and `player` filled in):

```bash
python3 scripts/hoopvision-stats.py data/game.hoopvision.json --out box-score.csv
python3 scripts/hoopvision-stats.py data/reviewed-shot-log.csv --final Miller=63,Crittenden=32 --out box-score.csv
```

Rough playing-time review sheets and the resulting minutes CSV also stay under `data/`:

```bash
python3 scripts/hoopvision-presence.py sheets data/game.hoopvision --every 1
python3 scripts/hoopvision-presence.py minutes data/game.hoopvision/presence/presence.csv --out minutes.csv --every 1
```

`box-score.csv` uses the NBA box-score layout, one row per player plus `Team Total`:

```
TEAM, PLAYER, MIN, FGM, FGA, FG%, 3PM, 3PA, 3P%, FTM, FTA, FT%, OREB, DREB, REB, AST, STL, BLK, TO, PF, PTS, +/-
```

The shooting columns and PTS are filled from the video. MIN is a rough estimate allocated from each
identified player's video-visible shooting and free-throw activity; it is normalized so each team's
minutes equal five players times the configured game duration. Individual +/- is a rough proxy based
on the final score margin and estimated MIN, not substitution tracking. OREB, DREB, REB, AST, STL,
BLK, TO and PF stay empty because scoreboard and ball tracking cannot produce them. Each team
also gets an `Unknown` row for attempts whose number could not be read and an `Unattributed` row
when the reviewed log credits fewer points than the final score (plays whose outcome was unclear),
so `Team Total` always matches the scoreboard. Sample: `../data/20260903-miller-crittenden-box-score.csv`.
