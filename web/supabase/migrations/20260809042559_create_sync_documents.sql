create table if not exists public.sync_documents (
  space text primary key check (char_length(space) >= 24),
  payload jsonb not null default '{"schemaVersion":1,"updatedAt":0,"teams":[],"players":[],"games":[],"events":[]}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.sync_documents enable row level security;

revoke all on table public.sync_documents from anon, authenticated;
grant select, insert, update on table public.sync_documents to anon, authenticated;

create policy "read matching private sync space"
on public.sync_documents for select
to anon, authenticated
using (
  space = coalesce(current_setting('request.headers', true), '{}')::jsonb ->> 'x-sync-space'
);

create policy "insert matching private sync space"
on public.sync_documents for insert
to anon, authenticated
with check (
  space = coalesce(current_setting('request.headers', true), '{}')::jsonb ->> 'x-sync-space'
);

create policy "update matching private sync space"
on public.sync_documents for update
to anon, authenticated
using (
  space = coalesce(current_setting('request.headers', true), '{}')::jsonb ->> 'x-sync-space'
)
with check (
  space = coalesce(current_setting('request.headers', true), '{}')::jsonb ->> 'x-sync-space'
);
