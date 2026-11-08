// Stripe Checkout for a game's statistics PDF, $0.99 once per game.
// POST starts a Checkout Session for the signed-in user; GET verifies the session Stripe sent the
// browser back with and records the purchase in pdf_purchases (service role: clients can only read).
import { caller, env } from "../login/shared";
import { type CheckoutSession, checkoutSessionParams, purchaseFromSession } from "@/lib/pdf-checkout";

export const dynamic = "force-dynamic";

async function stripe(path: string, body?: URLSearchParams) {
  const res = await fetch(`https://api.stripe.com/v1${path}`, {
    method: body ? "POST" : "GET",
    headers: { Authorization: `Bearer ${env("STRIPE_SECRET_KEY")}` },
    body,
  });
  const json = await res.json();
  if (!res.ok) throw new Error(json?.error?.message ?? `Stripe ${res.status}`);
  return json;
}

export async function POST(req: Request) {
  const { user } = await caller(req);
  if (!user) return Response.json({ error: "Sign in first." }, { status: 401 });
  const body = await req.json().catch(() => ({}));
  const gameUuid = typeof body.game_uuid === "string" ? body.game_uuid : "";
  if (!/^[\w-]{1,64}$/.test(gameUuid)) return Response.json({ error: "Invalid game." }, { status: 400 });
  const title = typeof body.title === "string" && body.title.trim() ? body.title.trim().slice(0, 120) : "Game";
  try {
    const session = await stripe("/checkout/sessions", checkoutSessionParams({
      origin: new URL(req.url).origin, gameUuid, userId: user.id, email: user.email, title,
    }));
    return Response.json({ url: session.url });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Checkout failed." }, { status: 502 });
  }
}

export async function GET(req: Request) {
  const { user, admin } = await caller(req);
  if (!user) return Response.json({ error: "Sign in first." }, { status: 401 });
  const id = new URL(req.url).searchParams.get("session") ?? "";
  if (!/^cs_[\w]+$/.test(id)) return Response.json({ error: "Invalid session." }, { status: 400 });
  try {
    const session: CheckoutSession = await stripe(`/checkout/sessions/${id}`);
    const purchase = purchaseFromSession(session, user.id);
    if (!purchase) return Response.json({ paid: false });
    const { error } = await admin.from("hoop_pdf_purchases").upsert(purchase, { onConflict: "user_id,game_uuid" });
    if (error) throw new Error(error.message);
    return Response.json({ paid: true, game_uuid: purchase.game_uuid });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Verification failed." }, { status: 502 });
  }
}
