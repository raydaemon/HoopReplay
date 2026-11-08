// GET lists a game's highlights; POST cuts one in the cloud from the game's uploaded footage.
// The cut reads each recording over presigned HTTP range requests (only the needed seconds are
// fetched), re-encodes every clip to the same 720p H.264/AAC, and joins them without re-encoding.
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import ffmpegPath from "ffmpeg-static";
import { highlightClips, type Clip, type ClipEvent, type HighlightTarget } from "@/lib/highlight-clips";
import { call, exists, presign } from "@/lib/r2";
import { gameContext, publicHighlight, saveHighlight, validTarget, type HighlightRow } from "./shared";

export const dynamic = "force-dynamic";

export const maxDuration = 300;

const run = promisify(execFile);
/** Stop starting new clips this long into a request; the function limit is 300 s. */
const CUT_BUDGET_MS = 200_000;
/** Worst-case time to cut one clip on Vercel (~28 s measured for 4K → 720p). */
const CLIP_COST_MS = 45_000;

export async function GET(req: Request) {
  const ctx = await gameContext(req, new URL(req.url).searchParams.get("game_uuid"));
  if ("error" in ctx) return ctx.error;
  const { data, error } = await ctx.admin.from("hoop_highlight_videos").select("*").eq("game_uuid", ctx.gameUuid).order("created_at", { ascending: false });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json(await Promise.all((data as HighlightRow[]).map(publicHighlight)));
}

/** POST {game_uuid, target_key, target_label} → 202 {status:"cutting", done, total} until every clip is cut, then 200 {status:"ready", highlight}; 409 {missing} when footage is not uploaded. */
export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const ctx = await gameContext(req, body.game_uuid);
  if ("error" in ctx) return ctx.error;
  if (!validTarget(body.target_key)) return Response.json({ error: "Invalid highlight." }, { status: 400 });
  const { admin, user, gameUuid, gameRows } = ctx;
  const [kind, id] = body.target_key.split(":");
  const target: HighlightTarget = kind === "player" ? { player_id: Number(id) } : { team_id: Number(id) };

  const [events, segments] = await Promise.all([
    admin.from("hoop_events").select("team_id, player_id, type, segment, segment_time_ms, reverted").match(gameRows).range(0, 19999),
    admin.from("hoop_segments").select("sequence, duration_ms, object_key, upload_status").match(gameRows).range(0, 999),
  ]);
  if (events.error || segments.error) return Response.json({ error: (events.error ?? segments.error)!.message }, { status: 500 });
  const clipEvents = (events.data as Array<Omit<ClipEvent, "reverted"> & { reverted: boolean }>).map(e => ({ ...e, reverted: e.reverted ? 1 : 0 }));
  const clips = highlightClips(clipEvents, segments.data, target);
  if (clips.length === 0) return Response.json({ error: "No plays for this selection." }, { status: 422 });
  const bySequence = new Map(segments.data.map(s => [s.sequence, s]));
  const missing = [...new Set(clips.map(c => c.segment))].filter(n => bySequence.get(n)?.upload_status !== "uploaded");
  if (missing.length) return Response.json({ error: "Some recordings are not uploaded yet.", missing }, { status: 409 });

  // Vercel's CPU turns a 4K → 720p clip into ~30 s of work, so one request cannot cut a whole
  // highlight within the function limit. Each finished clip is cached in R2 under a key that
  // names its exact source window; a request cuts what it can in its time budget and answers
  // 202 {done, total} until every clip exists, then joins them. The Web card keeps calling.
  const clipKey = (clip: Clip) => `cache/${gameUuid}/${clip.segment}-${clip.start_ms}-${clip.end_ms}.mp4`;
  const cached = await Promise.all(clips.map(clip => exists(clipKey(clip))));
  const deadline = Date.now() + CUT_BUDGET_MS;
  const dir = await mkdtemp(path.join(tmpdir(), "highlight-"));
  try {
    for (const [i, clip] of clips.entries()) {
      if (cached[i] || Date.now() + CLIP_COST_MS > deadline) continue;
      const out = path.join(dir, `clip-${i}.mp4`);
      await run(ffmpegPath!, [
        "-v", "error", "-ss", String(clip.start_ms / 1000), "-t", String((clip.end_ms - clip.start_ms) / 1000), "-i", await presign("GET", bySequence.get(clip.segment)!.object_key!),
        "-vf", "scale=-2:720", "-r", "30", "-c:v", "libx264", "-preset", "veryfast", "-b:v", "5M",
        "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2", out,
      ]);
      await call("PUT", clipKey(clip), { body: await readFile(out), headers: { "content-type": "video/mp4" } });
      await rm(out, { force: true });
      cached[i] = true;
    }
    const done = cached.filter(Boolean).length;
    if (done < clips.length) return Response.json({ status: "cutting", done, total: clips.length }, { status: 202 });

    const parts: string[] = [];
    for (const [i, clip] of clips.entries()) {
      const out = path.join(dir, `part-${i}.mp4`);
      await writeFile(out, Buffer.from(await (await call("GET", clipKey(clip))).arrayBuffer()));
      parts.push(out);
    }
    const list = path.join(dir, "list.txt");
    await writeFile(list, parts.map(p => `file '${p}'`).join("\n"));
    const joined = path.join(dir, "highlight.mp4");
    await run(ffmpegPath!, ["-v", "error", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", "-movflags", "+faststart", joined]);

    const highlightId = randomUUID();
    const objectKey = `highlights/${gameUuid}/${highlightId}.mp4`;
    await call("PUT", objectKey, { body: await readFile(joined), headers: { "content-type": "video/mp4" } });
    const saved = await saveHighlight(admin, {
      id: highlightId, game_uuid: gameUuid, user_id: user.id, target_key: body.target_key, target_label: String(body.target_label ?? "").slice(0, 120),
      source: "cloud", object_key: objectKey, duration_ms: clips.reduce((sum, c) => sum + c.end_ms - c.start_ms, 0), clip_count: clips.length,
      created_at: new Date().toISOString(),
    });
    await Promise.all(clips.map(clip => call("DELETE", clipKey(clip)).catch(() => {})));
    return Response.json({ status: "ready", highlight: saved });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Could not cut the highlight." }, { status: 502 });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
