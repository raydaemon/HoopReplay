// Shared checks for the highlight routes: who is calling and whether they may see the game.
import { caller } from "../login/shared";
import { call, presign } from "@/lib/r2";

export type HighlightRow = {
  id: string; game_uuid: string; target_key: string; target_label: string; source: "phone" | "cloud";
  object_key: string; duration_ms: number; clip_count: number; created_at: string;
};

/**
 * The caller and their admin client once they are signed in and can see the game, or the error response.
 * `write` also requires the owner or editor role, `owner` the owner role (the admin client bypasses RLS).
 */
export async function gameContext(req: Request, gameUuid: unknown, { write = false, owner: ownerOnly = false } = {}) {
  const { user, admin, asUser } = await caller(req);
  if (!user) return { error: Response.json({ error: "Sign in first." }, { status: 401 }) };
  if (!isUuid(gameUuid)) return { error: Response.json({ error: "Invalid game." }, { status: 400 }) };
  const { data: game } = await asUser.from("hoop_accessible_games").select("id, access_role").eq("id", gameUuid).maybeSingle();
  if (!game) return { error: Response.json({ error: "Game not found." }, { status: 404 }) };
  if (write && game.access_role !== "owner" && game.access_role !== "editor") return { error: Response.json({ error: "You can only view this game." }, { status: 403 }) };
  // Recordings belong to the owner: editors may not create or replace segments (as the segments trigger enforces).
  if (ownerOnly && game.access_role !== "owner") return { error: Response.json({ error: "Only the game owner can upload recordings." }, { status: 403 }) };
  // Events and segments reference games.id; the owner tuple keeps the match on the owner's rows.
  const { data: owner } = await admin.from("hoop_games").select("user_id, sync_space").eq("id", gameUuid).single();
  if (!owner) return { error: Response.json({ error: "Game not found." }, { status: 404 }) };
  const gameRows = { user_id: owner.user_id, sync_space: owner.sync_space, game_id: gameUuid };
  return { user, admin, asUser, gameUuid, gameRows };
}

/** Where a game's recording segment lives in R2. Always derived here, never read from a row clients can write. */
export const footageKey = (gameUuid: string, sequence: number) => `footage/${gameUuid}/${sequence}.mp4`;

/**
 * ffmpeg flags placed before `-i` for media a client uploaded: read it only as MP4/MOV over
 * HTTPS, so a file posing as a playlist or concat list cannot make the server fetch other URLs.
 */
export const UNTRUSTED_INPUT = ["-protocol_whitelist", "https,tls,tcp", "-f", "mov"];

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

/** A lowercase canonical UUID (games.id, row ids). */
export function isUuid(value: unknown): value is string {
  return typeof value === "string" && new RegExp(`^${UUID}$`).test(value);
}

/** `player:<uuid>` or `team:<uuid>`. */
export function validTarget(key: unknown): key is string {
  return typeof key === "string" && new RegExp(`^(player|team):${UUID}$`).test(key);
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
