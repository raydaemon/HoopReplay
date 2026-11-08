// Google sign-in without the Supabase Google provider. The browser is sent to Google by us,
// Google returns an authorization code to our own callback, the code is exchanged for an ID
// token server-side, and a Supabase session is minted for that email (see ../shared.ts).
import { NextResponse } from "next/server";

import { APP_REDIRECT, codeChallenge, env, finishRedirect, mintSession, NO_CHALLENGE, readCookie, redirectTarget, sessionFragment } from "../shared";

const COOKIE = { name: "google_login", path: "/api/login/google" };

/** GET /api/login/google/start?redirect_to=…&state=… — send the browser to Google's consent screen. */
export function startGoogleLogin(req: Request) {
  const url = new URL(req.url);
  const to = redirectTarget(url.searchParams.get("redirect_to"), url.origin);
  // The apps send a state of their own so they can tell our callback from a deep link any other
  // app on the device could fire; it is handed back to them untouched in the fragment.
  const appState = url.searchParams.get("state") ?? "";
  const state = crypto.randomUUID();
  const authorize = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  authorize.search = new URLSearchParams({
    client_id: env("GOOGLE_CLIENT_ID"),
    redirect_uri: `${url.origin}/api/login/google/callback`,
    response_type: "code",
    scope: "openid email profile",
    prompt: "select_account",
    state,
  }).toString();
  const res = NextResponse.redirect(authorize, { status: 302 });
  res.cookies.set(COOKIE.name, JSON.stringify({ state, to, appState, challenge: codeChallenge(url) }), {
    httpOnly: true, secure: true, sameSite: "lax", path: COOKIE.path, maxAge: 600,
  });
  return res;
}

/** GET /api/login/google/callback?code=&state= — Google's return; ends at the redirect target. */
export async function finishGoogleLogin(req: Request) {
  const url = new URL(req.url);
  const saved = readCookie(req, COOKIE.name);
  const to = redirectTarget(saved?.to ?? null, url.origin);
  const fail = (message: string) => {
    console.error(`[AUTH][GOOGLE][callback] ${message}`);
    return finishRedirect(COOKIE, to, url.origin, { login_error: message });
  };
  const error = url.searchParams.get("error");
  if (error) return fail(error);
  if (!saved || url.searchParams.get("state") !== saved.state) return fail("State mismatch");
  if (!saved.challenge) return fail(NO_CHALLENGE);
  const code = url.searchParams.get("code");
  if (!code) return fail("No code");
  try {
    const identity = await exchangeCode(code, `${url.origin}/api/login/google/callback`);
    const { session, user } = await mintSession(identity);
    return finishRedirect(COOKIE, to, url.origin,
      sessionFragment(to === APP_REDIRECT, session, user, identity, saved.appState, saved.challenge));
  } catch (err) {
    return fail(err instanceof Error ? err.message : "Google login failed");
  }
}

/** Trades the authorization code for Google's ID token and reads the identity out of it. */
async function exchangeCode(code: string, redirectUri: string) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: env("GOOGLE_CLIENT_ID"),
      client_secret: env("GOOGLE_CLIENT_SECRET"),
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });
  const body = await res.json();
  if (!res.ok || typeof body.id_token !== "string") {
    throw new Error(body.error_description ?? body.error ?? "Google token exchange failed");
  }
  // The ID token arrived straight from Google over TLS, so its payload needs no signature check.
  const claims = JSON.parse(Buffer.from(body.id_token.split(".")[1], "base64url").toString());
  if (claims.aud !== env("GOOGLE_CLIENT_ID")) throw new Error("Google token is for another client");
  if (typeof claims.email !== "string" || claims.email_verified !== true) {
    throw new Error("Google account has no verified email");
  }
  return { email: claims.email.toLowerCase(), name: typeof claims.name === "string" ? claims.name : "" };
}
