// Run: node --test lib/replay-video.test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { operationState, promptFromResponse, promptRequest, videoRequest } from "./replay-video.ts";

test("prompt request carries the score, teams and plays", () => {
  const body = promptRequest({ title: "Falcons vs Rockets", away: "Falcons", home: "Rockets", awayScore: 61, homeScore: 58, plays: "Q1\t09:40\tFalcons (Away)\t3PT made\t#7 Ann Lee\t+3\t3 - 0" });
  const text = body.contents[0].parts[0].text;
  assert.match(text, /Falcons \(Away\) 61 - 58 Rockets \(Home\)/);
  assert.match(text, /#7 Ann Lee/);
  assert.match(text, /at most 90 words/);
  assert.match(text, /Never write any person's name/);
  assert.equal(body.generationConfig.thinkingConfig.thinkingBudget, 0);
});

test("prompt text is extracted and unquoted", () => {
  assert.equal(promptFromResponse({ candidates: [{ content: { parts: [{ text: "\"A packed gym...\"\n" }] } }] }), "A packed gym...");
  assert.equal(promptFromResponse({ candidates: [{ content: { parts: [{ text: "thinking...", thought: true }, { text: "Prompt." }] } }] }), "Prompt.");
  assert.equal(promptFromResponse({ candidates: [] }), null);
});

test("video request asks for one 8-second landscape clip", () => {
  assert.deepEqual(videoRequest("p"), { instances: [{ prompt: "p" }], parameters: { aspectRatio: "16:9", resolution: "720p", durationSeconds: 8 } });
});

test("operation state distinguishes running, ready, filtered and failed", () => {
  assert.deepEqual(operationState({ name: "operations/x" }), { done: false });
  assert.deepEqual(operationState({ done: true, response: { generateVideoResponse: { generatedSamples: [{ video: { uri: "https://v/1" } }] } } }), { done: true, uri: "https://v/1" });
  assert.deepEqual(operationState({ done: true, response: { generateVideoResponse: { raiMediaFilteredCount: 1, raiMediaFilteredReasons: ["Blocked for safety."] } } }), { done: true, error: "Blocked for safety." });
  assert.deepEqual(operationState({ done: true, error: { message: "Quota exceeded" } }), { done: true, error: "Quota exceeded" });
});
