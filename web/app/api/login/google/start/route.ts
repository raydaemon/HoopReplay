import { startGoogleLogin } from "../google-login";

export const dynamic = "force-dynamic";

/** GET /api/login/google/start?redirect_to=… — send the browser to Google. */
export const GET = startGoogleLogin;
