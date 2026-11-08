// Run: node --test lib/i18n.test.ts
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { LANGUAGES, format, matchLanguage } from "./i18n-core.ts";

test("browser tags map onto the shipped languages", () => {
  assert.equal(matchLanguage("en-US"), "en");
  assert.equal(matchLanguage("zh-CN"), "zh-Hans");
  assert.equal(matchLanguage("zh-Hans-CN"), "zh-Hans");
  assert.equal(matchLanguage("zh-TW"), "zh-Hant");
  assert.equal(matchLanguage("zh-Hant"), "zh-Hant");
  assert.equal(matchLanguage("pt-BR"), "pt");
  assert.equal(matchLanguage("ar"), null);
  assert.equal(matchLanguage(undefined), null);
});

test("placeholders are filled and unknown ones stay visible", () => {
  assert.equal(format("{count} plays", { count: 3 }), "3 plays");
  assert.equal(format("{a} vs {b}", { a: "Egan", b: "Miller" }), "Egan vs Miller");
  assert.equal(format("{missing}"), "{missing}");
});

test("every language file has exactly the English keys and no empty values", () => {
  const dir = new URL("../i18n/", import.meta.url);
  const en = JSON.parse(readFileSync(new URL("en.json", dir), "utf8")) as Record<string, string>;
  const files = readdirSync(dir).filter((name) => name.endsWith(".json")).sort();
  assert.deepEqual(files, LANGUAGES.map((language) => `${language.code}.json`).sort());
  for (const [key, value] of Object.entries(en)) assert.equal(key, value, `en.json value differs from key: ${key}`);
  for (const file of files) {
    const dict = JSON.parse(readFileSync(new URL(file, dir), "utf8")) as Record<string, string>;
    assert.deepEqual(Object.keys(dict).sort(), Object.keys(en).sort(), `${file} keys differ from en.json`);
    for (const [key, value] of Object.entries(dict)) {
      assert.ok(value.trim(), `${file}: empty translation for "${key}"`);
      const placeholders = (text: string) => (text.match(/\{\w+\}/g) ?? []).sort();
      assert.deepEqual(placeholders(value), placeholders(key), `${file}: placeholders differ for "${key}"`);
    }
  }
});
