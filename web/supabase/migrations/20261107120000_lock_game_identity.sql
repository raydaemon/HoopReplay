-- games.uuid_id names a game in every API route, R2 key and video row, so it must be unique
-- across all owners, not just within one owner's sync space: otherwise a user could create a
-- game reusing someone else's uuid and reach that game's replay video and highlights.
create unique index if not exists hoop_games_uuid_id_key on public.hoop_games (uuid_id);

-- Editors may update a shared game's rows, but never the columns that say whose game it is.
-- Without this, an editor could rewrite user_id to their own id and take the game over
-- (the RLS with-check only asks whether the caller can edit the *new* row, which they then own).
create or replace function private.lock_row_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- The service role (auth.uid() is null) and the owner keep full control.
  if (select auth.uid()) is null or (select auth.uid()) = old.user_id then
    return new;
  end if;
  if new.user_id is distinct from old.user_id
     or new.sync_space is distinct from old.sync_space
     or new.local_id is distinct from old.local_id
     or (tg_table_name = 'hoop_games' and new.uuid_id is distinct from old.uuid_id)
     or (tg_table_name <> 'hoop_games' and new.game_id is distinct from old.game_id) then
    raise exception 'Only the owner can change which game this row belongs to.' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function private.lock_row_identity() from public, anon, authenticated;

drop trigger if exists lock_identity on public.hoop_games;
create trigger lock_identity before update on public.hoop_games
  for each row execute function private.lock_row_identity();
drop trigger if exists lock_identity on public.hoop_events;
create trigger lock_identity before update on public.hoop_events
  for each row execute function private.lock_row_identity();
drop trigger if exists lock_identity on public.hoop_segments;
create trigger lock_identity before update on public.hoop_segments
  for each row execute function private.lock_row_identity();
