drop policy if exists "read matching private sync space" on public.sync_documents;
drop policy if exists "insert matching private sync space" on public.sync_documents;
drop policy if exists "update matching private sync space" on public.sync_documents;

create policy "read matching private sync space"
on public.sync_documents for select to anon, authenticated
using (space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space');

create policy "insert matching private sync space"
on public.sync_documents for insert to anon, authenticated
with check (space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space');

create policy "update matching private sync space"
on public.sync_documents for update to anon, authenticated
using (space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space')
with check (space = coalesce((select current_setting('request.headers', true)), '{}')::jsonb ->> 'x-sync-space');
