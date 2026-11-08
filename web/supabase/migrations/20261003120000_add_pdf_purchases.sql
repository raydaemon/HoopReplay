-- A statistics PDF costs $0.99 once per game. The web server records the Stripe Checkout
-- Session it verified here, so the buyer never pays twice for the same game and the client can
-- only read, never grant, its own purchases.

create table if not exists public.pdf_purchases (
  user_id uuid not null references auth.users(id) on delete cascade,
  game_uuid text not null,
  stripe_session_id text not null unique,
  paid_at timestamptz not null default now(),
  primary key (user_id, game_uuid)
);

alter table public.pdf_purchases enable row level security;

revoke all on public.pdf_purchases from anon;
grant select on public.pdf_purchases to authenticated;

create policy "users read own pdf purchases"
on public.pdf_purchases for select to authenticated
using ((select auth.uid()) = user_id);
