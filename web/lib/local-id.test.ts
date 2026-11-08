// Run: node --test lib/local-id.test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { compareIds, newId } from "./local-id.ts";

test("newId makes unique, time-ordered lowercase UUIDv7s", () => {
  const ids = Array.from({ length: 5000 }, () => newId());
  for (const id of ids) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(new Set(ids).size, ids.length);
  assert.deepEqual([...ids].sort(compareIds), ids);
  assert.equal(parseInt(ids[0].replace(/-/g, "").slice(0, 12), 16) <= Date.now() + 10, true);
});
