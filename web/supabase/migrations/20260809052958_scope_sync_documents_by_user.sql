-- A sync-space name may be reused safely because ownership is enforced by RLS.
alter table public.sync_documents
  drop constraint if exists sync_documents_pkey;

create unique index if not exists sync_documents_user_space_key
  on public.sync_documents (user_id, space);
