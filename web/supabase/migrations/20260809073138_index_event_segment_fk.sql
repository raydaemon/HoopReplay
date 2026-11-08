create index if not exists event_segment_fk_idx
  on public.events (user_id, sync_space, game_id, segment);
