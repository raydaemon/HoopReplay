-- Give every game a stable UUID while retaining local_id for backwards
-- compatibility with older Web and Android clients during the rollout.

create extension if not exists pgcrypto;

alter table public.games
  add column if not exists uuid_id uuid;

update public.games
set uuid_id = gen_random_uuid()
where uuid_id is null;

alter table public.games
  alter column uuid_id set default gen_random_uuid(),
  alter column uuid_id set not null;

create unique index if not exists games_uuid_id_idx
  on public.games (user_id, sync_space, uuid_id);

alter table public.events
  add column if not exists game_uuid_id uuid;

update public.events event_row
set game_uuid_id = game.uuid_id
from public.games game
where event_row.game_uuid_id is null
  and event_row.user_id = game.user_id
  and event_row.sync_space = game.sync_space
  and event_row.game_id = game.local_id;

alter table public.segments
  add column if not exists game_uuid_id uuid;

update public.segments segment_row
set game_uuid_id = game.uuid_id
from public.games game
where segment_row.game_uuid_id is null
  and segment_row.user_id = game.user_id
  and segment_row.sync_space = game.sync_space
  and segment_row.game_id = game.local_id;

alter table public.game_permissions
  add column if not exists game_uuid_id uuid;

update public.game_permissions permission_row
set game_uuid_id = game.uuid_id
from public.games game
where permission_row.game_uuid_id is null
  and permission_row.owner_id = game.user_id
  and permission_row.sync_space = game.sync_space
  and permission_row.game_id = game.local_id;

create index if not exists events_game_uuid_id_idx
  on public.events (user_id, sync_space, game_uuid_id);

create index if not exists segments_game_uuid_id_idx
  on public.segments (user_id, sync_space, game_uuid_id);

create index if not exists game_permissions_game_uuid_id_idx
  on public.game_permissions (owner_id, sync_space, game_uuid_id);

comment on column public.games.uuid_id is
  'Canonical game identifier. local_id remains temporarily for legacy clients.';
comment on column public.events.game_uuid_id is
  'Canonical UUID reference to games.uuid_id.';
comment on column public.segments.game_uuid_id is
  'Canonical UUID reference to games.uuid_id.';
comment on column public.game_permissions.game_uuid_id is
  'Canonical UUID reference to games.uuid_id.';
