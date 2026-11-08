import { createClient } from "@supabase/supabase-js";
import { call } from "@/lib/r2";

export const dynamic = "force-dynamic";
export const maxDuration = 300;

/** Every R2 prefix that holds one game's objects (see footageKey, highlight and cut-cache keys). */
const PREFIXES = ["footage", "highlights", "cache"];
const BATCH = 25;

const xmlValues = (xml: string, tag: string) =>
  [...xml.matchAll(new RegExp(`<${tag}>([^<]*)</${tag}>`, "g"))].map(m => m[1].replace(/&amp;/g, "&").replace(/&quot;/g, "\""));

/** Deletes every object and aborts every unfinished multipart upload under `prefix`. */
async function purgePrefix(prefix: string) {
  for (;;) {
    const listed = await (await call("GET", "", { query: { "list-type": "2", prefix, "max-keys": "1000" } })).text();
    const keys = xmlValues(listed, "Key");
    for (const key of keys) await call("DELETE", key);
    if (keys.length === 0 || !listed.includes("<IsTruncated>true</IsTruncated>")) break;
  }
  const uploads = await (await call("GET", "", { query: { uploads: "", prefix } })).text();
  for (const block of uploads.match(/<Upload>[\s\S]*?<\/Upload>/g) ?? []) {
    const [key] = xmlValues(block, "Key");
    const [uploadId] = xmlValues(block, "UploadId");
    if (key && uploadId) await call("DELETE", key, { query: { uploadId } });
  }
}

/**
 * A deleted game's footage, highlights, cut cache and replay video are unreachable (its id is
 * retired and the rows cascaded away) but would otherwise stay in storage forever, at the
 * operator's cost. Each run clears a batch of retired ids that have not been purged yet.
 */
export async function GET(request: Request) {
  const cronSecret = process.env.CRON_SECRET;
  if (!cronSecret || request.headers.get("authorization") !== `Bearer ${cronSecret}`) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return Response.json({ error: "Purge environment variables are not configured" }, { status: 500 });
  const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });

  const { data, error } = await admin.from("hoop_retired_game_ids").select("id")
    .is("purged_at", null).order("retired_at").limit(BATCH);
  if (error) return Response.json({ error: error.message }, { status: 502 });
  const purged: string[] = [];
  const failed: string[] = [];
  for (const { id } of data ?? []) {
    try {
      if (!/^[0-9a-f-]{36}$/.test(id)) throw new Error("Unexpected game id");
      for (const prefix of PREFIXES) await purgePrefix(`${prefix}/${id}/`);
      const removed = await admin.storage.from("replay-videos").remove([`${id}.mp4`]);
      if (removed.error) throw new Error(removed.error.message);
      const marked = await admin.from("hoop_retired_game_ids").update({ purged_at: new Date().toISOString() }).eq("id", id);
      if (marked.error) throw new Error(marked.error.message);
      purged.push(id);
    } catch (cause) {
      console.error("Purging deleted game failed", id, cause);
      failed.push(id);
    }
  }
  return Response.json({ purged: purged.length, failed: failed.length }, { status: failed.length ? 207 : 200 });
}
