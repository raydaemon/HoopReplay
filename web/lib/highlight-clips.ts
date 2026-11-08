/**
 * The highlight clip rule shared by Android, iOS and the cloud cutter (spec:
 * docs/superpowers/specs/2026-10-04-video-highlights-design.md). Each play becomes a window
 * from 8 s before to 2 s after it was recorded, kept inside its own recording; overlapping or
 * touching windows merge. highlight-clips.fixture.json pins the result on every platform.
 */

export type ClipEvent = { team_id: number; player_id: number | null; type: string; segment: number; segment_time_ms: number; reverted: number };
export type ClipSegment = { sequence: number; duration_ms: number };
export type HighlightTarget = { player_id: number } | { team_id: number };
export type Clip = { segment: number; start_ms: number; end_ms: number };

export const CLIP_BEFORE_MS = 8000;
export const CLIP_AFTER_MS = 2000;
export const TEAM_TYPES = ["PTS_1", "PTS_2", "PTS_3", "FT_MADE"];
export const PLAYER_TYPES = [...TEAM_TYPES, "REB", "OREB", "DREB", "AST", "STL", "BLK"];

export function highlightClips(events: ClipEvent[], segments: ClipSegment[], target: HighlightTarget): Clip[] {
  const durations = new Map(segments.filter(s => s.sequence > 0).map(s => [s.sequence, s.duration_ms]));
  const windows = events
    .filter(e => !e.reverted && durations.has(e.segment) && ("player_id" in target
      ? e.player_id === target.player_id && PLAYER_TYPES.includes(e.type)
      : e.team_id === target.team_id && TEAM_TYPES.includes(e.type)))
    .map(e => ({
      segment: e.segment,
      start_ms: Math.max(0, e.segment_time_ms - CLIP_BEFORE_MS),
      end_ms: Math.min(durations.get(e.segment)!, e.segment_time_ms + CLIP_AFTER_MS),
    }))
    // A play stamped past the end of its recording has nothing to show.
    .filter(w => w.start_ms < w.end_ms)
    .sort((a, b) => a.segment - b.segment || a.start_ms - b.start_ms);
  const clips: Clip[] = [];
  for (const w of windows) {
    const last = clips.at(-1);
    if (last && last.segment === w.segment && w.start_ms <= last.end_ms) last.end_ms = Math.max(last.end_ms, w.end_ms);
    else clips.push({ ...w });
  }
  return clips;
}
