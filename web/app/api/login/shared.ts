// Shared tail of the Google / Apple browser sign-ins: redirect-target validation, the
// state cookie, the final redirect carrying the session, and minting a Supabase session
// for an email the provider has verified. Supabase Auth stays the identity system.
import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";

/** The Android and iOS apps' deep link; the session travels to the app in its fragment. */
export const APP_REDIRECT = "hoopreplay://auth-callback";

export function env(name: string) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

/**
 * The Supabase user behind an API request's bearer token, a service-role client (admin) and a
 * client acting as that user (asUser) for queries that must respect row-level security.
 */
export async function caller(req: Request) {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const url = env("NEXT_PUBLIC_SUPABASE_URL");
  const options = { auth: { persistSession: false, autoRefreshToken: false } };
  const admin = createClient(url, env("SUPABASE_SECRET_KEY"), options);
  const asUser = createClient(url, env("NEXT_PUBLIC_SUPABASE_ANON_KEY"), { ...options, global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data: { user } } = token ? await admin.auth.getUser(token) : { data: { user: null } };
  return { user, admin, asUser };
}

/**
 * Only same-site paths or the app deep link may be redirect targets. The candidate is resolved
 * against our origin and must stay there: a bare prefix check lets `/\\evil.com` through,
 * which the URL parser turns into another host.
 */
export function redirectTarget(value: string | null, origin: string) {
  if (value === APP_REDIRECT) return value;
  if (!value || !value.startsWith("/") || /[\\\s\x00-\x1f]/.test(value)) return "/";
  const resolved = new URL(value, origin);
  return resolved.origin === origin ? resolved.pathname + resolved.search : "/";
}

export type LoginCookie = { state: string; to: string; appState: string };

export function readCookie(req: Request, name: string): LoginCookie | null {
  const raw = req.headers.get("cookie")?.split(";").map((c) => c.trim())
    .find((c) => c.startsWith(`${name}=`));
  if (!raw) return null;
  try {
    return JSON.parse(decodeURIComponent(raw.slice(name.length + 1)));
  } catch {
    return null;
  }
}

/** Sends the browser on to `to` with `fragment` in the URL hash and drops the state cookie. */
export function finishRedirect(
  cookie: { name: string; path: string },
  to: string,
  origin: string,
  fragment: Record<string, string>,
) {
  const target = `${to === APP_REDIRECT ? to : new URL(to, origin)}#${new URLSearchParams(fragment)}`;
  const res = NextResponse.redirect(target, { status: 303 });
  res.cookies.set(cookie.name, "", { path: cookie.path, maxAge: 0 });
  return res;
}

/** The fragment a client gets after a successful sign-in; see page.tsx / Sync.kt / SyncService.swift. */
export function sessionFragment(
  app: boolean,
  session: { access_token: string; refresh_token: string; expires_at?: number },
  user: { id: string; email?: string; user_metadata?: Record<string, unknown> },
  fallback: { email: string; name: string },
  appState: string,
): Record<string, string> {
  // The web keys deliberately avoid `access_token` / `error`, which supabase-js would try to
  // parse out of the URL itself; the apps get the full session so they skip a round trip.
  if (!app) return { token: session.access_token, refresh: session.refresh_token };
  const meta = user.user_metadata ?? {};
  return {
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    expires_at: String(session.expires_at ?? ""),
    user_id: user.id,
    email: user.email ?? fallback.email,
    name: typeof meta.full_name === "string" ? meta.full_name : fallback.name,
    state: appState,
  };
}

/**
 * Mints a Supabase session without a provider: create the user if needed, then generate a
 * magic link server-side and verify it right away (never emailed). Refresh tokens work as usual.
 */
// ponytail: verifyOtp counts against auth.rate_limit.token_verifications per caller IP
// (30 / 5 min; all logins share the server's IP). Raise it when logins get that frequent.
export async function mintSession({ email, name }: { email: string; name: string }) {
  const url = env("NEXT_PUBLIC_SUPABASE_URL");
  const options = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
  const admin = createClient(url, env("SUPABASE_SECRET_KEY"), options);
  const created = await admin.auth.admin.createUser({
    email, email_confirm: true, user_metadata: name ? { full_name: name } : {},
  });
  if (created.error && created.error.code !== "email_exists") throw new Error(created.error.message);
  const link = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link.data.properties?.hashed_token;
  if (link.error || !tokenHash) throw new Error(link.error?.message ?? "Could not start session");
  const { data, error } = await createClient(url, env("NEXT_PUBLIC_SUPABASE_ANON_KEY"), options)
    .auth.verifyOtp({ type: "magiclink", token_hash: tokenHash });
  if (error || !data.session || !data.user) throw new Error(error?.message ?? "Could not start session");
  return { session: data.session, user: data.user };
}
