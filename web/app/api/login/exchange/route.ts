import { openCode } from "../shared";

export const dynamic = "force-dynamic";

/** POST {code, code_verifier} → the session fields an app's deep link used to carry (see ../shared.ts). */
export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const fields = typeof body.code === "string" && typeof body.code_verifier === "string" ? openCode(body.code, body.code_verifier) : null;
  if (!fields) return Response.json({ error: "Sign in expired. Try again" }, { status: 400 });
  return Response.json(fields, { headers: { "cache-control": "no-store" } });
}
