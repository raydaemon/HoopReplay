-- Apple Guideline 5.1.1(v): one authenticated request permanently removes the
-- account and every row owned by it.  auth.users cascades through the FK graph.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = pg_catalog, auth, public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
