import { finishAppleLogin } from "../apple-login";

export const dynamic = "force-dynamic";

/** POST /api/login/apple/callback — Apple's form_post return with the ID token. */
export const POST = finishAppleLogin;
