alter table public.sync_documents add column if not exists user_id uuid references auth.users(id) on delete cascade;
drop policy if exists "read matching private sync space" on public.sync_documents;
drop policy if exists "insert matching private sync space" on public.sync_documents;
drop policy if exists "update matching private sync space" on public.sync_documents;
revoke all on table public.sync_documents from anon;
grant select, insert, update on table public.sync_documents to authenticated;
create policy "users read their own sync space" on public.sync_documents for select to authenticated using ((select auth.uid()) = user_id and space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space');
create policy "users create their own sync space" on public.sync_documents for insert to authenticated with check ((select auth.uid()) = user_id and space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space');
create policy "users update their own sync space" on public.sync_documents for update to authenticated using ((select auth.uid()) = user_id and space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space') with check ((select auth.uid()) = user_id and space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space');
