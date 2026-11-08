// Sign in with Apple for browsers (web app and the Android browser flow) without the Supabase
// Apple provider: we send the user to Apple ourselves and take the ID token back on our own
// callback, so no client secret (the .p8-signed JWT Apple expires every 6 months) is involved.
// iOS keeps its native flow. The session is minted exactly like Google's (see ../shared.ts).
import { createPublicKey, verify } from "node:crypto";
import { NextResponse } from "next/server";

import { APP_REDIRECT, finishRedirect, mintSession, readCookie, redirectTarget, sessionFragment } from "../shared";

const COOKIE = { name: "apple_login", path: "/api/login/apple" };
/** Services ID of the web / Android flow (Apple Developer → Identifiers → Services IDs). */
const APPLE_SERVICES_ID = "com.hoopreplay.web";
/** Audiences we accept: the Services ID and the iOS bundle id. */
const APPLE_CLIENT_IDS = [APPLE_SERVICES_ID, "com.hoopreplay.ios"];

/** GET /api/login/apple/start?redirect_to=…&state=… — send the browser to Apple. */
export function startAppleLogin(req: Request) {
  const url = new URL(req.url);
  const to = redirectTarget(url.searchParams.get("redirect_to"), url.origin);
  const appState = url.searchParams.get("state") ?? "";
  const state = crypto.randomUUID();
  const authorize = new URL("https://appleid.apple.com/auth/authorize");
  authorize.search = new URLSearchParams({
    client_id: APPLE_SERVICES_ID,
    redirect_uri: `${url.origin}/api/login/apple/callback`,
    response_type: "code id_token",
    response_mode: "form_post",
    scope: "name email",
    state,
  }).toString();
  const res = NextResponse.redirect(authorize, { status: 302 });
  // Apple POSTs the callback cross-site, so the cookie must be SameSite=None.
  res.cookies.set(COOKIE.name, JSON.stringify({ state, to, appState }), {
    httpOnly: true, secure: true, sameSite: "none", path: COOKIE.path, maxAge: 600,
  });
  return res;
}

/** POST /api/login/apple/callback — Apple's form_post with state, id_token and (first time) user. */
export async function finishAppleLogin(req: Request) {
  const url = new URL(req.url);
  const form = await req.formData();
  const saved = readCookie(req, COOKIE.name);
  const to = redirectTarget(saved?.to ?? null, url.origin);
  const fail = (message: string) => {
    console.error(`[AUTH][APPLE][callback] ${message}`);
    return finishRedirect(COOKIE, to, url.origin, { login_error: message });
  };
  const error = form.get("error");
  if (error) return fail(error === "user_cancelled_authorize" ? "Sign in was cancelled" : String(error));
  if (!saved || form.get("state") !== saved.state) return fail("State mismatch");
  const idToken = form.get("id_token");
  if (typeof idToken !== "string" || !idToken) return fail("No id_token");
  try {
    const identity = { email: await verifiedAppleEmail(idToken), name: nameFromForm(form.get("user")) };
    const { session, user } = await mintSession(identity);
    return finishRedirect(COOKIE, to, url.origin,
      sessionFragment(to === APP_REDIRECT, session, user, identity, saved.appState));
  } catch (err) {
    return fail(err instanceof Error ? err.message : "Apple login failed");
  }
}

/**
 * Verifies the ID token against Apple's published keys and returns its email. Unlike Google's,
 * this token comes through the browser, so its signature must be checked.
 */
async function verifiedAppleEmail(idToken: string) {
  const [header, payload, signature] = idToken.split(".");
  const { kid } = JSON.parse(Buffer.from(header, "base64url").toString());
  const { keys } = await (await fetch("https://appleid.apple.com/auth/keys", { cache: "no-store" })).json();
  const jwk = (keys as { kid: string }[]).find((key) => key.kid === kid);
  if (!jwk) throw new Error("Unknown Apple signing key");
  const valid = verify("RSA-SHA256", Buffer.from(`${header}.${payload}`),
    createPublicKey({ key: jwk, format: "jwk" }), Buffer.from(signature, "base64url"));
  if (!valid) throw new Error("Invalid Apple token signature");
  const claims = JSON.parse(Buffer.from(payload, "base64url").toString());
  if (claims.iss !== "https://appleid.apple.com" || !APPLE_CLIENT_IDS.includes(claims.aud)) {
    throw new Error("Apple token is for another client");
  }
  if (typeof claims.exp !== "number" || claims.exp * 1000 < Date.now()) throw new Error("Apple token expired");
  // Apple sends email_verified as a boolean or the string "true".
  if (typeof claims.email !== "string" || String(claims.email_verified) !== "true") {
    throw new Error("Apple account has no verified email");
  }
  return claims.email.toLowerCase() as string;
}

/** Apple sends `user` (JSON with the name) on the first authorization only. */
function nameFromForm(user: FormDataEntryValue | null) {
  if (typeof user !== "string") return "";
  try {
    const name = JSON.parse(user)?.name;
    return [name?.firstName, name?.lastName].filter(Boolean).join(" ");
  } catch {
    return "";
  }
}
