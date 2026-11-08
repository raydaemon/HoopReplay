// One AI replay video per game through the Gemini API: Flash turns the play-by-play into a Veo
// prompt, Veo renders an 8-second clip, and the finished mp4 is copied into Supabase Storage
// (Google keeps it only two days). POST starts a generation, GET reports and advances it.
import { caller, env, reserveUsage } from "../login/shared";
import { isUuid } from "../highlights/shared";
import {
  GEMINI_API, GENERATION_TIMEOUT_MS, PROMPT_MODEL, VIDEO_MODEL,
  operationState, promptFromResponse, promptRequest, videoRequest,
} from "@/lib/replay-video";

export const dynamic = "force-dynamic";
export const maxDuration = 120;

const BUCKET = "replay-videos";
/** A failing game may be retried this many times in total; Veo renders cost real money. */
const MAX_ATTEMPTS = 3;
/** Renders one user may start per day (UTC) across all their games: games are free to create. */
const DAILY_RENDERS = 3;
const SIGNED_URL_SECONDS = 60 * 60;

async function gemini(path: string, body?: unknown) {
  const res = await fetch(`${GEMINI_API}/${path}`, {
    method: body ? "POST" : "GET",
    headers: { "x-goog-api-key": env("GEMINI_API_KEY"), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json?.error?.message ?? `Gemini ${res.status}`);
  return json;
}

/** The caller, the game uuid and the row for it, or the error response to return instead. */
async function context(req: Request, gameUuid: string) {
  const { user, admin, asUser } = await caller(req);
  if (!user) return { error: Response.json({ error: "Sign in first." }, { status: 401 }) };
  if (!isUuid(gameUuid)) return { error: Response.json({ error: "Invalid game." }, { status: 400 }) };
  const { data: game } = await asUser.from("hoop_accessible_games").select("id, access_role").eq("id", gameUuid).maybeSingle();
  if (!game) return { error: Response.json({ error: "Game not found." }, { status: 404 }) };
  const { data: row } = await admin.from("hoop_replay_videos").select("*").eq("game_uuid", gameUuid).maybeSingle();
  return { user, admin, game, row: row as Row | null };
}

type Row = { status: string; operation_name: string | null; video_url: string | null; error: string | null; created_at: string; attempts: number };
type Admin = Awaited<ReturnType<typeof caller>>["admin"];

/** What the page may see: a ready video comes as a signed URL that expires, never the storage path. */
async function publicRow(admin: Admin, gameUuid: string, row: Row | null) {
  if (!row) return { status: "none" };
  let video_url: string | null = null;
  if (row.status === "ready") {
    const { data } = await admin.storage.from(BUCKET).createSignedUrl(`${gameUuid}.mp4`, SIGNED_URL_SECONDS);
    video_url = data?.signedUrl ?? null;
  }
  return { status: row.status, video_url, error: row.error };
}

export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const gameUuid = typeof body.game_uuid === "string" ? body.game_uuid : "";
  const ctx = await context(req, gameUuid);
  if ("error" in ctx) return ctx.error;
  const { user, admin, game, row } = ctx;
  if (game.access_role !== "owner") return Response.json({ error: "Only the game owner can generate the replay video." }, { status: 403 });
  if (row && row.status !== "failed") return Response.json(await publicRow(admin, gameUuid, row));
  if (row && row.attempts >= MAX_ATTEMPTS) return Response.json({ error: "This game has reached its replay video limit." }, { status: 429 });
  const input = {
    title: String(body.title ?? "Game").slice(0, 120), away: String(body.away ?? "Away").slice(0, 60), home: String(body.home ?? "Home").slice(0, 60),
    awayScore: Number(body.away_score) || 0, homeScore: Number(body.home_score) || 0, plays: String(body.plays ?? ""),
  };
  try {
    if (!(await reserveUsage(admin, user.id, "replay_video", 1, DAILY_RENDERS))) {
      return Response.json({ error: "Daily replay video limit reached. Try again tomorrow." }, { status: 429 });
    }
    // Claim the attempt before any paid call: the conditional upsert lets one request through per
    // attempt, so parallel POSTs cannot start several renders (see 20261107190000_usage_quotas.sql).
    const { data: attempt, error: claimError } = await admin.rpc("hoop_reserve_replay_attempt", { p_game: gameUuid, p_user: user.id, p_max: MAX_ATTEMPTS });
    if (claimError) throw new Error(claimError.message);
    if (attempt == null) {
      const { data: current } = await admin.from("hoop_replay_videos").select("*").eq("game_uuid", gameUuid).maybeSingle();
      return current && (current as Row).status !== "failed"
        ? Response.json(await publicRow(admin, gameUuid, current as Row))
        : Response.json({ error: "This game has reached its replay video limit." }, { status: 429 });
    }
    try {
      const prompt = promptFromResponse(await gemini(`models/${PROMPT_MODEL}:generateContent`, promptRequest(input)));
      if (!prompt) throw new Error("Gemini returned no prompt.");
      const operation = await gemini(`models/${VIDEO_MODEL}:predictLongRunning`, videoRequest(prompt));
      const patch = { operation_name: operation.name as string, prompt, updated_at: new Date().toISOString() };
      const { data: saved, error } = await admin.from("hoop_replay_videos").update(patch).eq("game_uuid", gameUuid).select("*").single();
      if (error) throw new Error(error.message);
      return Response.json(await publicRow(admin, gameUuid, saved as Row));
    } catch (error) {
      const message = error instanceof Error ? error.message : "Could not start the video.";
      await admin.from("hoop_replay_videos").update({ status: "failed", error: message, updated_at: new Date().toISOString() }).eq("game_uuid", gameUuid);
      throw error;
    }
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Could not start the video." }, { status: 502 });
  }
}

export async function GET(req: Request) {
  const gameUuid = new URL(req.url).searchParams.get("game_uuid") ?? "";
  const ctx = await context(req, gameUuid);
  if ("error" in ctx) return ctx.error;
  const { admin, row } = ctx;
  if (!row || row.status !== "generating") return Response.json(await publicRow(admin, gameUuid, row));
  // A POST has claimed the attempt but not yet started the render: wait, unless it died.
  if (!row.operation_name) {
    if (Date.now() - Date.parse(row.created_at) > GENERATION_TIMEOUT_MS) {
      await admin.from("hoop_replay_videos").update({ status: "failed", error: "Video generation timed out.", updated_at: new Date().toISOString() }).eq("game_uuid", gameUuid);
      return Response.json(await publicRow(admin, gameUuid, { ...row, status: "failed", error: "Video generation timed out." }));
    }
    return Response.json(await publicRow(admin, gameUuid, row));
  }
  const update = async (patch: Partial<Row>) => {
    await admin.from("hoop_replay_videos").update({ ...patch, updated_at: new Date().toISOString() }).eq("game_uuid", gameUuid);
    return Response.json(await publicRow(admin, gameUuid, { ...row, ...patch }));
  };
  try {
    const state = operationState(await gemini(row.operation_name ?? ""));
    if (!state.done) {
      if (Date.now() - Date.parse(row.created_at) > GENERATION_TIMEOUT_MS) return update({ status: "failed", error: "Video generation timed out." });
      return Response.json(await publicRow(admin, gameUuid, row));
    }
    if ("error" in state) return update({ status: "failed", error: state.error });
    const download = await fetch(state.uri, { headers: { "x-goog-api-key": env("GEMINI_API_KEY") } });
    if (!download.ok) throw new Error(`Video download failed (${download.status}).`);
    const path = `${gameUuid}.mp4`;
    const { error } = await admin.storage.from(BUCKET).upload(path, await download.arrayBuffer(), { contentType: "video/mp4", upsert: true });
    if (error) throw new Error(error.message);
    // The row keeps the storage path; every response signs a fresh URL for it.
    return update({ status: "ready", video_url: path, error: null });
  } catch (error) {
    return update({ status: "failed", error: error instanceof Error ? error.message : "Video generation failed." });
  }
}
