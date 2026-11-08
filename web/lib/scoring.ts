import type { Game, Player, Snapshot, StatEvent } from "./types";
import { nextId } from "./local-id";
import { comparePlayers } from "./player-sort";

/** Types that move the scoreboard: made shots, free throws, and manual +1/-1 adjustments. */
export const isScoringType = (type: string) => type.startsWith("PTS_") || type === "FT_MADE" || type === "ADJ";

export const rosterOrder = (players: Player[]) => [...players].sort(comparePlayers);

/** "#12 Haoxuan Tan"; a player without a jersey number shows only the name, never "#--". */
export const playerLabel = (player: Pick<Player, "name" | "number">) => {
  const number = (player.number ?? "").trim();
  const name = (player.name ?? "").trim();
  return number ? `#${number} ${name}`.trim() : name;
};

export type GameMoment = { period: number; ms: number };

/** Chronological order of plays: by period, then remaining clock counting down, then insertion. */
export const comparePlays = (a: StatEvent, b: StatEvent) => a.period - b.period || b.game_clock_ms - a.game_clock_ms || a.id - b.id;

/** True when the play happened at or before the moment (a countdown clock, so a larger ms is earlier). */
export const playedBy = (event: StatEvent, at: GameMoment) => event.period < at.period || (event.period === at.period && event.game_clock_ms >= at.ms);

/**
 * The players recorded as this team's starters for a period, in first-appearance order. Reverted
 * events must already be filtered out by the caller.
 */
export function periodStarters(events: StatEvent[], teamId: number, period: number) {
  const starters: number[] = [];
  for (const event of [...events].sort(comparePlays)) {
    if (event.team_id !== teamId || event.period !== period || event.type !== "STARTER" || event.player_id === null) continue;
    if (!starters.includes(event.player_id)) starters.push(event.player_id);
  }
  return starters;
}

/**
 * Replays the lineup events in game order to see who is on the floor, the same way the Android
 * recorder does. With `at` the replay stops at that moment, so after the clock is jumped back to fix
 * a missed substitution the dialog shows the five who were on the court then, not at the end of the
 * game. A period that has its own STARTER records starts from exactly those players: the previous
 * period's floor is not carried into it, otherwise a team confirmed at the start of every period
 * would appear to have ten players on the court. A period with no STARTER records keeps the floor
 * it inherited. Treating "every player with a recorded stat" as the lineup never takes anyone off
 * it, so a team could show more than five players.
 */
export function lineupOf(events: StatEvent[], roster: Player[], teamId: number, at?: GameMoment) {
  const ids = new Set(roster.map((player) => player.id));
  const onCourt = new Set<number>();
  const ordered = [...events].sort(comparePlays);
  const periodsWithStarters = new Set(ordered.filter((event) => event.team_id === teamId && event.type === "STARTER" && event.player_id !== null && ids.has(event.player_id)).map((event) => event.period));
  let period: number | null = null;
  for (const event of ordered) {
    if (at && !playedBy(event, at)) break;
    if (event.team_id !== teamId || event.player_id === null || !ids.has(event.player_id)) continue;
    if (event.period !== period) {
      period = event.period;
      if (periodsWithStarters.has(period)) onCourt.clear();
    }
    if (event.type === "STARTER" || event.type === "SUB_IN") onCourt.add(event.player_id);
    else if (event.type === "SUB_OUT") onCourt.delete(event.player_id);
  }
  return onCourt;
}

/** Grid slots: a named player fills a cell, number-only players pair up two to a cell. */
export function playerGridSlots(players: Player[]) {
  const slots: Player[][] = [];
  let pendingNameless: Player | null = null;
  for (const player of players) {
    if (!player.name.trim()) {
      if (pendingNameless) { slots.push([pendingNameless, player]); pendingNameless = null; }
      else pendingNameless = player;
    } else {
      if (pendingNameless) slots.push([pendingNameless]);
      pendingNameless = null;
      slots.push([player]);
    }
  }
  if (pendingNameless) slots.push([pendingNameless]);
  return slots;
}

export type PlayRequest = { teamId: number; player: Player | null; type: string; value: number; points?: number };

/**
 * Appends one action's plays to the snapshot in order. A STARTER can only happen at the start of a
 * period, so it is stamped with the full period clock no matter when the lineup is confirmed; a stat
 * never creates a STARTER. Players that do not exist yet (picked from the number pad or typed into
 * the "Other Player" row) are added to the roster in the same write.
 */
export function applyPlays(draft: Snapshot, game: Game, plays: PlayRequest[]): Snapshot {
  let players = draft.players;
  let events = draft.events;
  let home = 0;
  let away = 0;
  const period = game.current_period;
  const clock = game.clock_remaining_ms;
  // One timestamp for the whole batch: multi-player substitutions are paired later by created_at.
  const createdAt = Date.now();
  const add = (teamId: number, player: Player | null, type: string, value: number) => {
    const event: StatEvent = {
      id: nextId(events), game_id: game.id, team_id: teamId, player_id: player?.id ?? null,
      owner_id: game.owner_id, cloud_sync_space: game.cloud_sync_space,
      type, value, period, game_clock_ms: type === "STARTER" ? game.period_duration_ms : clock,
      segment: 0, segment_time_ms: 0, final_video_time_ms: 0, reverted: 0, created_at: createdAt,
    };
    events = [...events, event];
  };
  for (const play of plays) {
    const player = play.player;
    if (player && !players.some((row) => row.id === player.id)) players = [...players, player];
    add(play.teamId, player, play.type, play.value);
    const points = play.points ?? 0;
    if (play.teamId === game.home_id) home += points;
    else if (play.teamId === game.away_id) away += points;
  }
  return {
    ...draft,
    players,
    events,
    games: draft.games.map((row) => row.id === game.id
      ? { ...row, home_score: Math.max(0, row.home_score + home), away_score: Math.max(0, row.away_score + away) }
      : row),
  };
}

/** A new roster entry for the team; the id is allocated against the current roster. */
export function newPlayer(players: Player[], teamId: number, name: string, number: string): Player {
  return { id: nextId(players), team_id: teamId, name: name.trim(), number: number.trim() };
}
