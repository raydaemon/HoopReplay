import type { User } from "@supabase/supabase-js";
import {
  applyDeletions,
  deletableEntities,
  emptySnapshot,
  SNAPSHOT_SCHEMA_VERSION,
  type DeletableEntity,
  type Deletion,
  type Snapshot
} from "./types";
import { supabase, syncSpace } from "./supabase";

const ownership = (user: User) => ({ user_id: user.id, sync_space: syncSpace });

function stripCloudColumns<T extends Record<string, unknown>>(row: T) {
  // The owner tuple is remembered (never dropped) so a foreign row is never pushed as our own.
  const value: Record<string, unknown> = { ...row };
  const owner_id = String(value.user_id);
  const cloud_sync_space = String(value.sync_space);
  delete value.user_id;
  delete value.sync_space;
  delete value.legacy_local_id;
  return { ...value, owner_id, cloud_sync_space };
}

function toDeletion(row: Record<string, unknown>): Deletion {
  return {
    entity: row.entity as DeletableEntity,
    row_id: String(row.row_id),
    deleted_at: Number(row.deleted_at),
    device_id: String(row.device_id ?? "")
  };
}

/** Deleting rows one id list at a time keeps the PostgREST filter inside a sane URL length. */
/** Supabase's PostgREST max_rows; requesting more than this returns only this many. */
const PAGE_SIZE = 1000;

function chunk<T>(values: T[], size = 200) {
  const batches: T[][] = [];
  for (let index = 0; index < values.length; index += size) batches.push(values.slice(index, index + size));
  return batches;
}

export async function loadSnapshot(user: User): Promise<Snapshot> {
  if (!supabase) return emptySnapshot();
  if (!user.id) return emptySnapshot();
  const client = supabase;
  const tables = [...deletableEntities, "deletions"] as const;
  // PostgREST caps every response at the project's max_rows (1000), so a single select silently
  // drops the newest events of a busy account. Page until a short page says the table is done.
  const fetchAll = async (table: string) => {
    const rows: Record<string, unknown>[] = [];
    for (let from = 0; ; from += PAGE_SIZE) {
      const { data, error } = await client
        .from(table === "games" ? "hoop_accessible_games" : `hoop_${table}`)
        .select("*")
        .eq("sync_space", syncSpace)
        .order(table === "deletions" ? "row_id" : "id")
        .order("user_id")
        .range(from, from + PAGE_SIZE - 1);
      if (error) throw error;
      rows.push(...((data ?? []) as Record<string, unknown>[]));
      if ((data ?? []).length < PAGE_SIZE) return rows;
    }
  };
  const [teams, players, games, events, segments, deletionRows] = await Promise.all(tables.map(fetchAll));
  const [teamRows, playerRows, gameRows, eventRows, segmentRows] = [teams, players, games, events, segments].map(rows => rows.map(stripCloudColumns));
  const deletions = deletionRows.map(toDeletion);
  // The server already applied every tombstone, but replaying them here means a device that
  // merges cloud rows into local ones can never resurrect something another device deleted.
  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    updatedAt: Date.now(),
    teams: applyDeletions(teamRows as Snapshot["teams"], deletions, "teams"),
    players: applyDeletions(playerRows as Snapshot["players"], deletions, "players"),
    // Legacy games kept their random v4 ids, so creation order comes from created_at, not the id.
    games: applyDeletions((gameRows as Snapshot["games"]).sort((a, b) => a.created_at - b.created_at), deletions, "games"),
    events: applyDeletions(
      (eventRows as Array<Omit<Snapshot["events"][number], "reverted"> & { reverted: boolean }>)
        .map(event => ({ ...event, reverted: event.reverted ? 1 : 0 })),
      deletions,
      "events"
    ),
    segments: applyDeletions(segmentRows as Snapshot["segments"], deletions, "segments"),
    deletions
  };
}

/** Returns the tombstones that were pushed, so the caller can keep local state aligned. */
export async function saveSnapshot(user: User, snapshot: Snapshot): Promise<Deletion[]> {
  if (!supabase) return snapshot.deletions;
  const client = supabase;
  const owner = ownership(user);
  const upsert = async (table: string, rows: Record<string, unknown>[], onConflict: string) => {
    if (rows.length === 0) return;
    const { error } = await client.from(`hoop_${table}`).upsert(rows, { onConflict });
    if (error) throw error;
  };
  const rows = (table: string, values: Record<string, unknown>[]) => upsert(table, values, "id");
  // A pulled row keeps its owner tuple; only rows created here get ours.
  const cloudRow = <T extends { owner_id?: string; cloud_sync_space?: string }>(row: T) => {
    const { owner_id, cloud_sync_space, ...value } = row;
    return { ...value, user_id: owner_id ?? user.id, sync_space: cloud_sync_space ?? syncSpace };
  };
  const ownerKey = (row: { owner_id?: string; cloud_sync_space?: string }) =>
    `${row.owner_id ?? user.id}/${row.cloud_sync_space ?? syncSpace}`;
  const mine = (row: { owner_id?: string; cloud_sync_space?: string }) => ownerKey(row) === `${user.id}/${syncSpace}`;
  const writableGames = snapshot.games.filter(game => mine(game) || game.access_role === "editor");
  const writableGameById = new Map(writableGames.map(game => [game.id, game] as const));
  const ownGameIds = new Set(snapshot.games.filter(mine).map(game => game.id));
  // events.player_id has no ON DELETE clause, so a player row can only go once nothing points at
  // it. Events recorded on another device since this page loaded may still reference the player
  // in the cloud; detach those too, the same way the mobile apps null player_id.
  const detachPlayerEvents = async (playerIds: string[]) => {
    const { error } = await client.from("hoop_events").update({ player_id: null })
      .eq("user_id", owner.user_id)
      .eq("sync_space", owner.sync_space)
      .in("player_id", playerIds);
    if (error) throw error;
  };
  // games.home_id/away_id and events.team_id also block deletes. A team that a cloud game or
  // event still needs (one this device never loaded) must stay; otherwise the tombstone would fail
  // every save from now on. Such a tombstone is never pushed, and the next reload brings it back.
  const referencedTeams = async (teamIds: string[]) => {
    const blocked = new Set<string>();
    for (const teamId of teamIds) {
      const [games, events] = await Promise.all([
        client.from("hoop_games").select("id")
          .eq("user_id", owner.user_id).eq("sync_space", owner.sync_space)
          .or(`home_id.eq.${teamId},away_id.eq.${teamId}`).limit(1),
        client.from("hoop_events").select("id")
          .eq("user_id", owner.user_id).eq("sync_space", owner.sync_space)
          .eq("team_id", teamId).limit(1)
      ]);
      const error = games.error ?? events.error;
      if (error) throw error;
      if ((games.data?.length ?? 0) > 0 || (events.data?.length ?? 0) > 0) blocked.add(teamId);
    }
    return blocked;
  };
  let deletions = snapshot.deletions;
  const deletedTeams = deletions.filter(deletion => deletion.entity === "teams").map(deletion => deletion.row_id);
  const blockedTeams = new Set<string>();
  for (const batch of chunk(deletedTeams)) for (const id of await referencedTeams(batch)) blockedTeams.add(id);
  if (blockedTeams.size > 0) deletions = deletions.filter(deletion => !(deletion.entity === "teams" && blockedTeams.has(deletion.row_id)));

  const applyTombstones = async (entity: DeletableEntity) => {
    const ids = deletions.filter(deletion => deletion.entity === entity).map(deletion => deletion.row_id);
    for (const batch of chunk(ids)) {
      if (entity === "players") await detachPlayerEvents(batch);
      // Ids are globally unique; RLS decides which of them this user may delete.
      const { error } = await client.from(`hoop_${entity}`).delete().in("id", batch);
      if (error) throw error;
    }
  };

  await upsert(
    "deletions",
    deletions.map(deletion => ({ ...owner, ...deletion })),
    "user_id,sync_space,entity,row_id"
  );
  // Surviving rows go first: deleting a player, for example, is only legal once the events that
  // referenced them have been rewritten to point at nobody.
  await rows("teams", snapshot.teams.filter(mine).map(cloudRow));
  await rows("players", snapshot.players.filter(mine).map(cloudRow));
  await rows("games", writableGames.map(game => {
    const row = { ...game };
    delete row.access_role;
    return cloudRow(row);
  }));
  // The server rejects segments an editor creates or changes, so only the owner pushes them.
  await rows("segments", snapshot.segments.filter(row => mine(row) && ownGameIds.has(row.game_id)).map(cloudRow));
  // An event belongs to its game's owner, also when an editor recorded it here.
  await rows("events", snapshot.events.flatMap(({ reverted, ...row }) => {
    const game = writableGameById.get(row.game_id);
    return game ? [{ ...cloudRow({ ...row, owner_id: game.owner_id, cloud_sync_space: game.cloud_sync_space }), reverted: Boolean(reverted) }] : [];
  }));

  // Dependent rows first so the relational schema stays valid while tombstones are applied.
  for (const entity of ["events", "segments", "games", "players", "teams"] as const) await applyTombstones(entity);
  return deletions;
}
