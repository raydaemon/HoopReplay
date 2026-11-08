type CloudOwned = { owner_id?: string; cloud_sync_space?: string };
/** Row ids are lowercase UUIDv7 strings shared by every client and the server (see lib/local-id.ts). */
export type Team = CloudOwned & { id: string; name: string; created_at: number };
export type Player = CloudOwned & { id: string; team_id: string; name: string; number: string };
export type GameAccessRole = "owner" | "editor" | "viewer";
export type Game = CloudOwned & { access_role?: GameAccessRole; id: string; title: string; home_id: string; away_id: string; home_score: number; away_score: number; status: string; scheduled_at: number; video_quality: string; period_count: number; period_duration_ms: number; current_period: number; clock_remaining_ms: number; created_at: number };
export type StatEvent = CloudOwned & { id: string; game_id: string; team_id: string; player_id: string | null; related_player_id?: string | null; type: string; value: number; period: number; game_clock_ms: number; segment: number; segment_time_ms: number; final_video_time_ms: number; reverted: number; created_at: number };
export type Segment = CloudOwned & { id: string; game_id: string; sequence: number; uri: string; duration_ms: number; created_at: number };

/** Synced tables whose rows can be tombstoned. */
export const deletableEntities = ["teams", "players", "games", "events", "segments"] as const;
export type DeletableEntity = (typeof deletableEntities)[number];
/** A deletion is recorded, never inferred from a row's absence, so every device replays the same removal. */
export type Deletion = { entity: DeletableEntity; row_id: string; deleted_at: number; device_id: string };

export type Snapshot = { schemaVersion: number; updatedAt: number; teams: Team[]; players: Player[]; games: Game[]; events: StatEvent[]; segments: Segment[]; deletions: Deletion[] };

/** Snapshot layout version: 4 = UUID row ids. */
export const SNAPSHOT_SCHEMA_VERSION = 4;

export const emptySnapshot = (): Snapshot => ({ schemaVersion: SNAPSHOT_SCHEMA_VERSION, updatedAt: Date.now(), teams: [], players: [], games: [], events: [], segments: [], deletions: [] });

/** Rows a device still holds locally after applying every tombstone it knows about. */
export function applyDeletions<T extends { id: string }>(rows: T[], deletions: Deletion[], entity: DeletableEntity) {
  const removed = new Set(deletions.filter(d => d.entity === entity).map(d => d.row_id));
  return removed.size === 0 ? rows : rows.filter(row => !removed.has(row.id));
}

/** Merges cloud rows into local ones by id, keeping the local copy of anything edited on this device. */
function mergeRows<T extends { id: string }>(local: T[], remote: T[]) {
  const byId = new Map(remote.map(row => [row.id, row] as const));
  // Keep cloud-managed columns (owner_id, access_role, ...) that an older local copy lacks.
  for (const row of local) byId.set(row.id, { ...byId.get(row.id), ...row });
  return [...byId.values()];
}

/**
 * Combines a snapshot loaded from the cloud with local edits made while that load was in flight.
 * Without this the in-flight load overwrites the new rows, and the next save pushes a snapshot
 * that no longer contains them.
 */
export function mergeSnapshots(local: Snapshot, remote: Snapshot): Snapshot {
  const deletions = [...new Map(
    [...remote.deletions, ...local.deletions].map(deletion => [`${deletion.entity}:${deletion.row_id}`, deletion] as const)
  ).values()];
  const merged: Snapshot = {
    schemaVersion: Math.max(local.schemaVersion, remote.schemaVersion),
    updatedAt: Date.now(),
    teams: mergeRows(local.teams, remote.teams),
    players: mergeRows(local.players, remote.players),
    games: mergeRows(local.games, remote.games),
    events: mergeRows(local.events, remote.events),
    segments: mergeRows(local.segments, remote.segments),
    deletions
  };
  // Ids are never reused, so a tombstone always wins.
  return {
    ...merged,
    teams: applyDeletions(merged.teams, deletions, "teams"),
    players: applyDeletions(merged.players, deletions, "players"),
    games: applyDeletions(merged.games, deletions, "games"),
    events: applyDeletions(merged.events, deletions, "events"),
    segments: applyDeletions(merged.segments, deletions, "segments")
  };
}
