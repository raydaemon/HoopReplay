export const dynamic = "force-dynamic";

/**
 * GET /api/config — the public client configuration. The apps fetch this before signing in
 * (and cache it) so the backend can move without a store release; the values are the same
 * NEXT_PUBLIC_* ones the web app ships to every browser.
 */
export function GET(req: Request) {
  const origin = new URL(req.url).origin;
  return Response.json({
    supabase_url: process.env.NEXT_PUBLIC_SUPABASE_URL ?? "",
    supabase_anon_key: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "",
    sync_space: process.env.NEXT_PUBLIC_HOOPREPLAY_SYNC_SPACE ?? "",
    google_login_url: `${origin}/api/login/google/start`,
    apple_login_url: `${origin}/api/login/apple/start`,
  }, { headers: { "Cache-Control": "no-store" } });
}
