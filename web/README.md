# HoopReplay Web

Next.js dashboard deployed on Vercel with Supabase synchronization.

## Setup

1. Create a Supabase project and apply the migrations in `supabase/migrations/`.
2. Enable the Email provider in Supabase Auth, then copy `.env.example` to `.env.local` and fill in the project URL, publishable key, and a private random sync space of at least 24 characters.
3. Use the same values for Android Gradle properties: `HOOPREPLAY_SUPABASE_URL`, `HOOPREPLAY_SUPABASE_ANON_KEY`, and `HOOPREPLAY_SYNC_SPACE`.
4. Run `npm install && npm run dev`.
5. Import `web/` into Vercel and add the three environment variables.

## Free-plan keep-alive

`vercel.json` schedules two daily requests to `/api/cron/keep-alive`. The
protected route performs a lightweight `SELECT` against Supabase so an idle
Free Plan project continues to receive database activity.

Add these server-only environment variables to the Production environment in
Vercel, then create a new production deployment:

```text
CRON_SECRET=<random string with at least 16 characters>
SUPABASE_SECRET_KEY=<Supabase sb_secret_... key>
```

Vercel automatically sends `CRON_SECRET` in the cron request's Authorization
header. Never prefix `SUPABASE_SECRET_KEY` with `NEXT_PUBLIC_` or expose it to
browser code. The route reuses the existing `NEXT_PUBLIC_SUPABASE_URL` value.

## Authentication

The dashboard supports email/password registration, Google sign-in, persistent sessions, and logout through Supabase Auth. Google sign-in does not use the Supabase Google provider: `/api/login/google/start` sends the browser to Google, `/api/login/google/callback` exchanges the code with `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`, finds or creates the Supabase user, and returns the session in the URL fragment (the Android and iOS apps use the same routes with `redirect_to=hoopreplay://auth-callback`). In Google Cloud Console, add `https://www.hoopreplay.com/api/login/google/callback`, `https://hoopreplay.com/api/login/google/callback`, and `http://localhost:3080/api/login/google/callback` as authorized redirect URIs. Enable email signups in Supabase Auth settings, set the Supabase Site URL to `https://www.hoopreplay.com`, and add these Supabase Auth allowed redirect URLs: `https://www.hoopreplay.com/**`, `https://hoopreplay.com/**`, `http://localhost:3080/**`, and `http://localhost:3000/**`. The client redirects to the current origin, so local runs return to the port selected by `scripts/web-run.sh` while production returns to the deployed site. Each authenticated user can only access their own sync document through row-level security.

Creating teams, players, and games remains local and does not require login. Tapping Sync asks the user to authenticate, then merges their cloud snapshot into local storage and publishes the result. Video files remain local.
