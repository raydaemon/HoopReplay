-- A push must not overwrite work another client did after this device's last pull.
--
-- Without a shared counter the only way to notice a concurrent change is to diff whole
-- snapshots, which is exactly the guesswork the tombstones replaced. Every write to a
-- synced table bumps one revision per (user_id, sync_space); a client stores the revision
-- it last saw and refuses to push once the server has moved past it, so the user pulls
-- and merges first.

create table if not exists public.sync_revisions (
  user_id uuid not null references auth.users(id) on delete cascade,
  sync_space text not null check (char_length(sync_space) >= 24),
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  primary key (user_id, sync_space)
);

alter table public.sync_revisions enable row level security;

revoke all on public.sync_revisions from anon;
grant select on public.sync_revisions to authenticated;

create policy "users read own sync revision"
on public.sync_revisions for select to authenticated
using (
  (select auth.uid()) = user_id
  and sync_space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space'
);

-- Only the trigger writes the counter, so it runs as the table owner rather than the caller.
create or replace function public.bump_sync_revision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  owner uuid;
  space text;
begin
  if tg_op = 'DELETE' then
    owner := old.user_id; space := old.sync_space;
  else
    owner := new.user_id; space := new.sync_space;
  end if;
  insert into public.sync_revisions as target (user_id, sync_space, revision, updated_at)
  values (owner, space, 1, now())
  on conflict (user_id, sync_space)
  do update set revision = target.revision + 1, updated_at = now();
  return null;
end;
$$;

do $$
declare
  synced text;
begin
  foreach synced in array array['teams','players','games','events','segments','deletions'] loop
    execute format('drop trigger if exists bump_sync_revision on public.%I', synced);
    execute format(
      'create trigger bump_sync_revision after insert or update or delete on public.%I
         for each row execute function public.bump_sync_revision()',
      synced);
  end loop;
end;
$$;

-- Existing accounts start at a revision so the first client comparison has something to read.
insert into public.sync_revisions (user_id, sync_space, revision)
select distinct user_id, sync_space, 1 from public.teams
on conflict do nothing;
