#!/usr/bin/env node
// Gives every event in one substitution batch the same created_at.
//
// Before web/lib/scoring.ts stamped a whole commit with a single timestamp, each event in a
// multi-player substitution got its own Date.now(), so events written a millisecond apart no
// longer looked like one batch and the play-by-play could not pair Sub out with Sub in.
// A batch is: same user, sync space, game, team, period and clock, with consecutive (by id, a time-ordered UUIDv7)
// SUB_OUT / SUB_IN events whose created_at differ by at most 5 seconds. Every event in a batch
// is set to the batch's earliest created_at. Pass --apply to write; the default is a dry run.
//
//   node --env-file=.env.local scripts/normalize-substitution-timestamps.mjs [--apply]

import { createClient } from "@supabase/supabase-js";

const apply = process.argv.includes("--apply");
const BATCH_GAP_MS = 5000;

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const secretKey = process.env.SUPABASE_SECRET_KEY;
if (!supabaseUrl || !secretKey) {
  console.error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SECRET_KEY must be set (use --env-file=.env.local)");
  process.exit(1);
}
const supabase = createClient(supabaseUrl, secretKey, { auth: { persistSession: false, autoRefreshToken: false } });

async function loadSubstitutionEvents() {
  const rows = [];
  const pageSize = 1000;
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase
      .from("hoop_events")
      .select("user_id,sync_space,id,game_id,team_id,period,game_clock_ms,type,created_at,reverted")
      .in("type", ["SUB_OUT", "SUB_IN"])
      .order("user_id").order("sync_space").order("id")
      .range(from, from + pageSize - 1);
    if (error) throw error;
    rows.push(...(data ?? []));
    if ((data?.length ?? 0) < pageSize) break;
  }
  return rows;
}

const events = await loadSubstitutionEvents();
const groups = new Map();
for (const event of events) {
  const key = [event.user_id, event.sync_space, event.game_id, event.team_id, event.period, event.game_clock_ms].join("|");
  groups.set(key, [...(groups.get(key) ?? []), event]);
}

const updates = [];
let batches = 0;
for (const group of groups.values()) {
  group.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  let batch = [];
  const flush = () => {
    if (batch.length === 0) return;
    batches += 1;
    const earliest = Math.min(...batch.map((event) => Number(event.created_at)));
    for (const event of batch) {
      if (Number(event.created_at) !== earliest) updates.push({ event, created_at: earliest });
    }
    batch = [];
  };
  for (const event of group) {
    const previous = batch[batch.length - 1];
    if (previous && Math.abs(Number(event.created_at) - Number(previous.created_at)) > BATCH_GAP_MS) flush();
    batch.push(event);
  }
  flush();
}

console.log(`${events.length} substitution events in ${groups.size} team/period/clock groups, ${batches} batches`);
console.log(`${updates.length} event(s) need created_at aligned${apply ? "" : " (dry run, pass --apply to write)"}`);
for (const { event, created_at } of updates) {
  console.log(`  game ${event.game_id} team ${event.team_id} P${event.period} ${event.game_clock_ms}ms ${event.type} id ${event.id}: ${event.created_at} -> ${created_at} (${Number(event.created_at) - created_at} ms)`);
}

if (apply) {
  let written = 0;
  for (const { event, created_at } of updates) {
    const { error } = await supabase.from("hoop_events").update({ created_at })
      .eq("id", event.id);
    if (error) throw error;
    written += 1;
  }
  console.log(`updated ${written} event(s)`);
}
