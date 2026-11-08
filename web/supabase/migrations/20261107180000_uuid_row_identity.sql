-- Every synced row is identified by a globally unique UUID instead of a device-local integer.
--
-- local_id was only unique inside one owner's sync space, so a client that merged rows from
-- several owners (shared games) keyed them by a number another owner could pick on purpose,
-- and one row silently replaced another. The server now owns a global unique `id` per row;
-- clients generate UUIDv7 values (time ordered, so `order by id` still means creation order).
--
-- The column names clients already use stay the same (`id`, `team_id`, `game_id`, ...); only
-- their type changes from bigint to uuid. `legacy_local_id` keeps the old number so an
-- upgraded app can map the rows it stored locally onto the server's new ids once.
-- Foreign keys stay composite with (user_id, sync_space) so a row can only ever point at a
-- row of the same owner, exactly as before.

-- Existing rows get a deterministic, time-ordered UUIDv7: the 48-bit time prefix comes from the
-- old id (which was creation_ms * 1000 + salt) and the rest from a hash of owner + row.
create or replace function private.legacy_uuid(owner uuid, space text, entity text, local bigint)
returns uuid
language sql immutable
set search_path = ''
as $$
  select (lpad(to_hex(case when abs(local) >= 1000000000000 then abs(local) / 1000 else abs(local) end), 12, '0')
    || '7' || substr(s.h, 1, 3)
    || substr('89ab', (('x' || substr(s.h, 4, 1))::bit(4)::int % 4) + 1, 1)
    || substr(s.h, 5, 15))::uuid
  from (select md5(owner::text || '/' || space || '/' || entity || '/' || local::text) as h) s
$$;
revoke all on function private.legacy_uuid(uuid, text, text, bigint) from public, anon, authenticated;

-- 1. Everything that names the old columns goes first.
drop view if exists public.hoop_accessible_games;

do $$
declare policy record;
begin
  for policy in
    select schemaname, tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('hoop_teams','hoop_players','hoop_games','hoop_events','hoop_segments','hoop_game_permissions','hoop_team_members')
  loop
    execute format('drop policy %I on %I.%I', policy.policyname, policy.schemaname, policy.tablename);
  end loop;
end;
$$;

drop function if exists private.game_access_role(uuid, text, bigint);

do $$
declare constraint_row record;
begin
  -- Foreign keys between the synced tables (auth.users references stay), then their keys.
  for constraint_row in
    select c.conrelid::regclass as rel, c.conname from pg_constraint c
    where c.contype = 'f'
      and c.confrelid in ('public.hoop_teams'::regclass, 'public.hoop_players'::regclass, 'public.hoop_games'::regclass,
                          'public.hoop_events'::regclass, 'public.hoop_segments'::regclass)
  loop
    execute format('alter table %s drop constraint %I', constraint_row.rel, constraint_row.conname);
  end loop;
  for constraint_row in
    select c.conrelid::regclass as rel, c.conname from pg_constraint c
    where c.contype in ('p', 'u')
      and c.conrelid in ('public.hoop_teams'::regclass, 'public.hoop_players'::regclass, 'public.hoop_games'::regclass,
                         'public.hoop_events'::regclass, 'public.hoop_segments'::regclass,
                         'public.hoop_team_members'::regclass, 'public.hoop_deletions'::regclass)
  loop
    execute format('alter table %s drop constraint %I', constraint_row.rel, constraint_row.conname);
  end loop;
end;
$$;

-- 2. New UUID columns, backfilled from the old integer relationships.
alter table public.hoop_teams add column new_id uuid;
update public.hoop_teams set new_id = private.legacy_uuid(user_id, sync_space, 'teams', local_id);

alter table public.hoop_players add column new_id uuid, add column new_team_id uuid;
update public.hoop_players p set
  new_id = private.legacy_uuid(p.user_id, p.sync_space, 'players', p.local_id),
  new_team_id = t.new_id
from public.hoop_teams t
where t.user_id = p.user_id and t.sync_space = p.sync_space and t.local_id = p.team_id;

alter table public.hoop_games add column new_id uuid, add column new_home_id uuid, add column new_away_id uuid;
update public.hoop_games g set
  new_id = g.uuid_id,
  new_home_id = (select t.new_id from public.hoop_teams t where t.user_id = g.user_id and t.sync_space = g.sync_space and t.local_id = g.home_id),
  new_away_id = (select t.new_id from public.hoop_teams t where t.user_id = g.user_id and t.sync_space = g.sync_space and t.local_id = g.away_id);

alter table public.hoop_segments add column new_id uuid, add column new_game_id uuid;
update public.hoop_segments s set
  new_id = private.legacy_uuid(s.user_id, s.sync_space, 'segments', s.local_id),
  new_game_id = g.new_id
from public.hoop_games g
where g.user_id = s.user_id and g.sync_space = s.sync_space and g.local_id = s.game_id;

alter table public.hoop_events add column new_id uuid, add column new_game_id uuid, add column new_team_id uuid, add column new_player_id uuid;
update public.hoop_events e set
  new_id = private.legacy_uuid(e.user_id, e.sync_space, 'events', e.local_id),
  new_game_id = (select g.new_id from public.hoop_games g where g.user_id = e.user_id and g.sync_space = e.sync_space and g.local_id = e.game_id),
  new_team_id = (select t.new_id from public.hoop_teams t where t.user_id = e.user_id and t.sync_space = e.sync_space and t.local_id = e.team_id),
  new_player_id = (select p.new_id from public.hoop_players p where p.user_id = e.user_id and p.sync_space = e.sync_space and p.local_id = e.player_id);

alter table public.hoop_team_members add column new_team_id uuid;
update public.hoop_team_members m set new_team_id = t.new_id
from public.hoop_teams t
where t.user_id = m.owner_id and t.sync_space = m.sync_space and t.local_id = m.team_id;

alter table public.hoop_game_permissions add column new_game_id uuid, add column new_subject_team_id uuid;
update public.hoop_game_permissions p set
  new_game_id = (select g.new_id from public.hoop_games g where g.user_id = p.owner_id and g.sync_space = p.sync_space and g.local_id = p.game_id),
  new_subject_team_id = (select t.new_id from public.hoop_teams t where t.user_id = p.owner_id and t.sync_space = p.sync_space and t.local_id = p.subject_team_id);

-- Tombstones name the deleted row's UUID; an already-gone row gets the same deterministic UUID
-- its row would have received, and keeps legacy_local_id for upgrading clients.
alter table public.hoop_deletions add column row_id uuid;
update public.hoop_deletions d set row_id = coalesce(
  case when d.entity = 'games' then (select g.new_id from public.hoop_games g where g.user_id = d.user_id and g.sync_space = d.sync_space and g.local_id = d.local_id) end,
  private.legacy_uuid(d.user_id, d.sync_space, d.entity, d.local_id));

-- Highlights name their target by id ("player:<id>" / "team:<id>").
alter table public.hoop_highlight_videos drop constraint if exists highlight_videos_target_key_check;
update public.hoop_highlight_videos h set target_key = split_part(h.target_key, ':', 1) || ':' || coalesce(
  (select p.new_id::text from public.hoop_players p join public.hoop_games g on g.user_id = p.user_id and g.sync_space = p.sync_space
    where g.uuid_id::text = h.game_uuid and split_part(h.target_key, ':', 1) = 'player' and p.local_id = split_part(h.target_key, ':', 2)::bigint),
  (select t.new_id::text from public.hoop_teams t join public.hoop_games g on g.user_id = t.user_id and g.sync_space = t.sync_space
    where g.uuid_id::text = h.game_uuid and split_part(h.target_key, ':', 1) = 'team' and t.local_id = split_part(h.target_key, ':', 2)::bigint),
  private.legacy_uuid(h.user_id, '', split_part(h.target_key, ':', 1), split_part(h.target_key, ':', 2)::bigint)::text);
alter table public.hoop_highlight_videos add constraint highlight_videos_target_key_check
  check (target_key ~ '^(player|team):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

-- 3. Swap the columns.
alter table public.hoop_teams rename column local_id to legacy_local_id;
alter table public.hoop_teams alter column legacy_local_id drop not null;
alter table public.hoop_teams rename column new_id to id;

alter table public.hoop_players rename column local_id to legacy_local_id;
alter table public.hoop_players alter column legacy_local_id drop not null;
alter table public.hoop_players drop column team_id;
alter table public.hoop_players rename column new_id to id;
alter table public.hoop_players rename column new_team_id to team_id;

alter table public.hoop_games rename column local_id to legacy_local_id;
alter table public.hoop_games alter column legacy_local_id drop not null;
alter table public.hoop_games drop column home_id, drop column away_id, drop column uuid_id;
alter table public.hoop_games rename column new_id to id;
alter table public.hoop_games rename column new_home_id to home_id;
alter table public.hoop_games rename column new_away_id to away_id;

alter table public.hoop_segments rename column local_id to legacy_local_id;
alter table public.hoop_segments alter column legacy_local_id drop not null;
alter table public.hoop_segments drop column game_id, drop column game_uuid_id;
alter table public.hoop_segments rename column new_id to id;
alter table public.hoop_segments rename column new_game_id to game_id;

alter table public.hoop_events rename column local_id to legacy_local_id;
alter table public.hoop_events alter column legacy_local_id drop not null;
alter table public.hoop_events drop column game_id, drop column team_id, drop column player_id, drop column game_uuid_id;
alter table public.hoop_events rename column new_id to id;
alter table public.hoop_events rename column new_game_id to game_id;
alter table public.hoop_events rename column new_team_id to team_id;
alter table public.hoop_events rename column new_player_id to player_id;

alter table public.hoop_team_members drop column team_id;
alter table public.hoop_team_members rename column new_team_id to team_id;

alter table public.hoop_game_permissions drop column game_id, drop column subject_team_id, drop column game_uuid_id;
alter table public.hoop_game_permissions rename column new_game_id to game_id;
alter table public.hoop_game_permissions rename column new_subject_team_id to subject_team_id;

alter table public.hoop_deletions rename column local_id to legacy_local_id;
alter table public.hoop_deletions alter column legacy_local_id drop not null;

-- Rows whose parent never existed could not be mapped; they were already unreachable.
delete from public.hoop_events where game_id is null or team_id is null;
delete from public.hoop_segments where game_id is null;
delete from public.hoop_players where team_id is null;
delete from public.hoop_games where home_id is null or away_id is null;
delete from public.hoop_team_members where team_id is null;
delete from public.hoop_game_permissions where game_id is null or (subject_type = 'team' and subject_team_id is null);

-- 4. Keys.
alter table public.hoop_teams alter column id set not null, alter column id set default gen_random_uuid(),
  add primary key (id), add constraint hoop_teams_owner_id_key unique (user_id, sync_space, id);
alter table public.hoop_players alter column id set not null, alter column id set default gen_random_uuid(),
  alter column team_id set not null,
  add primary key (id), add constraint hoop_players_owner_id_key unique (user_id, sync_space, id),
  add constraint player_team_fk foreign key (user_id, sync_space, team_id)
    references public.hoop_teams (user_id, sync_space, id) on delete cascade;
alter table public.hoop_games alter column id set not null, alter column id set default gen_random_uuid(),
  alter column home_id set not null, alter column away_id set not null,
  add primary key (id), add constraint hoop_games_owner_id_key unique (user_id, sync_space, id),
  add constraint game_different_teams check (home_id <> away_id),
  add constraint game_home_team_fk foreign key (user_id, sync_space, home_id) references public.hoop_teams (user_id, sync_space, id),
  add constraint game_away_team_fk foreign key (user_id, sync_space, away_id) references public.hoop_teams (user_id, sync_space, id);
alter table public.hoop_segments alter column id set not null, alter column id set default gen_random_uuid(),
  alter column game_id set not null,
  add primary key (id),
  add constraint segment_game_fk foreign key (user_id, sync_space, game_id)
    references public.hoop_games (user_id, sync_space, id) on delete cascade,
  add constraint segment_game_sequence_key unique (user_id, sync_space, game_id, sequence);
alter table public.hoop_events alter column id set not null, alter column id set default gen_random_uuid(),
  alter column game_id set not null, alter column team_id set not null,
  add primary key (id),
  add constraint event_game_fk foreign key (user_id, sync_space, game_id) references public.hoop_games (user_id, sync_space, id) on delete cascade,
  add constraint event_team_fk foreign key (user_id, sync_space, team_id) references public.hoop_teams (user_id, sync_space, id),
  add constraint event_player_fk foreign key (user_id, sync_space, player_id) references public.hoop_players (user_id, sync_space, id),
  add constraint event_segment_fk foreign key (user_id, sync_space, game_id, segment)
    references public.hoop_segments (user_id, sync_space, game_id, sequence) on delete cascade;
alter table public.hoop_team_members alter column team_id set not null,
  add primary key (owner_id, sync_space, team_id, member_email),
  add foreign key (owner_id, sync_space, team_id) references public.hoop_teams (user_id, sync_space, id) on delete cascade;
alter table public.hoop_game_permissions alter column game_id set not null,
  add foreign key (owner_id, sync_space, game_id) references public.hoop_games (user_id, sync_space, id) on delete cascade;
alter table public.hoop_game_permissions drop constraint if exists game_permissions_check;
alter table public.hoop_game_permissions add constraint game_permissions_subject_check check (
  (subject_type = 'user' and subject_email = lower(btrim(subject_email)) and subject_club_id is null and subject_team_id is null)
  or (subject_type = 'club' and subject_email is null and subject_club_id is not null and subject_team_id is null)
  or (subject_type = 'team' and subject_email is null and subject_club_id is null and subject_team_id is not null)
  or (subject_type = 'everyone' and subject_email is null and subject_club_id is null and subject_team_id is null));
alter table public.hoop_deletions alter column row_id set not null,
  add primary key (user_id, sync_space, entity, row_id);

create index if not exists player_team_idx on public.hoop_players (user_id, sync_space, team_id);
create index if not exists game_home_idx on public.hoop_games (user_id, sync_space, home_id);
create index if not exists game_away_idx on public.hoop_games (user_id, sync_space, away_id);
create index if not exists event_game_idx on public.hoop_events (user_id, sync_space, game_id);
create index if not exists event_team_idx on public.hoop_events (user_id, sync_space, team_id);
create index if not exists event_player_idx on public.hoop_events (user_id, sync_space, player_id) where player_id is not null;
create index if not exists event_segment_fk_idx on public.hoop_events (user_id, sync_space, game_id, segment);
create index if not exists team_members_email_idx on public.hoop_team_members (member_email, owner_id, sync_space, team_id);
create index if not exists game_permissions_game_idx on public.hoop_game_permissions (owner_id, sync_space, game_id);
create index if not exists legacy_teams_idx on public.hoop_teams (user_id, sync_space, legacy_local_id) where legacy_local_id is not null;
create index if not exists legacy_players_idx on public.hoop_players (user_id, sync_space, legacy_local_id) where legacy_local_id is not null;
create index if not exists legacy_games_idx on public.hoop_games (user_id, sync_space, legacy_local_id) where legacy_local_id is not null;
create index if not exists legacy_events_idx on public.hoop_events (user_id, sync_space, legacy_local_id) where legacy_local_id is not null;
create index if not exists legacy_segments_idx on public.hoop_segments (user_id, sync_space, legacy_local_id) where legacy_local_id is not null;
create unique index if not exists game_permissions_user_unique on public.hoop_game_permissions (owner_id, sync_space, game_id, role, subject_email) where subject_type = 'user';
create unique index if not exists game_permissions_club_unique on public.hoop_game_permissions (owner_id, sync_space, game_id, role, subject_club_id) where subject_type = 'club';
create unique index if not exists game_permissions_team_unique on public.hoop_game_permissions (owner_id, sync_space, game_id, role, subject_team_id) where subject_type = 'team';
create unique index if not exists game_permissions_everyone_unique on public.hoop_game_permissions (owner_id, sync_space, game_id, role) where subject_type = 'everyone';

-- 5. Derived media is keyed by the game id and goes with the game.
delete from public.hoop_replay_videos v where not exists (select 1 from public.hoop_games g where g.id::text = v.game_uuid);
delete from public.hoop_highlight_videos v where not exists (select 1 from public.hoop_games g where g.id::text = v.game_uuid);
alter table public.hoop_replay_videos alter column game_uuid type uuid using game_uuid::uuid,
  add constraint replay_videos_game_fk foreign key (game_uuid) references public.hoop_games (id) on delete cascade;
alter table public.hoop_highlight_videos alter column game_uuid type uuid using game_uuid::uuid,
  add constraint highlight_videos_game_fk foreign key (game_uuid) references public.hoop_games (id) on delete cascade;

-- A deleted game's id is never handed out again: clients choose ids, and a game recreated with an
-- old id would otherwise inherit that id's footage keys, purchases and attempt counts.
create table if not exists public.hoop_retired_game_ids (
  id uuid primary key,
  retired_at timestamptz not null default now()
);
alter table public.hoop_retired_game_ids enable row level security;
revoke all on public.hoop_retired_game_ids from anon, authenticated;

create or replace function private.retire_game_id()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.hoop_retired_game_ids (id) values (old.id) on conflict do nothing;
  return null;
end;
$$;

-- Skipping (not raising) keeps a stale device's save from failing forever; the tombstone it
-- pulls next removes the row locally.
create or replace function private.reject_retired_game_id()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.hoop_retired_game_ids r where r.id = new.id) then
    return null;
  end if;
  return new;
end;
$$;
revoke all on function private.retire_game_id(), private.reject_retired_game_id() from public, anon, authenticated;

drop trigger if exists retire_game_id on public.hoop_games;
create trigger retire_game_id after delete on public.hoop_games
  for each row execute function private.retire_game_id();
drop trigger if exists reject_retired_game_id on public.hoop_games;
create trigger reject_retired_game_id before insert on public.hoop_games
  for each row execute function private.reject_retired_game_id();

-- 6. Sharing identity: only a confirmed email address counts. The JWT `email` claim is whatever
-- address the account was created with, confirmed or not, so a sign-up with someone else's
-- address used to inherit every game shared with that address.
create or replace function private.request_email()
returns text
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select lower(u.email) from auth.users u
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
      and (u.raw_app_meta_data ->> 'email_proven')::boolean is true), '')
$$;
revoke all on function private.request_email() from public;
grant execute on function private.request_email() to authenticated;

-- email_confirmed_at alone is not proof: an auto-confirmed signup (confirmation disabled, or an
-- admin-created account) has it set from the start. Only an actual confirmation (null -> set) or
-- the server's OAuth login (which sets app_metadata.email_proven itself) proves the address.
-- app_metadata is not writable by users.
create or replace function private.mark_email_proven()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    new.raw_app_meta_data := coalesce(new.raw_app_meta_data, '{}'::jsonb) || '{"email_proven": true}'::jsonb;
  end if;
  if new.email is distinct from old.email then
    -- A new address is a new owner to prove: the OAuth claim on the old one no longer counts.
    new.raw_app_meta_data := coalesce(new.raw_app_meta_data, '{}'::jsonb) - 'email_proven' - 'oauth_claimed';
    if new.email_confirmed_at is not null and new.email_change = '' and old.email_change <> '' then
      -- Supabase applies a confirmed email change by rewriting email: the new address was proven.
      new.raw_app_meta_data := new.raw_app_meta_data || '{"email_proven": true}'::jsonb;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.mark_email_proven() from public, anon, authenticated;
drop trigger if exists hoop_mark_email_proven on auth.users;
create trigger hoop_mark_email_proven before update on auth.users
  for each row execute function private.mark_email_proven();

-- The first time a provider identity (Google/Apple, including iOS's native Apple id_token grant
-- that bypasses the web login) is attached to an account, any password set before that is
-- discarded: it may belong to someone who pre-registered the address without proving it.
-- The web mintSession path does the same; this covers GoTrue's own linking.
create or replace function private.claim_on_provider_link()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.provider <> 'email' then
    update auth.users u
    set encrypted_password = '',
        raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb) || '{"oauth_claimed": true, "email_proven": true}'::jsonb
    where u.id = new.user_id
      and coalesce((u.raw_app_meta_data ->> 'oauth_claimed')::boolean, false) is false
      and lower(u.email) = lower(new.identity_data ->> 'email');
  end if;
  return null;
end;
$$;
revoke all on function private.claim_on_provider_link() from public, anon, authenticated;
drop trigger if exists hoop_claim_on_provider_link on auth.identities;
create trigger hoop_claim_on_provider_link after insert on auth.identities
  for each row execute function private.claim_on_provider_link();

-- ponytail: existing confirmed accounts are grandfathered as proven; their origin can't be told apart now.
update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"email_proven": true}'::jsonb
where email_confirmed_at is not null;

create or replace function private.game_access_role(game_owner uuid, game_space text, requested_game uuid)
returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when (select auth.uid()) = game_owner then 'owner'
    when private.request_email() = '' then null
    when exists (
      select 1 from public.hoop_game_permissions permission
      where permission.owner_id = game_owner and permission.sync_space = game_space and permission.game_id = requested_game
        and permission.role = 'editor' and permission.subject_type = 'user'
        and permission.subject_email = private.request_email()
    ) then 'editor'
    when exists (
      select 1 from public.hoop_game_permissions permission
      where permission.owner_id = game_owner and permission.sync_space = game_space and permission.game_id = requested_game
        and permission.role = 'viewer' and (
          permission.subject_type = 'everyone'
          or (permission.subject_type = 'user' and permission.subject_email = private.request_email())
          or (permission.subject_type = 'club' and exists (
            select 1 from public.hoop_club_members member
            where member.club_id = permission.subject_club_id and member.member_email = private.request_email()
          ))
          or (permission.subject_type = 'team' and exists (
            select 1 from public.hoop_team_members member
            where member.owner_id = permission.owner_id and member.sync_space = permission.sync_space
              and member.team_id = permission.subject_team_id and member.member_email = private.request_email()
          ))
        )
    ) then 'viewer'
    else null
  end
$$;
revoke all on function private.game_access_role(uuid, text, uuid) from public;
grant execute on function private.game_access_role(uuid, text, uuid) to authenticated;

-- 7. Policies (same rules as before, keyed by id).
create policy "authorized users read teams" on public.hoop_teams for select to authenticated
  using ((select auth.uid()) = user_id or exists (
    select 1 from public.hoop_games game
    where game.user_id = hoop_teams.user_id and game.sync_space = hoop_teams.sync_space
      and (game.home_id = hoop_teams.id or game.away_id = hoop_teams.id)));
create policy "authorized users read players" on public.hoop_players for select to authenticated
  using ((select auth.uid()) = user_id or exists (
    select 1 from public.hoop_games game
    where game.user_id = hoop_players.user_id and game.sync_space = hoop_players.sync_space
      and (game.home_id = hoop_players.team_id or game.away_id = hoop_players.team_id)));

do $$
declare synced text;
begin
  foreach synced in array array['hoop_teams', 'hoop_players'] loop
    execute format('create policy "owners insert rows" on public.%I for insert to authenticated with check ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'')', synced);
    execute format('create policy "owners update rows" on public.%I for update to authenticated using ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'') with check ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'')', synced);
    execute format('create policy "owners delete rows" on public.%I for delete to authenticated using ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'')', synced);
  end loop;
end;
$$;

create policy "authorized users read games" on public.hoop_games for select to authenticated
  using (private.game_access_role(user_id, sync_space, id) is not null);
create policy "owners insert games" on public.hoop_games for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "owners and editors update games" on public.hoop_games for update to authenticated
  using (private.game_access_role(user_id, sync_space, id) in ('owner', 'editor'))
  with check (private.game_access_role(user_id, sync_space, id) in ('owner', 'editor'));
create policy "owners delete games" on public.hoop_games for delete to authenticated
  using ((select auth.uid()) = user_id);

do $$
declare synced text;
begin
  foreach synced in array array['hoop_events', 'hoop_segments'] loop
    execute format('create policy "authorized users read rows" on public.%I for select to authenticated using (private.game_access_role(user_id, sync_space, game_id) is not null)', synced);
    execute format('create policy "owners and editors insert rows" on public.%I for insert to authenticated with check (private.game_access_role(user_id, sync_space, game_id) in (''owner'', ''editor''))', synced);
    execute format('create policy "owners and editors update rows" on public.%I for update to authenticated using (private.game_access_role(user_id, sync_space, game_id) in (''owner'', ''editor'')) with check (private.game_access_role(user_id, sync_space, game_id) in (''owner'', ''editor''))', synced);
    execute format('create policy "owners and editors delete rows" on public.%I for delete to authenticated using (private.game_access_role(user_id, sync_space, game_id) in (''owner'', ''editor''))', synced);
  end loop;
end;
$$;

create policy "owners and members read team memberships" on public.hoop_team_members for select to authenticated
  using ((select auth.uid()) = owner_id or member_email = private.request_email());
create policy "owners insert team memberships" on public.hoop_team_members for insert to authenticated
  with check ((select auth.uid()) = owner_id);
create policy "owners update team memberships" on public.hoop_team_members for update to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "owners delete team memberships" on public.hoop_team_members for delete to authenticated
  using ((select auth.uid()) = owner_id);

-- A participant sees only the grant that lets them in, never the owner's whole list of
-- invited email addresses.
create policy "owners and grantees read game permissions" on public.hoop_game_permissions for select to authenticated
  using ((select auth.uid()) = owner_id
    or (subject_type = 'user' and subject_email = private.request_email() and private.request_email() <> ''));
create policy "owners insert game permissions" on public.hoop_game_permissions for insert to authenticated
  with check ((select auth.uid()) = owner_id);
create policy "owners update game permissions" on public.hoop_game_permissions for update to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "owners delete game permissions" on public.hoop_game_permissions for delete to authenticated
  using ((select auth.uid()) = owner_id);

-- 8. Editors may change a shared game's play-by-play, never what it is or where its video lives.
-- Changing home/away to another of the owner's teams would expose that team's roster; changing a
-- segment's uri makes the owner's phone open whatever path the editor wrote.
create or replace function private.lock_row_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  current_row jsonb;
  proposed jsonb := to_jsonb(new);
  key text;
begin
  -- The service role (no auth.uid()) and the owner keep full control.
  if me is null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if me = new.user_id or tg_table_name <> 'hoop_segments' then
      return new;
    end if;
    -- An editor's upsert of an existing segment turns into an update, which the update branch
    -- polices column by column; only a genuinely new segment is refused here.
    if not exists (select 1 from public.hoop_segments s where s.id = new.id) then
      raise exception 'Only the owner can add video segments.' using errcode = '42501';
    end if;
    return new;
  else
    if me = old.user_id then
      return new;
    end if;
    current_row := to_jsonb(old);
  end if;
  foreach key in array case tg_table_name
      when 'hoop_games' then array['id', 'user_id', 'sync_space', 'legacy_local_id', 'home_id', 'away_id']
      when 'hoop_segments' then array['id', 'user_id', 'sync_space', 'legacy_local_id', 'game_id', 'sequence', 'uri', 'object_key', 'duration_ms', 'upload_status']
      else array['id', 'user_id', 'sync_space', 'legacy_local_id', 'game_id'] end loop
    if proposed -> key is distinct from current_row -> key then
      raise exception 'Only the owner can change %.%', tg_table_name, key using errcode = '42501';
    end if;
  end loop;
  return new;
end;
$$;
revoke all on function private.lock_row_identity() from public, anon, authenticated;

drop trigger if exists lock_identity on public.hoop_segments;
create trigger lock_identity before insert or update on public.hoop_segments
  for each row execute function private.lock_row_identity();

-- 8b. Every deletion leaves a tombstone in the OWNER's space, whoever deleted the row (an editor
-- deleting a shared game's event, or a cascade). Otherwise the owner's devices never learn about
-- it and push their cached copy straight back.
create or replace function private.record_tombstone()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.hoop_deletions (user_id, sync_space, entity, row_id, deleted_at, device_id)
  values (old.user_id, old.sync_space, substr(tg_table_name, 6), old.id,
          (extract(epoch from clock_timestamp()) * 1000)::bigint, 'server')
  on conflict do nothing;
  return null;
end;
$$;
revoke all on function private.record_tombstone() from public, anon, authenticated;
do $$
declare synced text;
begin
  foreach synced in array array['hoop_teams', 'hoop_players', 'hoop_games', 'hoop_events', 'hoop_segments'] loop
    execute format('drop trigger if exists record_tombstone on public.%I', synced);
    execute format('create trigger record_tombstone after delete on public.%I for each row execute function private.record_tombstone()', synced);
  end loop;
end;
$$;

-- 9. The view expands game.* at creation, so it is rebuilt on the new columns.
create view public.hoop_accessible_games
with (security_invoker = true)
as
select game.*, private.game_access_role(game.user_id, game.sync_space, game.id) as access_role
from public.hoop_games game;
revoke all on public.hoop_accessible_games from anon;
grant select on public.hoop_accessible_games to authenticated;

notify pgrst, 'reload schema';
