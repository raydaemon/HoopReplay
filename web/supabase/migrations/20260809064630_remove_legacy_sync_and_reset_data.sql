drop trigger if exists sync_legacy_snapshot_to_relational on public.sync_documents;
drop function if exists public.sync_legacy_snapshot_to_relational();

-- The product has not launched. Start the normalized schema with no test data.
truncate table public.events, public.segments, public.games, public.players, public.teams;

drop table if exists public.sync_documents;
