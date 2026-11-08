-- Every HoopReplay table carries a `hoop_` prefix so the schema can share a
-- Supabase project with other products. Constraints, policies, grants, triggers
-- and the view body follow the renames automatically; only the function bodies
-- stored as text (SQL and PL/pgSQL) still name the old tables and are recreated.

alter table public.teams rename to hoop_teams;
alter table public.players rename to hoop_players;
alter table public.games rename to hoop_games;
alter table public.events rename to hoop_events;
alter table public.segments rename to hoop_segments;
alter table public.deletions rename to hoop_deletions;
alter table public.sync_revisions rename to hoop_sync_revisions;
alter table public.clubs rename to hoop_clubs;
alter table public.club_members rename to hoop_club_members;
alter table public.team_members rename to hoop_team_members;
alter table public.game_permissions rename to hoop_game_permissions;
alter table public.pdf_purchases rename to hoop_pdf_purchases;
alter table public.replay_videos rename to hoop_replay_videos;
alter table public.highlight_videos rename to hoop_highlight_videos;
alter view public.accessible_games rename to hoop_accessible_games;

create or replace function public.bump_sync_revision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  owner uuid;
  space text;
begin
  if tg_op = 'DELETE' then
    owner := old.user_id; space := old.sync_space;
  else
    owner := new.user_id; space := new.sync_space;
  end if;
  insert into public.hoop_sync_revisions as target (user_id, sync_space, revision, updated_at)
  values (owner, space, 1, now())
  on conflict (user_id, sync_space)
  do update set revision = target.revision + 1, updated_at = now();
  return null;
end;
$$;

create or replace function private.game_access_role(game_owner uuid, game_space text, requested_game bigint)
returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when (select auth.uid()) = game_owner then 'owner'
    when exists (
      select 1 from public.hoop_game_permissions permission
      where permission.owner_id = game_owner and permission.sync_space = game_space and permission.game_id = requested_game
        and permission.role = 'editor' and permission.subject_type = 'user'
        and permission.subject_email = private.request_email()
    ) then 'editor'
    when exists (
      select 1 from public.hoop_game_permissions permission
      where permission.owner_id = game_owner and permission.sync_space = game_space and permission.game_id = requested_game
        and permission.role = 'viewer' and (
          permission.subject_type = 'everyone'
          or (permission.subject_type = 'user' and permission.subject_email = private.request_email())
          or (permission.subject_type = 'club' and exists (
            select 1 from public.hoop_club_members member
            where member.club_id = permission.subject_club_id and member.member_email = private.request_email()
          ))
          or (permission.subject_type = 'team' and exists (
            select 1 from public.hoop_team_members member
            where member.owner_id = permission.owner_id and member.sync_space = permission.sync_space
              and member.team_id = permission.subject_team_id and member.member_email = private.request_email()
          ))
        )
    ) then 'viewer'
    else null
  end
$$;

notify pgrst, 'reload schema';
