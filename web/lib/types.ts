type CloudOwned = { owner_id?: string; cloud_sync_space?: string };
export type Team = CloudOwned & { id: number; name: string; created_at: number };
export type Player = CloudOwned & { id: number; team_id: number; name: string; number: string };
export type GameAccessRole = "owner" | "editor" | "viewer";
export type Game = CloudOwned & { access_role?: GameAccessRole; id: number; uuid_id?: string; title: string; home_id: number; away_id: number; home_score: number; away_score: number; status: string; scheduled_at: number; video_quality: string; period_count: number; period_duration_ms: number; current_period: number; clock_remaining_ms: number; created_at: number };
export type StatEvent = CloudOwned & { id: number; game_id: number; team_id: number; player_id: number | null; related_player_id?: number | null; type: string; value: number; period: number; game_clock_ms: number; segment: number; segment_time_ms: number; final_video_time_ms: number; reverted: number; created_at: number };
export type Segment = CloudOwned & { id: number; game_id: number; sequence: number; uri: string; duration_ms: number; created_at: number };

/** Tables whose rows carry a device-local integer id and can therefore be tombstoned. */
export const deletableEntities = ["teams", "players", "games", "events", "segments"] as const;
export type DeletableEntity = (typeof deletableEntities)[number];
/** A deletion is recorded, never inferred from a row's absence, so every device replays the same removal. */
export type Deletion = { entity: DeletableEntity; local_id: number; deleted_at: number; device_id: string };

export type Snapshot = { schemaVersion: number; updatedAt: number; teams: Team[]; players: Player[]; games: Game[]; events: StatEvent[]; segments: Segment[]; deletions: Deletion[] };

export const emptySnapshot = (): Snapshot => ({ schemaVersion: 3, updatedAt: Date.now(), teams: [], players: [], games: [], events: [], segments: [], deletions: [] });

/** Rows a device still holds locally after applying every tombstone it knows about. */
export function applyDeletions<T extends { id: number }>(rows: T[], deletions: Deletion[], entity: DeletableEntity) {
  const removed = new Set(deletions.filter(d => d.entity === entity).map(d => d.local_id));
  return removed.size === 0 ? rows : rows.filter(row => !removed.has(row.id));
}

/** A recreated local id must win over its old tombstone, otherwise the new row is deleted again. */
export function pruneResurrectedDeletions(snapshot: Snapshot) {
  const live: Record<DeletableEntity, Set<number>> = {
    teams: new Set(snapshot.teams.map(row => row.id)),
    players: new Set(snapshot.players.map(row => row.id)),
    games: new Set(snapshot.games.map(row => row.id)),
    events: new Set(snapshot.events.map(row => row.id)),
    segments: new Set(snapshot.segments.map(row => row.id))
  };
  return snapshot.deletions.filter(deletion => !live[deletion.entity].has(deletion.local_id));
}

/** Merges cloud rows into local ones by id, keeping the local copy of anything edited on this device. */
function mergeRows<T extends { id: number }>(local: T[], remote: T[]) {
  const byId = new Map(remote.map(row => [row.id, row] as const));
  // Preserve cloud-managed columns (for example games.uuid_id) when a local edit
  // was based on an older snapshot that did not know about that column yet.
  for (const row of local) byId.set(row.id, { ...byId.get(row.id), ...row });
  return [...byId.values()].sort((a, b) => a.id - b.id);
}

/**
 * Combines a snapshot loaded from the cloud with local edits made while that load was in flight.
 * Without this the in-flight load overwrites the new rows, and the next save pushes a snapshot
 * that no longer contains them.
 */
export function mergeSnapshots(local: Snapshot, remote: Snapshot): Snapshot {
  const deletions = [...new Map(
    [...remote.deletions, ...local.deletions].map(deletion => [`${deletion.entity}:${deletion.local_id}`, deletion] as const)
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
  const live = { ...merged, deletions: pruneResurrectedDeletions(merged) };
  return {
    ...live,
    teams: applyDeletions(live.teams, live.deletions, "teams"),
    players: applyDeletions(live.players, live.deletions, "players"),
    games: applyDeletions(live.games, live.deletions, "games"),
    events: applyDeletions(live.events, live.deletions, "events"),
    segments: applyDeletions(live.segments, live.deletions, "segments")
  };
}
