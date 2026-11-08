alter table public.team rename to teams;
alter table public.player rename to players;
alter table public.game rename to games;
alter table public.event rename to events;
alter table public.segment rename to segments;

-- PL/pgSQL keeps its source text, so update the compatibility trigger function
-- to target the renamed tables. Constraints, policies, grants and data follow
-- table renames automatically.
do $migration$
declare
  definition text;
begin
  definition := pg_get_functiondef('public.sync_legacy_snapshot_to_relational()'::regprocedure);
  definition := replace(definition, 'public.segment', 'public.segments');
  definition := replace(definition, 'public.event', 'public.events');
  definition := replace(definition, 'public.game', 'public.games');
  definition := replace(definition, 'public.player', 'public.players');
  definition := replace(definition, 'public.team', 'public.teams');
  execute definition;
end
$migration$;
