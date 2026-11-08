create index if not exists event_team_idx
  on public.event (user_id, sync_space, team_id);
