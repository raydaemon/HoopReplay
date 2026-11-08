create or replace function public.sync_legacy_snapshot_to_relational()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  insert into public.team (user_id, sync_space, local_id, name, created_at)
  select new.user_id, new.space, (row->>'id')::bigint, row->>'name', (row->>'created_at')::bigint
  from jsonb_array_elements(coalesce(new.payload->'teams', '[]'::jsonb)) row
  on conflict (user_id, sync_space, local_id) do update
    set name = excluded.name, created_at = excluded.created_at;

  insert into public.player (user_id, sync_space, local_id, team_id, name, number)
  select new.user_id, new.space, (row->>'id')::bigint, (row->>'team_id')::bigint,
         coalesce(row->>'name',''), coalesce(row->>'number','')
  from jsonb_array_elements(coalesce(new.payload->'players', '[]'::jsonb)) row
  on conflict (user_id, sync_space, local_id) do update
    set team_id = excluded.team_id, name = excluded.name, number = excluded.number;

  insert into public.game (user_id, sync_space, local_id, title, home_id, away_id, home_score, away_score, status, scheduled_at, video_quality, period_count, period_duration_ms, current_period, clock_remaining_ms, created_at)
  select new.user_id, new.space, (row->>'id')::bigint, row->>'title', (row->>'home_id')::bigint,
         (row->>'away_id')::bigint, (row->>'home_score')::integer, (row->>'away_score')::integer,
         row->>'status', coalesce((row->>'scheduled_at')::bigint, (row->>'created_at')::bigint),
         coalesce(row->>'video_quality','HIGHEST'), coalesce((row->>'period_count')::integer,4),
         coalesce((row->>'period_duration_ms')::bigint,480000), coalesce((row->>'current_period')::integer,1),
         coalesce((row->>'clock_remaining_ms')::bigint,480000), (row->>'created_at')::bigint
  from jsonb_array_elements(coalesce(new.payload->'games', '[]'::jsonb)) row
  on conflict (user_id, sync_space, local_id) do update set
    title = excluded.title, home_id = excluded.home_id, away_id = excluded.away_id,
    home_score = excluded.home_score, away_score = excluded.away_score, status = excluded.status,
    scheduled_at = excluded.scheduled_at, video_quality = excluded.video_quality,
    period_count = excluded.period_count, period_duration_ms = excluded.period_duration_ms,
    current_period = excluded.current_period, clock_remaining_ms = excluded.clock_remaining_ms,
    created_at = excluded.created_at;

  insert into public.event (user_id, sync_space, local_id, game_id, team_id, player_id, type, value, period, game_clock_ms, segment, segment_time_ms, final_video_time_ms, reverted, created_at)
  select new.user_id, new.space, (row->>'id')::bigint, (row->>'game_id')::bigint, (row->>'team_id')::bigint,
         nullif(row->>'player_id','')::bigint, row->>'type', (row->>'value')::integer,
         (row->>'period')::integer, (row->>'game_clock_ms')::bigint, (row->>'segment')::integer,
         (row->>'segment_time_ms')::bigint, (row->>'final_video_time_ms')::bigint,
         coalesce((row->>'reverted')::integer,0) <> 0, (row->>'created_at')::bigint
  from jsonb_array_elements(coalesce(new.payload->'events', '[]'::jsonb)) row
  on conflict (user_id, sync_space, local_id) do update set
    game_id = excluded.game_id, team_id = excluded.team_id, player_id = excluded.player_id,
    type = excluded.type, value = excluded.value, period = excluded.period,
    game_clock_ms = excluded.game_clock_ms, segment = excluded.segment,
    segment_time_ms = excluded.segment_time_ms, final_video_time_ms = excluded.final_video_time_ms,
    reverted = excluded.reverted, created_at = excluded.created_at;

  return new;
end
$function$;

revoke all on function public.sync_legacy_snapshot_to_relational() from public, anon, authenticated;

drop trigger if exists sync_legacy_snapshot_to_relational on public.sync_documents;
create trigger sync_legacy_snapshot_to_relational
after insert or update of payload on public.sync_documents
for each row execute function public.sync_legacy_snapshot_to_relational();
