import type { User } from "@supabase/supabase-js";
import {
  applyDeletions,
  deletableEntities,
  emptySnapshot,
  pruneResurrectedDeletions,
  type DeletableEntity,
  type Deletion,
  type Snapshot
} from "./types";
import { supabase, syncSpace } from "./supabase";

const ownership = (user: User) => ({ user_id: user.id, sync_space: syncSpace });

function stripCloudColumns<T extends Record<string, unknown>>(row: T) {
  const value: Record<string, unknown> = { ...row };
  const local_id = value.local_id;
  const owner_id = String(value.user_id);
  const cloud_sync_space = String(value.sync_space);
  delete value.user_id;
  delete value.sync_space;
  delete value.local_id;
  return { ...value, owner_id, cloud_sync_space, id: Number(local_id) };
}

function toDeletion(row: Record<string, unknown>): Deletion {
  return {
    entity: row.entity as DeletableEntity,
    local_id: Number(row.local_id),
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
        .gte("local_id", 0)
        .order("local_id")
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
    schemaVersion: 3,
    updatedAt: Date.now(),
    teams: applyDeletions(teamRows as Snapshot["teams"], deletions, "teams"),
    players: applyDeletions(playerRows as Snapshot["players"], deletions, "players"),
    games: applyDeletions(gameRows as Snapshot["games"], deletions, "games"),
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

/** Returns the tombstones that survived pruning, so the caller can keep local state aligned. */
export async function saveSnapshot(user: User, snapshot: Snapshot): Promise<Deletion[]> {
  if (!supabase) return snapshot.deletions;
  const client = supabase;
  const owner = ownership(user);
  let deletions = pruneResurrectedDeletions(snapshot);
  const upsert = async (table: string, rows: Record<string, unknown>[], onConflict: string) => {
    if (rows.length === 0) return;
    const { error } = await client.from(`hoop_${table}`).upsert(rows, { onConflict });
    if (error) throw error;
  };
  const rows = (table: string, values: Record<string, unknown>[]) => upsert(table, values, "user_id,sync_space,local_id");
  const cloudRow = <T extends { owner_id?: string; cloud_sync_space?: string; id: number }>(row: T) => {
    const { owner_id, cloud_sync_space, id, ...value } = row;
    return { user_id: owner_id ?? user.id, sync_space: cloud_sync_space ?? syncSpace, local_id: id, ...value };
  };
  const writableGames = snapshot.games.filter(game => !game.owner_id || game.owner_id === user.id || game.access_role === "editor");
  const writableGameKeys = new Set(writableGames.map(game => `${game.owner_id ?? user.id}:${game.id}`));
  // Absence never means deletion. Only an explicit tombstone removes a row, so a device saving a
  // stale snapshot can no longer wipe rows another device created while it was out of date.
  // events.player_id has no ON DELETE clause, so a player row can only go once nothing points at
  // it. The local snapshot already orphaned the events it knows about, but events recorded on
  // another device since this page loaded still reference the player in the cloud; detach those
  // too, the same way the Android app nulls player_id when it deletes a player.
  const detachPlayerEvents = async (playerIds: number[]) => {
    const { error } = await client.from("hoop_events").update({ player_id: null })
      .eq("user_id", owner.user_id)
      .eq("sync_space", owner.sync_space)
      .in("player_id", playerIds);
    if (error) throw error;
  };
  // games.home_id/away_id and events.team_id also block deletes. A team that a cloud game or
  // event still needs (one this device never loaded, or a stale tombstone another device already
  // resurrected) must stay; otherwise the tombstone would fail every save from now on. Such a
  // tombstone is dropped instead, and the next reload brings the team back.
  const referencedTeams = async (teamIds: number[]) => {
    const blocked = new Set<number>();
    for (const teamId of teamIds) {
      const [games, events] = await Promise.all([
        client.from("hoop_games").select("local_id")
          .eq("user_id", owner.user_id).eq("sync_space", owner.sync_space)
          .or(`home_id.eq.${teamId},away_id.eq.${teamId}`).limit(1),
        client.from("hoop_events").select("local_id")
          .eq("user_id", owner.user_id).eq("sync_space", owner.sync_space)
          .eq("team_id", teamId).limit(1)
      ]);
      const error = games.error ?? events.error;
      if (error) throw error;
      if ((games.data?.length ?? 0) > 0 || (events.data?.length ?? 0) > 0) blocked.add(teamId);
    }
    return blocked;
  };
  const applyTombstones = async (entity: DeletableEntity) => {
    const ids = deletions.filter(deletion => deletion.entity === entity).map(deletion => deletion.local_id);
    for (const batch of chunk(ids)) {
      if (entity === "players") await detachPlayerEvents(batch);
      const blocked = entity === "teams" ? await referencedTeams(batch) : new Set<number>();
      const deletable = batch.filter(id => !blocked.has(id));
      if (blocked.size > 0) {
        deletions = deletions.filter(deletion => !(deletion.entity === entity && blocked.has(deletion.local_id)));
      }
      if (deletable.length === 0) continue;
      const { error } = await client.from(`hoop_${entity}`).delete()
        .eq("user_id", owner.user_id)
        .eq("sync_space", owner.sync_space)
        .in("local_id", deletable);
      if (error) throw error;
    }
  };

  await upsert(
    "deletions",
    deletions.map(deletion => ({ ...owner, ...deletion })),
    "user_id,sync_space,entity,local_id"
  );
  // Surviving rows go first: deleting a player, for example, is only legal once the events that
  // referenced them have been rewritten to point at nobody.
  await rows("teams", snapshot.teams.filter(row => !row.owner_id || row.owner_id === user.id).map(cloudRow));
  await rows("players", snapshot.players.filter(row => !row.owner_id || row.owner_id === user.id).map(cloudRow));
  await rows("games", writableGames.map(game => {
    const row = { ...game };
    delete row.access_role;
    return cloudRow(row);
  }));
  await rows("segments", snapshot.segments.filter(row => writableGameKeys.has(`${row.owner_id ?? user.id}:${row.game_id}`)).map(cloudRow));
  await rows("events", snapshot.events.filter(row => writableGameKeys.has(`${row.owner_id ?? user.id}:${row.game_id}`)).map(({ reverted, ...row }) => ({ ...cloudRow(row), reverted: Boolean(reverted) })));

  // Dependent rows first so the relational schema stays valid while tombstones are applied.
  for (const entity of ["events", "segments", "games", "players", "teams"] as const) await applyTombstones(entity);

  // A resurrected id dropped its tombstone above; drop it on the server too.
  const resurrected = snapshot.deletions.filter(deletion =>
    !deletions.some(kept => kept.entity === deletion.entity && kept.local_id === deletion.local_id)
  );
  for (const deletion of resurrected) {
    const { error } = await client.from("hoop_deletions").delete()
      .eq("user_id", owner.user_id)
      .eq("sync_space", owner.sync_space)
      .eq("entity", deletion.entity)
      .eq("local_id", deletion.local_id);
    if (error) throw error;
  }
  return deletions;
}
