create schema if not exists private;

create table public.clubs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  created_at timestamptz not null default now(),
  unique (owner_id, name)
);

create table public.club_members (
  club_id uuid not null references public.clubs(id) on delete cascade,
  member_email text not null check (member_email = lower(btrim(member_email)) and member_email <> ''),
  created_at timestamptz not null default now(),
  primary key (club_id, member_email)
);

create table public.team_members (
  owner_id uuid not null,
  sync_space text not null,
  team_id bigint not null,
  member_email text not null check (member_email = lower(btrim(member_email)) and member_email <> ''),
  created_at timestamptz not null default now(),
  primary key (owner_id, sync_space, team_id, member_email),
  foreign key (owner_id, sync_space, team_id)
    references public.teams(user_id, sync_space, local_id) on delete cascade
);

create table public.game_permissions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null,
  sync_space text not null,
  game_id bigint not null,
  role text not null check (role in ('editor', 'viewer')),
  subject_type text not null check (subject_type in ('user', 'club', 'team', 'everyone')),
  subject_email text,
  subject_club_id uuid references public.clubs(id) on delete cascade,
  subject_team_id bigint,
  created_at timestamptz not null default now(),
  foreign key (owner_id, sync_space, game_id)
    references public.games(user_id, sync_space, local_id) on delete cascade,
  check (
    (subject_type = 'user' and subject_email = lower(btrim(subject_email)) and subject_club_id is null and subject_team_id is null)
    or (subject_type = 'club' and subject_email is null and subject_club_id is not null and subject_team_id is null)
    or (subject_type = 'team' and subject_email is null and subject_club_id is null and subject_team_id is not null)
    or (subject_type = 'everyone' and subject_email is null and subject_club_id is null and subject_team_id is null)
  ),
  check (role = 'viewer' or subject_type = 'user')
);

create unique index game_permissions_user_unique
  on public.game_permissions (owner_id, sync_space, game_id, role, subject_email)
  where subject_type = 'user';
create unique index game_permissions_club_unique
  on public.game_permissions (owner_id, sync_space, game_id, role, subject_club_id)
  where subject_type = 'club';
create unique index game_permissions_team_unique
  on public.game_permissions (owner_id, sync_space, game_id, role, subject_team_id)
  where subject_type = 'team';
create unique index game_permissions_everyone_unique
  on public.game_permissions (owner_id, sync_space, game_id, role)
  where subject_type = 'everyone';
create index club_members_email_idx on public.club_members (member_email, club_id);
create index team_members_email_idx on public.team_members (member_email, owner_id, sync_space, team_id);
create index game_permissions_game_idx on public.game_permissions (owner_id, sync_space, game_id);

create or replace function private.request_email()
returns text
language sql stable security invoker
set search_path = ''
as $$
  select lower(coalesce((select auth.jwt()) ->> 'email', ''))
$$;

create or replace function private.game_access_role(game_owner uuid, game_space text, requested_game bigint)
returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when (select auth.uid()) = game_owner then 'owner'
    when exists (
      select 1 from public.game_permissions permission
      where permission.owner_id = game_owner and permission.sync_space = game_space and permission.game_id = requested_game
        and permission.role = 'editor' and permission.subject_type = 'user'
        and permission.subject_email = private.request_email()
    ) then 'editor'
    when exists (
      select 1 from public.game_permissions permission
      where permission.owner_id = game_owner and permission.sync_space = game_space and permission.game_id = requested_game
        and permission.role = 'viewer' and (
          permission.subject_type = 'everyone'
          or (permission.subject_type = 'user' and permission.subject_email = private.request_email())
          or (permission.subject_type = 'club' and exists (
            select 1 from public.club_members member
            where member.club_id = permission.subject_club_id and member.member_email = private.request_email()
          ))
          or (permission.subject_type = 'team' and exists (
            select 1 from public.team_members member
            where member.owner_id = permission.owner_id and member.sync_space = permission.sync_space
              and member.team_id = permission.subject_team_id and member.member_email = private.request_email()
          ))
        )
    ) then 'viewer'
    else null
  end
$$;

revoke all on function private.request_email() from public;
revoke all on function private.game_access_role(uuid, text, bigint) from public;
grant usage on schema private to authenticated;
grant execute on function private.request_email() to authenticated;
grant execute on function private.game_access_role(uuid, text, bigint) to authenticated;

alter table public.clubs enable row level security;
alter table public.club_members enable row level security;
alter table public.team_members enable row level security;
alter table public.game_permissions enable row level security;

revoke all on public.clubs, public.club_members, public.team_members, public.game_permissions from anon;
grant select, insert, update, delete on public.clubs, public.club_members, public.team_members, public.game_permissions to authenticated;

create policy "owners manage clubs" on public.clubs for all to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "owners and members read club memberships" on public.club_members for select to authenticated
  using (member_email = private.request_email() or exists (
    select 1 from public.clubs club where club.id = club_id and club.owner_id = (select auth.uid())
  ));
create policy "owners manage club memberships" on public.club_members for all to authenticated
  using (exists (select 1 from public.clubs club where club.id = club_id and club.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.clubs club where club.id = club_id and club.owner_id = (select auth.uid())));
create policy "owners and members read team memberships" on public.team_members for select to authenticated
  using ((select auth.uid()) = owner_id or member_email = private.request_email());
create policy "owners manage team memberships" on public.team_members for all to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "participants read game permissions" on public.game_permissions for select to authenticated
  using ((select auth.uid()) = owner_id or private.game_access_role(owner_id, sync_space, game_id) is not null);
create policy "owners manage game permissions" on public.game_permissions for all to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);

drop policy if exists "users read own game" on public.games;
drop policy if exists "users insert own game" on public.games;
drop policy if exists "users update own game" on public.games;
drop policy if exists "users delete own game" on public.games;
create policy "authorized users read games" on public.games for select to authenticated
  using (private.game_access_role(user_id, sync_space, local_id) is not null);
create policy "owners insert games" on public.games for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "owners and editors update games" on public.games for update to authenticated
  using (private.game_access_role(user_id, sync_space, local_id) in ('owner', 'editor'))
  with check (private.game_access_role(user_id, sync_space, local_id) in ('owner', 'editor'));
create policy "owners delete games" on public.games for delete to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "users read own event" on public.events;
drop policy if exists "users insert own event" on public.events;
drop policy if exists "users update own event" on public.events;
drop policy if exists "users delete own event" on public.events;
create policy "authorized users read events" on public.events for select to authenticated
  using (private.game_access_role(user_id, sync_space, game_id) is not null);
create policy "owners and editors insert events" on public.events for insert to authenticated
  with check (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'));
create policy "owners and editors update events" on public.events for update to authenticated
  using (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'))
  with check (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'));
create policy "owners and editors delete events" on public.events for delete to authenticated
  using (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'));

drop policy if exists "users read own segment" on public.segments;
drop policy if exists "users insert own segment" on public.segments;
drop policy if exists "users update own segment" on public.segments;
drop policy if exists "users delete own segment" on public.segments;
create policy "authorized users read segments" on public.segments for select to authenticated
  using (private.game_access_role(user_id, sync_space, game_id) is not null);
create policy "owners and editors insert segments" on public.segments for insert to authenticated
  with check (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'));
create policy "owners and editors update segments" on public.segments for update to authenticated
  using (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'))
  with check (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'));
create policy "owners and editors delete segments" on public.segments for delete to authenticated
  using (private.game_access_role(user_id, sync_space, game_id) in ('owner', 'editor'));

drop policy if exists "users read own team" on public.teams;
create policy "authorized users read teams" on public.teams for select to authenticated
  using ((select auth.uid()) = user_id or exists (
    select 1 from public.games game
    where game.user_id = teams.user_id and game.sync_space = teams.sync_space
      and (game.home_id = teams.local_id or game.away_id = teams.local_id)
  ));

drop policy if exists "users read own player" on public.players;
create policy "authorized users read players" on public.players for select to authenticated
  using ((select auth.uid()) = user_id or exists (
    select 1 from public.games game
    where game.user_id = players.user_id and game.sync_space = players.sync_space
      and (game.home_id = players.team_id or game.away_id = players.team_id)
  ));

create view public.accessible_games
with (security_invoker = true)
as
select game.*, private.game_access_role(game.user_id, game.sync_space, game.local_id) as access_role
from public.games game;

revoke all on public.accessible_games from anon;
grant select on public.accessible_games to authenticated;
