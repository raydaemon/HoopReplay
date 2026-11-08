import { nextId } from "./local-id";
import type { Game, Player, Snapshot, Team } from "./types";

const gameExportKind = "hoopreplay.game";

export type GameExport = Record<string, unknown>;
export type GameImport = {
  snapshot: Snapshot;
  gameId: number;
  events: number;
  createdTeams: number;
  createdPlayers: number;
};

const clean = (value: unknown) => (typeof value === "string" ? value.trim() : "");
const capitalizeInitial = (value: string) => {
  const index = value.search(/\p{L}/u);
  return index === -1
    ? value
    : value.slice(0, index) + value[index].toUpperCase() + value.slice(index + 1);
};

/** File name for a game's JSON export: HoopReplay_$HOME_$AWAY_$DATE_$TIMESTAMP.json, where DATE is the
 * game's scheduled day (yyyyMMdd) and TIMESTAMP is the export moment as yyyyMMdd_HHmmss. */
export function exportGameFileName(snapshot: Snapshot, game: Game, now = new Date()): string {
  const teamName = (id: number) => safeFileToken(snapshot.teams.find((team) => team.id === id)?.name || "Team");
  const pad = (n: number) => String(n).padStart(2, "0");
  const dayOf = (d: Date) => `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
  const stamp = `${dayOf(now)}_${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  return `HoopReplay_${teamName(game.home_id)}_${teamName(game.away_id)}_${dayOf(new Date(game.scheduled_at))}_${stamp}.json`;
}
function safeFileToken(text: string): string {
  return text.trim().replace(/[\\/:*?"<>|_]+/g, "-").replace(/\s+/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "Team";
}

/** Serializes one game in the same shape the Android and iOS apps write, so files move between platforms. */
export function exportGameJson(snapshot: Snapshot, game: Game): GameExport {
  const roster = (teamId: number) =>
    snapshot.players.filter((player) => player.team_id === teamId)
      .map((player) => ({ number: player.number, name: player.name }));
  const playerById = new Map(snapshot.players.map((player) => [player.id, player]));
  const side = (teamId: number) => (teamId === game.home_id ? "HOME" : "AWAY");
  return {
    kind: gameExportKind,
    schemaVersion: 1,
    exportedAt: Date.now(),
    game: {
      title: game.title,
      status: game.status,
      scheduledAt: game.scheduled_at,
      videoQuality: game.video_quality,
      periodCount: game.period_count,
      periodDurationMs: game.period_duration_ms,
      currentPeriod: game.current_period,
      clockRemainingMs: game.clock_remaining_ms,
      homeScore: game.home_score,
      awayScore: game.away_score,
    },
    home: { name: snapshot.teams.find(t => t.id === game.home_id)?.name ?? "", players: roster(game.home_id) },
    away: { name: snapshot.teams.find(t => t.id === game.away_id)?.name ?? "", players: roster(game.away_id) },
    events: snapshot.events.filter((event) => event.game_id === game.id).map((event) => {
      const player = event.player_id === null ? undefined : playerById.get(event.player_id);
      return {
        side: side(event.team_id),
        playerNumber: player?.number ?? "",
        playerName: player?.name ?? "",
        type: event.type,
        value: event.value,
        period: event.period,
        gameClockMs: event.game_clock_ms,
        segment: event.segment,
        segmentTimeMs: event.segment_time_ms,
        finalVideoTimeMs: event.final_video_time_ms,
        reverted: Boolean(event.reverted),
      };
    }),
  };
}

/**
 * Recreates an exported game as a new game in the snapshot. Teams are matched by name and players by
 * jersey number (falling back to the name for unnumbered players); anything missing is created. Video
 * timestamps are dropped because the imported plays do not belong to the new game's recording.
 */
export function importGameJson(snapshot: Snapshot, raw: unknown): GameImport {
  const source = raw as Record<string, unknown>;
  if (!source || source.kind !== gameExportKind) throw new Error("Not a HoopReplay game export");
  const meta = (source.game ?? {}) as Record<string, unknown>;
  const teams: Team[] = [...snapshot.teams];
  const players: Player[] = [...snapshot.players];
  let createdTeams = 0;
  let createdPlayers = 0;

  const findPlayer = (teamId: number, name: string, number: string) => {
    const roster = players.filter((player) => player.team_id === teamId);
    return number
      ? roster.find((player) => player.number.trim() === number)
      : roster.find((player) => !player.number.trim() && name && player.name.toLowerCase() === name.toLowerCase());
  };
  const addPlayer = (teamId: number, name: string, number: string) => {
    const player: Player = { id: nextId(players), team_id: teamId, name: capitalizeInitial(name), number };
    players.push(player);
    createdPlayers += 1;
    return player;
  };
  const resolveTeam = (raw: unknown) => {
    const side = (raw ?? {}) as Record<string, unknown>;
    const name = capitalizeInitial(clean(side.name) || "Unnamed");
    const existing = teams.find((team) => team.name.toLowerCase() === name.toLowerCase());
    const team = existing ?? { id: nextId(teams), name, created_at: Date.now() };
    if (!existing) {
      teams.push(team);
      createdTeams += 1;
    }
    for (const entry of (side.players ?? []) as Array<Record<string, unknown>>) {
      const number = clean(entry.number);
      const name = clean(entry.name);
      if (!number && !name) continue;
      if (!findPlayer(team.id, name, number)) addPlayer(team.id, name, number);
    }
    return team.id;
  };

  const homeId = resolveTeam(source.home);
  const awayId = resolveTeam(source.away);
  const periodDurationMs = Number(meta.periodDurationMs ?? 480_000);
  const game: Game = {
    id: nextId(snapshot.games),
    title: clean(meta.title) || "Imported game",
    home_id: homeId,
    away_id: awayId,
    home_score: Number(meta.homeScore ?? 0),
    away_score: Number(meta.awayScore ?? 0),
    status: clean(meta.status) || "READY",
    scheduled_at: Number(meta.scheduledAt ?? Date.now()),
    video_quality: clean(meta.videoQuality) || "HIGHEST",
    period_count: Number(meta.periodCount ?? 4),
    period_duration_ms: periodDurationMs,
    current_period: Number(meta.currentPeriod ?? 1),
    clock_remaining_ms: Number(meta.clockRemainingMs ?? periodDurationMs),
    created_at: Date.now(),
  };

  const events = [...snapshot.events];
  let imported = 0;
  for (const entry of (source.events ?? []) as Array<Record<string, unknown>>) {
    const teamId = entry.side === "AWAY" ? awayId : homeId;
    const number = clean(entry.playerNumber);
    const name = clean(entry.playerName);
    const player = !number && !name
      ? undefined
      : findPlayer(teamId, name, number) ?? addPlayer(teamId, name, number);
    events.push({
      id: nextId(events),
      game_id: game.id,
      team_id: teamId,
      player_id: player?.id ?? null,
      type: clean(entry.type),
      value: Number(entry.value ?? 1),
      period: Number(entry.period ?? 1),
      game_clock_ms: Number(entry.gameClockMs ?? 0),
      segment: 0,
      segment_time_ms: 0,
      final_video_time_ms: 0,
      reverted: entry.reverted ? 1 : 0,
      created_at: Date.now(),
    });
    imported += 1;
  }

  return {
    snapshot: { ...snapshot, teams, players, games: [...snapshot.games, game], events, updatedAt: Date.now() },
    gameId: game.id,
    events: imported,
    createdTeams,
    createdPlayers,
  };
}
