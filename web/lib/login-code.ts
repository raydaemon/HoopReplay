// One-time sign-in codes for the apps' deep link (see app/api/login/shared.ts).
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

function secret() {
  const value = process.env.SUPABASE_SECRET_KEY;
  if (!value) throw new Error("SUPABASE_SECRET_KEY is not set");
  return value;
}

const CODE_TTL_MS = 5 * 60 * 1000;
const codeKey = () => createHash("sha256").update(`hoop-login-code:${secret()}`).digest();
const challengeOf = (verifier: string) => createHash("sha256").update(verifier).digest("base64url");

/**
 * Seals the app's session into a short-lived code. Any app on the device can register the
 * `hoopreplay://` scheme and read the deep link, so the link carries only this code; tokens come
 * out of /api/login/exchange for the caller holding the PKCE verifier behind `challenge`.
 */
export function sealCode(fields: Record<string, string>, challenge: string) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", codeKey(), iv);
  const body = Buffer.concat([cipher.update(JSON.stringify({ fields, challenge, expires: Date.now() + CODE_TTL_MS })), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), body]).toString("base64url");
}

/** The session fields sealed in `code`, or null when the code is forged, expired or the verifier does not match. */
export function openCode(code: string, verifier: string): Record<string, string> | null {
  try {
    const raw = Buffer.from(code, "base64url");
    const decipher = createDecipheriv("aes-256-gcm", codeKey(), raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    const { fields, challenge, expires } = JSON.parse(Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString());
    // ponytail: a code is not single-use; it is worthless without the verifier and dies in 5 minutes.
    return Date.now() < expires && challengeOf(verifier) === challenge ? fields : null;
  } catch {
    return null;
  }
}
