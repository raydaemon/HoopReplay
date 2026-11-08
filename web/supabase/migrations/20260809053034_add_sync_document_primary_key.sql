alter table public.sync_documents
  add column if not exists id bigint generated always as identity;

alter table public.sync_documents
  add constraint sync_documents_pkey primary key (id);
