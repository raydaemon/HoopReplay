// Shared checks for the highlight routes: who is calling and whether they may see the game.
import { caller } from "../login/shared";
import { call, presign } from "@/lib/r2";

export type HighlightRow = {
  id: string; game_uuid: string; target_key: string; target_label: string; source: "phone" | "cloud";
  object_key: string; duration_ms: number; clip_count: number; created_at: string;
};

/**
 * The caller and their admin client once they are signed in and can see the game, or the error response.
 * `write` also requires the owner or editor role, matching the segments RLS the admin client bypasses.
 */
export async function gameContext(req: Request, gameUuid: unknown, { write = false } = {}) {
  const { user, admin, asUser } = await caller(req);
  if (!user) return { error: Response.json({ error: "Sign in first." }, { status: 401 }) };
  if (typeof gameUuid !== "string" || !/^[\w-]{1,64}$/.test(gameUuid)) return { error: Response.json({ error: "Invalid game." }, { status: 400 }) };
  const { data: game } = await asUser.from("hoop_accessible_games").select("uuid_id, access_role").eq("uuid_id", gameUuid).maybeSingle();
  if (!game) return { error: Response.json({ error: "Game not found." }, { status: 404 }) };
  if (write && game.access_role !== "owner" && game.access_role !== "editor") return { error: Response.json({ error: "You can only view this game." }, { status: 403 }) };
  // Synced events and segments carry the owner's device-local game id, not the game uuid
  // (events.game_uuid_id was only backfilled once), so rows are found by owner + space + local id.
  const { data: owner } = await admin.from("hoop_games").select("user_id, sync_space, local_id").eq("uuid_id", gameUuid).single();
  if (!owner) return { error: Response.json({ error: "Game not found." }, { status: 404 }) };
  const gameRows = { user_id: owner.user_id, sync_space: owner.sync_space, game_id: owner.local_id };
  return { user, admin, asUser, gameUuid, gameRows };
}

export function validTarget(key: unknown): key is string {
  return typeof key === "string" && /^(player|team):[0-9]+$/.test(key);
}

type Admin = Awaited<ReturnType<typeof caller>>["admin"];

/**
 * Records a highlight whose file is already in R2. A newer cut of the same target and source
 * replaces the old row, and the old file is deleted so R2 never keeps orphans.
 */
export async function saveHighlight(admin: Admin, row: HighlightRow & { user_id: string }) {
  const { data: old } = await admin.from("hoop_highlight_videos").select("object_key")
    .eq("game_uuid", row.game_uuid).eq("target_key", row.target_key).eq("source", row.source).maybeSingle();
  const { data, error } = await admin.from("hoop_highlight_videos").upsert(row, { onConflict: "game_uuid,target_key,source" }).select().single();
  if (error) throw new Error(error.message);
  if (old && old.object_key !== row.object_key) await call("DELETE", old.object_key).catch(() => {});
  return publicHighlight(data as HighlightRow);
}

/** What a client may see of a highlight: its presigned URL instead of the R2 key. */
export async function publicHighlight(row: HighlightRow) {
  const { object_key, ...rest } = row;
  // A cross-origin <a download> is ignored by browsers; a signed Content-Disposition forces the save.
  const filename = `${row.target_label.replace(/[^\w .()-]+/g, "_")}.mp4`;
  return {
    ...rest,
    video_url: await presign("GET", object_key),
    download_url: await presign("GET", object_key, { "response-content-disposition": `attachment; filename="${filename}"` }),
  };
}
