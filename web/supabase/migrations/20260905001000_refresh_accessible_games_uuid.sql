-- PostgreSQL expands `game.*` when a view is created. Recreate the view after
-- adding games.uuid_id so PostgREST returns the UUID to Web clients.

drop view if exists public.accessible_games;

create view public.accessible_games
with (security_invoker = true)
as
select game.*, private.game_access_role(game.user_id, game.sync_space, game.local_id) as access_role
from public.games game;

revoke all on public.accessible_games from anon;
grant select on public.accessible_games to authenticated;
