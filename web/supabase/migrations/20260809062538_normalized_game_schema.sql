-- Store HoopReplay data relationally while preserving the device-local integer IDs.
-- user_id + sync_space isolates accounts and lets each device keep its SQLite IDs.

create table if not exists public.team (
  user_id uuid not null references auth.users(id) on delete cascade,
  sync_space text not null check (char_length(sync_space) >= 24),
  local_id bigint not null,
  name text not null check (btrim(name) <> ''),
  created_at bigint not null,
  primary key (user_id, sync_space, local_id)
);

create table if not exists public.player (
  user_id uuid not null,
  sync_space text not null check (char_length(sync_space) >= 24),
  local_id bigint not null,
  team_id bigint not null,
  name text not null default '',
  number text not null default '',
  primary key (user_id, sync_space, local_id),
  constraint player_has_name_or_number check (btrim(name) <> '' or btrim(number) <> ''),
  constraint player_team_fk foreign key (user_id, sync_space, team_id)
    references public.team (user_id, sync_space, local_id) on delete cascade
);

create table if not exists public.game (
  user_id uuid not null,
  sync_space text not null check (char_length(sync_space) >= 24),
  local_id bigint not null,
  title text not null,
  home_id bigint not null,
  away_id bigint not null,
  home_score integer not null default 0 check (home_score >= 0),
  away_score integer not null default 0 check (away_score >= 0),
  status text not null check (status in ('DRAFT','READY','RECORDING','PAUSED','PROCESSING','COMPLETED','FAILED','ERROR')),
  scheduled_at bigint not null,
  video_quality text not null default 'HIGHEST',
  period_count integer not null default 4 check (period_count > 0),
  period_duration_ms bigint not null default 480000 check (period_duration_ms > 0),
  current_period integer not null default 1 check (current_period > 0),
  clock_remaining_ms bigint not null default 480000 check (clock_remaining_ms >= 0),
  created_at bigint not null,
  primary key (user_id, sync_space, local_id),
  constraint game_different_teams check (home_id <> away_id),
  constraint game_home_team_fk foreign key (user_id, sync_space, home_id)
    references public.team (user_id, sync_space, local_id),
  constraint game_away_team_fk foreign key (user_id, sync_space, away_id)
    references public.team (user_id, sync_space, local_id)
);

create table if not exists public.event (
  user_id uuid not null,
  sync_space text not null check (char_length(sync_space) >= 24),
  local_id bigint not null,
  game_id bigint not null,
  team_id bigint not null,
  player_id bigint,
  type text not null check (type in ('PTS_1','PTS_2','PTS_3','MISS_2','MISS_3','FT_MADE','FT_MISS','REB','AST','STL','BLK','TOV','FOUL','SUB_OUT','SUB_IN')),
  value integer not null,
  period integer not null check (period > 0),
  game_clock_ms bigint not null check (game_clock_ms >= 0),
  segment integer not null check (segment >= 0),
  segment_time_ms bigint not null check (segment_time_ms >= 0),
  final_video_time_ms bigint not null check (final_video_time_ms >= 0),
  reverted boolean not null default false,
  created_at bigint not null,
  primary key (user_id, sync_space, local_id),
  constraint event_game_fk foreign key (user_id, sync_space, game_id)
    references public.game (user_id, sync_space, local_id) on delete cascade,
  constraint event_team_fk foreign key (user_id, sync_space, team_id)
    references public.team (user_id, sync_space, local_id),
  constraint event_player_fk foreign key (user_id, sync_space, player_id)
    references public.player (user_id, sync_space, local_id)
);

create table if not exists public.segment (
  user_id uuid not null,
  sync_space text not null check (char_length(sync_space) >= 24),
  local_id bigint not null,
  game_id bigint not null,
  sequence integer not null check (sequence > 0),
  uri text not null,
  duration_ms bigint not null default 0 check (duration_ms >= 0),
  created_at bigint not null,
  primary key (user_id, sync_space, local_id),
  constraint segment_game_fk foreign key (user_id, sync_space, game_id)
    references public.game (user_id, sync_space, local_id) on delete cascade,
  constraint segment_game_sequence_key unique (user_id, sync_space, game_id, sequence)
);

create index if not exists player_team_idx on public.player (user_id, sync_space, team_id);
create index if not exists game_home_idx on public.game (user_id, sync_space, home_id);
create index if not exists game_away_idx on public.game (user_id, sync_space, away_id);
create index if not exists event_game_idx on public.event (user_id, sync_space, game_id, local_id);
create index if not exists event_player_idx on public.event (user_id, sync_space, player_id) where player_id is not null;
create index if not exists segment_game_sequence_idx on public.segment (user_id, sync_space, game_id, sequence);

alter table public.team enable row level security;
alter table public.player enable row level security;
alter table public.game enable row level security;
alter table public.event enable row level security;
alter table public.segment enable row level security;

revoke all on public.team, public.player, public.game, public.event, public.segment from anon;
grant select, insert, update, delete on public.team, public.player, public.game, public.event, public.segment to authenticated;

do $policies$
declare table_name text;
begin
  foreach table_name in array array['team','player','game','event','segment'] loop
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'')', 'users read own ' || table_name, table_name);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'')', 'users insert own ' || table_name, table_name);
    execute format('create policy %I on public.%I for update to authenticated using ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'') with check ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'')', 'users update own ' || table_name, table_name);
    execute format('create policy %I on public.%I for delete to authenticated using ((select auth.uid()) = user_id and sync_space = coalesce((select current_setting(''request.headers'', true)), ''{}'')::jsonb ->> ''x-sync-space'')', 'users delete own ' || table_name, table_name);
  end loop;
end
$policies$;

-- Preserve existing cloud data by copying legacy JSON snapshots into the new tables.
insert into public.team (user_id, sync_space, local_id, name, created_at)
select d.user_id, d.space, (row->>'id')::bigint, row->>'name', (row->>'created_at')::bigint
from public.sync_documents d cross join lateral jsonb_array_elements(d.payload->'teams') row
where d.user_id is not null on conflict do nothing;

insert into public.player (user_id, sync_space, local_id, team_id, name, number)
select d.user_id, d.space, (row->>'id')::bigint, (row->>'team_id')::bigint,
       coalesce(row->>'name',''), coalesce(row->>'number','')
from public.sync_documents d cross join lateral jsonb_array_elements(d.payload->'players') row
where d.user_id is not null on conflict do nothing;

insert into public.game (user_id, sync_space, local_id, title, home_id, away_id, home_score, away_score, status, scheduled_at, video_quality, period_count, period_duration_ms, current_period, clock_remaining_ms, created_at)
select d.user_id, d.space, (row->>'id')::bigint, row->>'title', (row->>'home_id')::bigint,
       (row->>'away_id')::bigint, (row->>'home_score')::integer, (row->>'away_score')::integer,
       row->>'status', coalesce((row->>'scheduled_at')::bigint, (row->>'created_at')::bigint),
       coalesce(row->>'video_quality','HIGHEST'), coalesce((row->>'period_count')::integer,4),
       coalesce((row->>'period_duration_ms')::bigint,480000), coalesce((row->>'current_period')::integer,1),
       coalesce((row->>'clock_remaining_ms')::bigint,480000), (row->>'created_at')::bigint
from public.sync_documents d cross join lateral jsonb_array_elements(d.payload->'games') row
where d.user_id is not null on conflict do nothing;

insert into public.event (user_id, sync_space, local_id, game_id, team_id, player_id, type, value, period, game_clock_ms, segment, segment_time_ms, final_video_time_ms, reverted, created_at)
select d.user_id, d.space, (row->>'id')::bigint, (row->>'game_id')::bigint, (row->>'team_id')::bigint,
       nullif(row->>'player_id','')::bigint, row->>'type', (row->>'value')::integer,
       (row->>'period')::integer, (row->>'game_clock_ms')::bigint, (row->>'segment')::integer,
       (row->>'segment_time_ms')::bigint, (row->>'final_video_time_ms')::bigint,
       coalesce((row->>'reverted')::integer,0) <> 0, (row->>'created_at')::bigint
from public.sync_documents d cross join lateral jsonb_array_elements(d.payload->'events') row
where d.user_id is not null on conflict do nothing;
