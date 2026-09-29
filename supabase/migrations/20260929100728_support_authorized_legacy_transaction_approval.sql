-- Keep the already deployed client working while enforcing the same approval
-- role at the database boundary. The new client uses approve_transaction RPC.
create or replace function private.guard_transaction_approval()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  v_authorized boolean := false;
begin
  if old.status = '승인완료' and new is distinct from old then
    raise exception 'approved transaction is locked';
  end if;

  if new.status = '승인완료' and old.status is distinct from '승인완료' then
    v_authorized := current_setting('app.transaction_approval_actor', true) = auth.uid()::text;
    if not v_authorized then
      select exists (
        select 1
        from public.companies c
        join public.organization_members m on m.organization_id = c.organization_id
        where c.id = new.company_id
          and m.user_id = auth.uid()
          and m.role in ('owner','admin','reviewer')
      ) into v_authorized;
    end if;
    if not v_authorized then raise exception 'approval role required'; end if;
    if new.account_code is null or btrim(new.account_code) = ''
       or new.account_name is null or btrim(new.account_name) = '' then
      raise exception 'classified transaction required';
    end if;
    if new.approved_by is distinct from auth.uid() or new.approved_at is null then
      raise exception 'invalid transaction approval metadata';
    end if;
  elsif new.status <> '승인완료' then
    new.approved_by := null;
    new.approved_at := null;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.guard_transaction_approval() from public, anon, authenticated;
