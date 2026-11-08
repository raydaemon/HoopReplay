// Run: node --test lib/highlight-clips.test.ts
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { highlightClips } from "./highlight-clips.ts";

const fixture = JSON.parse(readFileSync(new URL("./highlight-clips.fixture.json", import.meta.url), "utf8"));

for (const c of fixture.cases) {
  test(c.name, () => {
    assert.deepEqual(highlightClips(fixture.events, fixture.segments, c.target), c.clips);
  });
}
