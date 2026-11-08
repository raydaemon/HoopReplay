-- 1. Account deletion. hoop_games has no FK to auth.users and references hoop_teams with NO ACTION,
-- so the auth.users cascade could never remove an account that owns a game. The tombstone trigger
-- also inserted hoop_deletions rows for the very user being deleted, which fails their FK. The
-- account's synced rows are now removed first, while the user still exists, and tombstones for
-- an owner who is gone are skipped.
create or replace function private.record_tombstone()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from auth.users u where u.id = old.user_id) then
    return null;
  end if;
  insert into public.hoop_deletions (user_id, sync_space, entity, row_id, deleted_at, device_id)
  values (old.user_id, old.sync_space, substr(tg_table_name, 6), old.id,
          (extract(epoch from clock_timestamp()) * 1000)::bigint, 'server')
  on conflict do nothing;
  return null;
end;
$$;
revoke all on function private.record_tombstone() from public, anon, authenticated;

-- The same for the sync revision counter: the auth.users cascade deletes the account's
-- hoop_deletions rows, and bumping the revision of a user who is gone would fail its FK.
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
  if not exists (select 1 from auth.users u where u.id = owner) then
    return null;
  end if;
  insert into public.hoop_sync_revisions as target (user_id, sync_space, revision, updated_at)
  values (owner, space, 1, now())
  on conflict (user_id, sync_space)
  do update set revision = target.revision + 1, updated_at = now();
  return null;
end;
$$;
revoke execute on function public.bump_sync_revision() from public, anon, authenticated;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = pg_catalog, auth, public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  -- Games first (their segments, events and grants cascade, and their ids are retired so the
  -- purge cron removes the footage), then teams (players and memberships cascade).
  delete from public.hoop_games where user_id = me;
  delete from public.hoop_teams where user_id = me;
  delete from auth.users where id = me;
end;
$$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- 2. Recordings belong to the owner: editors may edit play-by-play events but never delete a
-- segment (the delete would cascade its events and tombstone them on every owner device).
drop policy if exists "owners and editors delete rows" on public.hoop_segments;
create policy "owners delete segments" on public.hoop_segments for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 3. A retired game id can't be taken back by renaming a live game to it either: the check now
-- also runs when an UPDATE changes the id.
drop trigger if exists reject_retired_game_id on public.hoop_games;
create trigger reject_retired_game_id before insert or update of id on public.hoop_games
  for each row execute function private.reject_retired_game_id();
