/** Price of one game's statistics PDF, in US cents. Charged once per game. */
export const PDF_PRICE_CENTS = 99;
export const PDF_PRICE_LABEL = "$0.99";

/** Form body for POST /v1/checkout/sessions (Stripe takes application/x-www-form-urlencoded). */
export function checkoutSessionParams(
  { origin, gameUuid, userId, email, title }: {
    origin: string; gameUuid: string; userId: string; email?: string; title: string;
  },
) {
  const params = new URLSearchParams({
    mode: "payment",
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "usd",
    "line_items[0][price_data][unit_amount]": String(PDF_PRICE_CENTS),
    "line_items[0][price_data][product_data][name]": `HoopReplay statistics PDF: ${title}`,
    // Stripe fills in {CHECKOUT_SESSION_ID}; the page verifies that id server-side before printing.
    success_url: `${origin}/games/${gameUuid}?paid={CHECKOUT_SESSION_ID}`,
    cancel_url: `${origin}/games/${gameUuid}`,
    client_reference_id: userId,
    "metadata[user_id]": userId,
    "metadata[game_uuid]": gameUuid,
  });
  if (email) params.set("customer_email", email);
  return params;
}

export type CheckoutSession = {
  id: string;
  payment_status?: string;
  metadata?: Record<string, string>;
};

/** The purchase row a verified session grants, or null when it is unpaid or belongs to someone else. */
export function purchaseFromSession(session: CheckoutSession, userId: string) {
  const gameUuid = session.metadata?.game_uuid;
  if (session.payment_status !== "paid" || session.metadata?.user_id !== userId || !gameUuid) return null;
  return { user_id: userId, game_uuid: gameUuid, stripe_session_id: session.id };
}
