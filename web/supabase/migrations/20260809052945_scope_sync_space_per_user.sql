alter table public.sync_documents drop constraint if exists sync_documents_pkey;
alter table public.sync_documents add column if not exists id bigint generated always as identity;
alter table public.sync_documents add constraint sync_documents_pkey primary key (id);
alter table public.sync_documents add constraint sync_documents_user_space_key unique (user_id, space);
