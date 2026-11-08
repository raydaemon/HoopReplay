import { createClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

export const syncSpace = process.env.NEXT_PUBLIC_HOOPREPLAY_SYNC_SPACE ?? "";
export const isConfigured = Boolean(url && key && syncSpace);

const freshReadFetch: typeof fetch = (input, init) => {
  const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
  if (method !== "GET" && method !== "HEAD") return fetch(input, init);
  const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
  headers.set("Cache-Control", "no-cache, no-store, max-age=0");
  headers.set("Pragma", "no-cache");
  return fetch(input, { ...init, cache: "no-store", headers });
};

export const supabase = isConfigured ? createClient(url, key, {
  // PKCE only: supabase-js then installs a session from the URL only for a `?code=` this browser
  // started (its verifier is in storage), never tokens from a fragment someone else crafted.
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: "pkce" },
  global: { fetch: freshReadFetch, headers: { "x-sync-space": syncSpace } }
}) : null;
