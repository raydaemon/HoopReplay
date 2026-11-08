// Shared tail of the Google / Apple browser sign-ins: redirect-target validation, the
// state cookie, the final redirect carrying the session, and minting a Supabase session
// for an email the provider has verified. Supabase Auth stays the identity system.
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { sealCode } from "@/lib/login-code";

export { openCode } from "@/lib/login-code";

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

type Admin = Awaited<ReturnType<typeof caller>>["admin"];

/**
 * Atomically adds `amount` to the user's counter of `kind` for today (UTC) when it stays within
 * `cap` (see migration 20261107190000_usage_quotas.sql). False when the daily limit is reached.
 */
export async function reserveUsage(admin: Admin, userId: string, kind: string, amount: number, cap: number) {
  const { data, error } = await admin.rpc("hoop_reserve_usage", { p_user: userId, p_kind: kind, p_amount: Math.ceil(amount), p_cap: cap });
  if (error) throw new Error(error.message);
  return data === true;
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

export type LoginCookie = { state: string; to: string; appState: string; challenge?: string; nonce?: string };

/** The app's PKCE code_challenge (base64url SHA-256 of its verifier), or "" when absent or malformed. */
export function codeChallenge(url: URL) {
  const value = url.searchParams.get("code_challenge") ?? "";
  return /^[A-Za-z0-9_-]{43}$/.test(value) ? value : "";
}


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

/**
 * The fragment a client gets after a successful sign-in; see page.tsx / Sync.kt / SyncService.swift.
 * Tokens never ride in the URL: every client (web included) gets a short-lived code sealed to the
 * PKCE challenge it sent to /start, and redeems it at /api/login/exchange with its own verifier.
 * The callers reject a sign-in that sent no challenge before a session is minted.
 */
export function sessionFragment(
  app: boolean,
  session: { access_token: string; refresh_token: string; expires_at?: number },
  user: { id: string; email?: string; user_metadata?: Record<string, unknown> },
  fallback: { email: string; name: string },
  appState: string,
  challenge: string,
): Record<string, string> {
  if (!challenge) throw new Error("Sign in needs a code_challenge");
  // The web key deliberately avoids `code` / `access_token` / `error`, which supabase-js would try
  // to parse out of the URL itself.
  if (!app) return { login_code: sealCode({ access_token: session.access_token, refresh_token: session.refresh_token }, challenge) };
  const meta = user.user_metadata ?? {};
  const fields = {
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    expires_at: String(session.expires_at ?? ""),
    user_id: user.id,
    email: user.email ?? fallback.email,
    name: typeof meta.full_name === "string" ? meta.full_name : fallback.name,
  };
  return { code: sealCode(fields, challenge), state: appState };
}

/** Message for a sign-in started without PKCE (an outdated app build). */
export const NO_CHALLENGE = "Update HoopReplay to sign in";

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
  // The provider verified this email, so the account is marked `email_proven` (what sharing by
  // email trusts, see private.request_email) and `oauth_claimed` (its owner has taken it over, below).
  // Both live in app_metadata, which only the service role can write.
  const proven = { email_proven: true, oauth_claimed: true };
  const created = await admin.auth.admin.createUser({
    email, email_confirm: true, user_metadata: name ? { full_name: name } : {}, app_metadata: proven,
  });
  if (created.error && created.error.code !== "email_exists") throw new Error(created.error.message);
  const link = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link.data.properties?.hashed_token;
  if (link.error || !tokenHash) throw new Error(link.error?.message ?? "Could not start session");
  // An account that already holds this address may have been registered by someone who only
  // claimed it: password signups can be auto-confirmed, so neither email_confirmed_at nor the
  // grandfathered email_proven flag proves who set the password. The first time a provider brings
  // the address's owner to the account, any earlier password stops working and every other
  // session is revoked. (A legitimate password user resets it once through "Forgot password".)
  const existing = link.data.user;
  // Both flags are dropped on any email change (private.mark_email_proven), so an account whose
  // address was switched to this one is taken over too, never just re-marked as proven.
  const takeOver = !created.data.user && existing
    && !(existing.app_metadata?.oauth_claimed === true && existing.app_metadata?.email_proven === true);
  if (takeOver) {
    const reset = await admin.auth.admin.updateUserById(existing.id, {
      password: randomUUID() + randomUUID(), email_confirm: true, app_metadata: { ...existing.app_metadata, ...proven },
    });
    if (reset.error) throw new Error(reset.error.message);
  }
  const { data, error } = await createClient(url, env("NEXT_PUBLIC_SUPABASE_ANON_KEY"), options)
    .auth.verifyOtp({ type: "magiclink", token_hash: tokenHash });
  if (error || !data.session || !data.user) throw new Error(error?.message ?? "Could not start session");
  if (takeOver) {
    const revoked = await admin.auth.admin.signOut(data.session.access_token, "others");
    if (revoked.error) throw new Error(revoked.error.message);
  }
  return { session: data.session, user: data.user };
}
