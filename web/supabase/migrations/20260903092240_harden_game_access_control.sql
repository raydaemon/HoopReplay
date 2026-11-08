create index if not exists game_permissions_subject_club_idx
  on public.game_permissions (subject_club_id)
  where subject_club_id is not null;

drop policy if exists "owners manage club memberships" on public.club_members;
create policy "owners insert club memberships" on public.club_members for insert to authenticated
  with check (exists (select 1 from public.clubs club where club.id = club_id and club.owner_id = (select auth.uid())));
create policy "owners update club memberships" on public.club_members for update to authenticated
  using (exists (select 1 from public.clubs club where club.id = club_id and club.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.clubs club where club.id = club_id and club.owner_id = (select auth.uid())));
create policy "owners delete club memberships" on public.club_members for delete to authenticated
  using (exists (select 1 from public.clubs club where club.id = club_id and club.owner_id = (select auth.uid())));

drop policy if exists "owners manage team memberships" on public.team_members;
create policy "owners insert team memberships" on public.team_members for insert to authenticated
  with check ((select auth.uid()) = owner_id);
create policy "owners update team memberships" on public.team_members for update to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "owners delete team memberships" on public.team_members for delete to authenticated
  using ((select auth.uid()) = owner_id);

drop policy if exists "owners manage game permissions" on public.game_permissions;
create policy "owners insert game permissions" on public.game_permissions for insert to authenticated
  with check ((select auth.uid()) = owner_id);
create policy "owners update game permissions" on public.game_permissions for update to authenticated
  using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "owners delete game permissions" on public.game_permissions for delete to authenticated
  using ((select auth.uid()) = owner_id);

revoke execute on function public.bump_sync_revision() from public, anon, authenticated;
