-- Server-side spending limits for the paid / costly API routes (Veo renders, cloud highlight cuts,
-- R2 uploads). Only the service role (the web API routes) calls these functions; clients cannot
-- read or change the counters.

-- 1. Per-user daily usage counters, reserved atomically before the work starts.
create table if not exists public.hoop_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null,
  day date not null default (now() at time zone 'utc')::date,
  amount bigint not null default 0,
  primary key (user_id, kind, day)
);
alter table public.hoop_usage enable row level security;
revoke all on public.hoop_usage from anon, authenticated;

-- Adds `amount` to today's counter when the total stays within `cap`; false (nothing added) otherwise.
-- The conditional upsert runs under the row lock, so concurrent callers can never pass the cap together.
create or replace function public.hoop_reserve_usage(p_user uuid, p_kind text, p_amount bigint, p_cap bigint)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  reserved bigint;
begin
  if p_amount <= 0 or p_amount > p_cap then
    return p_amount <= 0;
  end if;
  insert into public.hoop_usage as u (user_id, kind, day, amount)
  values (p_user, p_kind, (now() at time zone 'utc')::date, p_amount)
  on conflict (user_id, kind, day) do update set amount = u.amount + excluded.amount
    where u.amount + excluded.amount <= p_cap
  returning u.amount into reserved;
  return reserved is not null;
end;
$$;

-- 2. One replay-video attempt per game, claimed atomically: a new row, or a failed row still under
-- the attempt limit, becomes 'generating' with no operation yet. Returns the attempt number, or
-- null when the game already has a video in progress / ready or has used all its attempts.
create or replace function public.hoop_reserve_replay_attempt(p_game uuid, p_user uuid, p_max integer)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  attempt integer;
begin
  insert into public.hoop_replay_videos as v (game_uuid, user_id, status, attempts, created_at, updated_at)
  values (p_game, p_user, 'generating', 1, now(), now())
  on conflict (game_uuid) do update set
    user_id = excluded.user_id, status = 'generating', operation_name = null, prompt = null, video_url = null,
    error = null, attempts = v.attempts + 1, created_at = now(), updated_at = now()
    where v.status = 'failed' and v.attempts < p_max
  returning v.attempts into attempt;
  return attempt;
end;
$$;

revoke all on function public.hoop_reserve_usage(uuid, text, bigint, bigint) from public, anon, authenticated;
revoke all on function public.hoop_reserve_replay_attempt(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function public.hoop_reserve_usage(uuid, text, bigint, bigint) to service_role;
grant execute on function public.hoop_reserve_replay_attempt(uuid, uuid, integer) to service_role;
