alter table public.events drop constraint if exists event_type_check;
alter table public.events
  add constraint event_type_check check (
    type in (
      'STARTER', 'PTS_1', 'PTS_2', 'PTS_3', 'MISS_2', 'MISS_3',
      'FT_MADE', 'FT_MISS', 'REB', 'AST', 'STL', 'BLK', 'TOV',
      'FOUL', 'SUB_OUT', 'SUB_IN'
    )
  );

-- Sequence zero is the virtual segment for statistics recorded without video.
alter table public.segments drop constraint if exists segment_sequence_check;
alter table public.segments
  add constraint segment_sequence_check check (sequence >= 0);

-- Enforce the same (game, segment sequence) relationship used by SQLite.
alter table public.events drop constraint if exists event_segment_fk;
alter table public.events
  add constraint event_segment_fk
  foreign key (user_id, sync_space, game_id, segment)
  references public.segments (user_id, sync_space, game_id, sequence)
  on delete cascade;
