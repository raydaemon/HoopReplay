// Run: node --test lib/login-code.test.ts
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";

process.env.SUPABASE_SECRET_KEY = "test-secret";
const { openCode, sealCode } = await import("./login-code.ts");

const verifier = "v".repeat(43);
const challenge = createHash("sha256").update(verifier).digest("base64url");

test("a sealed code opens only with the matching verifier and untampered", () => {
  const code = sealCode({ access_token: "a" }, challenge);
  assert.equal(openCode(code, verifier)?.access_token, "a");
  assert.equal(openCode(code, "w".repeat(43)), null);
  assert.equal(openCode(code.slice(0, -2) + "AA", verifier), null);
});
