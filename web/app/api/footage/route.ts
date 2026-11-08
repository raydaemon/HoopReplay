// Whole-game recordings go to R2 as S3 multipart uploads so a phone can resume after losing
// Wi-Fi or being killed. POST starts (or resumes) one segment's upload and returns a presigned
// URL for every part still missing; PUT completes it and marks the segment uploaded.
import { call, presign, xmlValue } from "@/lib/r2";
import { reserveUsage } from "../login/shared";
import { footageKey, gameContext } from "../highlights/shared";

export const dynamic = "force-dynamic";

/** 16 MB parts: a 6 GB recording is ~375 parts, well under S3's 10,000-part limit. */
const PART_SIZE = 16 * 1024 * 1024;
/** Largest recording segment accepted. Presigned part PUTs cannot cap their size, so completion checks it. */
const MAX_SEGMENT_BYTES = 12 * 1024 * 1024 * 1024;
/** New multipart uploads one user may start per day (resuming one is free). */
const DAILY_UPLOADS = 200;

function segmentInput(body: Record<string, unknown>) {
  const sequence = Number(body.sequence);
  const size = Number(body.size);
  // S3 allows at most 10,000 parts; a larger claimed size would only make us presign URLs in a loop.
  return Number.isInteger(sequence) && sequence > 0 && Number.isFinite(size) && size > 0 && size <= MAX_SEGMENT_BYTES ? { sequence, size } : null;
}

/** Parts R2 already holds for this upload (number → ETag and size), or null when the upload id is unknown or expired. */
async function uploadedParts(key: string, uploadId: string) {
  const res = await call("GET", key, { query: { uploadId, "max-parts": "10000" } }).catch(() => null);
  if (!res) return null;
  // One <Part> block at a time: S3 lists ETag before PartNumber, and a lazy match across blocks
  // would pair a part's number with the next part's ETag (R2 then rejects the completion).
  const parts = [...(await res.text()).matchAll(/<Part>([\s\S]*?)<\/Part>/g)].map(m => m[1]);
  return new Map(parts.flatMap(block => {
    const number = Number(xmlValue(block, "PartNumber"));
    const etag = xmlValue(block, "ETag")?.replace(/&quot;/g, "\"");
    const size = Number(xmlValue(block, "Size"));
    return number && etag ? [[number, { etag, size }] as const] : [];
  }));
}

/** POST {game_uuid, sequence, size, upload_id?} → {upload_id, part_size, parts: [{number, url}], done: [{number, etag}]} */
export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const ctx = await gameContext(req, body.game_uuid, { write: true, owner: true });
  if ("error" in ctx) return ctx.error;
  const input = segmentInput(body);
  if (!input) return Response.json({ error: "Invalid recording." }, { status: 400 });
  const { admin, gameUuid, gameRows } = ctx;
  const key = footageKey(gameUuid, input.sequence);
  try {
    let uploadId = typeof body.upload_id === "string" && body.upload_id ? body.upload_id : null;
    let done = uploadId ? await uploadedParts(key, uploadId) : null;
    if (!uploadId || !done) {
      if (!(await reserveUsage(admin, ctx.user.id, "footage_upload", 1, DAILY_UPLOADS))) {
        return Response.json({ error: "Daily recording upload limit reached. Try again tomorrow." }, { status: 429 });
      }
      uploadId = xmlValue(await (await call("POST", key, { query: { uploads: "" }, headers: { "content-type": "video/mp4" } })).text(), "UploadId");
      if (!uploadId) throw new Error("R2 returned no upload id.");
      done = new Map();
    }
    const { data: marked, error } = await admin.from("hoop_segments").update({ object_key: key, upload_status: "uploading" }).match(gameRows).eq("sequence", input.sequence).select("sequence");
    if (error) throw new Error(error.message);
    if (!marked?.length) return Response.json({ error: "Sync this game before uploading its recordings." }, { status: 409 });
    const count = Math.ceil(input.size / PART_SIZE);
    const parts = await Promise.all(Array.from({ length: count }, (_, i) => i + 1).filter(n => !done.has(n))
      .map(async number => ({ number, url: await presign("PUT", key, { partNumber: String(number), uploadId: uploadId! }) })));
    return Response.json({ upload_id: uploadId, part_size: PART_SIZE, parts, done: [...done].map(([number, { etag }]) => ({ number, etag })) });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Could not start the upload." }, { status: 502 });
  }
}

/** PUT {game_uuid, sequence, upload_id, parts: [{number, etag}]} → {object_key} */
export async function PUT(req: Request) {
  const body = await req.json().catch(() => ({}));
  const ctx = await gameContext(req, body.game_uuid, { write: true, owner: true });
  if ("error" in ctx) return ctx.error;
  const sequence = Number(body.sequence);
  const parts = Array.isArray(body.parts) ? body.parts.filter((p: { number?: unknown; etag?: unknown }) => Number.isInteger(p?.number) && typeof p?.etag === "string") : [];
  if (!Number.isInteger(sequence) || sequence <= 0 || typeof body.upload_id !== "string" || parts.length === 0) return Response.json({ error: "Invalid upload." }, { status: 400 });
  const { admin, gameUuid, gameRows } = ctx;
  const key = footageKey(gameUuid, sequence);
  try {
    // Check what R2 actually holds before completing: every part at most PART_SIZE, the total
    // within MAX_SEGMENT_BYTES. An oversized upload is aborted so its parts are freed.
    const held = await uploadedParts(key, body.upload_id);
    if (!held) throw new Error("The upload has expired. Start it again.");
    const sizes = [...held.values()].map(p => p.size);
    if (sizes.some(size => !(size <= PART_SIZE)) || sizes.reduce((a, b) => a + b, 0) > MAX_SEGMENT_BYTES) {
      await call("DELETE", key, { query: { uploadId: body.upload_id } }).catch(() => {});
      throw new Error("The recording is too large.");
    }
    // Complete with the ETags R2 listed above, not the client's: a part re-uploaded after the size
    // check no longer matches its listed ETag, so R2 rejects the completion.
    const xml = `<CompleteMultipartUpload>${[...held].sort(([a], [b]) => a - b)
      .map(([number, { etag }]) => `<Part><PartNumber>${number}</PartNumber><ETag>${etag.replace(/[<>&]/g, "")}</ETag></Part>`).join("")}</CompleteMultipartUpload>`;
    await call("POST", key, { query: { uploadId: body.upload_id }, body: xml, headers: { "content-type": "application/xml" } });
    const head = await call("HEAD", key);
    if (!head.ok || !(Number(head.headers.get("content-length")) <= MAX_SEGMENT_BYTES)) {
      await call("DELETE", key).catch(() => {});
      throw new Error("The recording is too large.");
    }
    const { error } = await admin.from("hoop_segments").update({ object_key: key, upload_status: "uploaded" }).match(gameRows).eq("sequence", sequence);
    if (error) throw new Error(error.message);
    return Response.json({ object_key: key });
  } catch (error) {
    await admin.from("hoop_segments").update({ upload_status: "failed" }).match(gameRows).eq("sequence", sequence);
    return Response.json({ error: error instanceof Error ? error.message : "Could not finish the upload." }, { status: 502 });
  }
}

/** GET ?game_uuid= → [{sequence, upload_status}] so a phone or the Web can show upload progress. */
export async function GET(req: Request) {
  const ctx = await gameContext(req, new URL(req.url).searchParams.get("game_uuid"));
  if ("error" in ctx) return ctx.error;
  const { data, error } = await ctx.admin.from("hoop_segments").select("sequence, upload_status").match(ctx.gameRows).gt("sequence", 0).order("sequence");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json(data);
}
