// Run: node --test lib/pdf-checkout.test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { checkoutSessionParams, purchaseFromSession } from "./pdf-checkout.ts";

test("checkout session charges $0.99 once and returns to the game page", () => {
  const params = checkoutSessionParams({ origin: "https://www.hoopreplay.com", gameUuid: "g1", userId: "u1", email: "a@b.c", title: "Falcons vs Rockets" });
  assert.equal(params.get("line_items[0][price_data][unit_amount]"), "99");
  assert.equal(params.get("mode"), "payment");
  assert.equal(params.get("success_url"), "https://www.hoopreplay.com/games/g1?paid={CHECKOUT_SESSION_ID}");
  assert.equal(params.get("metadata[game_uuid]"), "g1");
  assert.equal(params.get("customer_email"), "a@b.c");
});

test("only a paid session for the same user grants the purchase", () => {
  const paid = { id: "cs_1", payment_status: "paid", metadata: { user_id: "u1", game_uuid: "g1" } };
  assert.deepEqual(purchaseFromSession(paid, "u1"), { user_id: "u1", game_uuid: "g1", stripe_session_id: "cs_1" });
  assert.equal(purchaseFromSession({ ...paid, payment_status: "unpaid" }, "u1"), null);
  assert.equal(purchaseFromSession(paid, "u2"), null);
  assert.equal(purchaseFromSession({ id: "cs_2", payment_status: "paid" }, "u1"), null);
});
