// A phone that just cut a highlight asks here where to PUT it, uploads straight to R2, then
// calls /api/highlights/upload/complete so the row only exists once the file does.
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import ffmpegPath from "ffmpeg-static";
import { call, exists, presign } from "@/lib/r2";
import { gameContext, saveHighlight, UNTRUSTED_INPUT, validTarget } from "../shared";

export const dynamic = "force-dynamic";
/** Remuxing a highlight of a few hundred MB takes seconds, but well over the default function limit. */
export const maxDuration = 300;

/**
 * Phones write the mp4 index (moov) at the end of the file, and browsers will not start a
 * presigned R2 video until they have it. Remux in place without re-encoding so it leads.
 */
async function faststart(key: string) {
  const out = path.join(tmpdir(), `${randomUUID()}.mp4`);
  try {
    await promisify(execFile)(ffmpegPath!, ["-v", "error", "-y", ...UNTRUSTED_INPUT, "-i", await presign("GET", key), "-c", "copy", "-movflags", "+faststart", out]);
    await call("PUT", key, { body: await readFile(out), headers: { "content-type": "video/mp4" } });
  } finally {
    await rm(out, { force: true });
  }
}

const objectKey = (gameUuid: string, id: string) => `highlights/${gameUuid}/${id}.mp4`;

/** POST {game_uuid} → {id, put_url}: a fresh object to upload the mp4 to. */
export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const ctx = await gameContext(req, body.game_uuid, { write: true });
  if ("error" in ctx) return ctx.error;
  const id = randomUUID();
  return Response.json({ id, put_url: await presign("PUT", objectKey(ctx.gameUuid, id)) });
}

/** PUT {game_uuid, id, target_key, target_label, duration_ms, clip_count} → the saved highlight. */
export async function PUT(req: Request) {
  const body = await req.json().catch(() => ({}));
  const ctx = await gameContext(req, body.game_uuid, { write: true });
  if ("error" in ctx) return ctx.error;
  const { admin, user, gameUuid } = ctx;
  if (typeof body.id !== "string" || !/^[0-9a-f-]{36}$/.test(body.id) || !validTarget(body.target_key)) return Response.json({ error: "Invalid highlight." }, { status: 400 });
  const key = objectKey(gameUuid, body.id);
  if (!(await exists(key))) return Response.json({ error: "The video has not been uploaded." }, { status: 409 });
  try {
    await faststart(key);
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Could not finish the video." }, { status: 502 });
  }
  const row = {
    id: body.id, game_uuid: gameUuid, user_id: user.id, target_key: body.target_key, target_label: String(body.target_label ?? "").slice(0, 120),
    source: "phone" as const, object_key: key, duration_ms: Math.max(0, Number(body.duration_ms) || 0), clip_count: Math.max(0, Number(body.clip_count) || 0),
    created_at: new Date().toISOString(),
  };
  try {
    return Response.json(await saveHighlight(admin, row));
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Could not save the highlight." }, { status: 500 });
  }
}
