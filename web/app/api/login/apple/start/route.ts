import { startAppleLogin } from "../apple-login";

export const dynamic = "force-dynamic";

/** GET /api/login/apple/start?redirect_to=… — send the browser to Apple. */
export const GET = startAppleLogin;
