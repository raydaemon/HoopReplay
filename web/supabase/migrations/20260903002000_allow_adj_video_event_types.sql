-- The clients also write ADJ (manual score adjustments), FOUL_DRAWN, and — since the V3
-- recording workflow — one VIDEO event per finished recording file. Sync uploads were
-- rejected with 23514 because event_type_check did not know these types.
alter table public.events drop constraint if exists event_type_check;
alter table public.events
  add constraint event_type_check check (
    type in (
      'STARTER', 'PTS_1', 'PTS_2', 'PTS_3', 'MISS_2', 'MISS_3',
      'FT_MADE', 'FT_MISS', 'REB', 'AST', 'STL', 'BLK', 'TOV',
      'FOUL', 'FOUL_DRAWN', 'SUB_OUT', 'SUB_IN', 'ADJ', 'VIDEO'
    )
  );
