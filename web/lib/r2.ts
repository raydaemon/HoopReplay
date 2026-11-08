// Cloudflare R2 access for highlight videos and uploaded game footage. Only the server holds the
// credentials; phones and browsers get short-lived presigned URLs from the API routes.
import { AwsClient } from "aws4fetch";

const PRESIGN_SECONDS = 60 * 60;

function env(name: string) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

let client: AwsClient | null = null;
function r2() {
  client ??= new AwsClient({ accessKeyId: env("R2_ACCESS_KEY_ID"), secretAccessKey: env("R2_SECRET_ACCESS_KEY"), service: "s3", region: "auto" });
  return client;
}

/** The object's URL; `query` adds S3 sub-resources such as `uploadId` or `partNumber`. */
export function objectUrl(key: string, query: Record<string, string> = {}) {
  const url = new URL(`https://${env("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com/${env("R2_BUCKET")}/${key.split("/").map(encodeURIComponent).join("/")}`);
  for (const [name, value] of Object.entries(query)) url.searchParams.set(name, value);
  return url;
}

/** A URL anyone may use for the next hour to GET or PUT exactly this object (or upload part). */
export async function presign(method: "GET" | "PUT", key: string, query: Record<string, string> = {}) {
  const url = objectUrl(key, query);
  url.searchParams.set("X-Amz-Expires", String(PRESIGN_SECONDS));
  const signed = await r2().sign(new Request(url, { method }), { aws: { signQuery: true } });
  return signed.url;
}

/** A signed request from the server itself; throws with R2's message when it fails. */
export async function call(method: string, key: string, { query, body, headers }: { query?: Record<string, string>; body?: BodyInit; headers?: Record<string, string> } = {}) {
  // R2 rejects a PUT without Content-Length, and fetch does not add one for Buffer bodies when signing.
  const length = typeof body === "string" ? Buffer.byteLength(body) : body && "byteLength" in body ? body.byteLength : undefined;
  const res = await r2().fetch(objectUrl(key, query).toString(), { method, body, headers: length === undefined ? headers : { ...headers, "content-length": String(length) } });
  if (!res.ok && !(method === "HEAD" && res.status === 404)) throw new Error(`R2 ${method} ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return res;
}

export async function exists(key: string) {
  return (await call("HEAD", key)).ok;
}

/** The text of one XML element, e.g. `<UploadId>` in a CreateMultipartUpload answer. */
export function xmlValue(xml: string, tag: string) {
  return xml.match(new RegExp(`<${tag}>([^<]*)</${tag}>`))?.[1] ?? null;
}
