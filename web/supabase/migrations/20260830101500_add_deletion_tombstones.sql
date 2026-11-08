-- Deletions must be recorded explicitly instead of being inferred from a row's absence.
--
-- The previous sync replaced the whole account on every save: it deleted every row that
-- was missing from the pushed snapshot. A device that saved a stale snapshot therefore
-- silently destroyed rows another device had just created. A tombstone records what was
-- deleted, when, and by which device, so every other device can replay that exact
-- deletion instead of guessing from a diff.

create table if not exists public.deletions (
  user_id uuid not null references auth.users(id) on delete cascade,
  sync_space text not null check (char_length(sync_space) >= 24),
  entity text not null check (entity in ('teams','players','games','events','segments')),
  local_id bigint not null,
  deleted_at bigint not null,
  device_id text not null check (btrim(device_id) <> ''),
  primary key (user_id, sync_space, entity, local_id)
);

create index if not exists deletions_recent_idx
  on public.deletions (user_id, sync_space, deleted_at);

alter table public.deletions enable row level security;

revoke all on public.deletions from anon;
grant select, insert, update, delete on public.deletions to authenticated;

create policy "users read own deletions"
on public.deletions for select to authenticated
using (
  (select auth.uid()) = user_id
  and sync_space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space'
);

create policy "users insert own deletions"
on public.deletions for insert to authenticated
with check (
  (select auth.uid()) = user_id
  and sync_space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space'
);

create policy "users update own deletions"
on public.deletions for update to authenticated
using (
  (select auth.uid()) = user_id
  and sync_space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space'
)
with check (
  (select auth.uid()) = user_id
  and sync_space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space'
);

-- Recreating a local id must be able to clear its tombstone, so deletes stay permitted.
create policy "users delete own deletions"
on public.deletions for delete to authenticated
using (
  (select auth.uid()) = user_id
  and sync_space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space'
);
