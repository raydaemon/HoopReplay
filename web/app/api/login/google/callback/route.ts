import { finishGoogleLogin } from "../google-login";

export const dynamic = "force-dynamic";

/** GET /api/login/google/callback — Google's return with the authorization code. */
export const GET = finishGoogleLogin;
