-- Enforce transaction approval on the server. Client-side role checks are UX only.

create or replace function private.guard_transaction_approval()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if old.status = '승인완료' and new is distinct from old then
    raise exception 'approved transaction is locked';
  end if;

  if new.status = '승인완료' and old.status is distinct from '승인완료' then
    if current_setting('app.transaction_approval_actor', true) is distinct from auth.uid()::text then
      raise exception 'transaction approval must use approve_transaction';
    end if;
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

drop trigger if exists trg_guard_transaction_approval on public.transactions;
create trigger trg_guard_transaction_approval
before update on public.transactions
for each row execute function private.guard_transaction_approval();

create or replace function public.approve_transaction(transaction_id uuid)
returns public.transactions
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_transaction public.transactions;
  v_org uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select t into v_transaction
  from public.transactions t
  where t.id = transaction_id
  for update;

  if v_transaction.id is null then raise exception 'transaction not found'; end if;
  select c.organization_id into v_org
  from public.companies c where c.id = v_transaction.company_id;
  if not private.has_org_role(v_org, array['owner','admin','reviewer']) then
    raise exception 'approval role required';
  end if;
  if v_transaction.status = '승인완료' then return v_transaction; end if;
  if v_transaction.account_code is null or btrim(v_transaction.account_code) = ''
     or v_transaction.account_name is null or btrim(v_transaction.account_name) = '' then
    raise exception 'classified transaction required';
  end if;

  perform set_config('app.transaction_approval_actor', auth.uid()::text, true);
  update public.transactions
  set status = '승인완료', approved_by = auth.uid(), approved_at = now()
  where id = transaction_id
  returning * into v_transaction;
  return v_transaction;
end;
$$;

revoke all on function public.approve_transaction(uuid) from public, anon;
grant execute on function public.approve_transaction(uuid) to authenticated;

create or replace function private.audit_transaction_changes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_org uuid;
  v_row public.transactions;
begin
  if tg_op = 'DELETE' then v_row := old; else v_row := new; end if;
  select organization_id into v_org from public.companies where id = v_row.company_id;
  insert into public.audit_logs(
    organization_id, company_id, actor_user_id, action, target_type, target_id, detail
  ) values (
    v_org, v_row.company_id, auth.uid(), lower(tg_op), 'transaction', v_row.id::text,
    jsonb_build_object(
      'old_status', case when tg_op = 'INSERT' then null else old.status end,
      'new_status', case when tg_op = 'DELETE' then null else new.status end,
      'account_code', case when tg_op = 'DELETE' then old.account_code else new.account_code end
    )
  );
  return v_row;
end;
$$;

revoke all on function private.audit_transaction_changes() from public, anon, authenticated;

drop trigger if exists trg_audit_transactions on public.transactions;
create trigger trg_audit_transactions
after insert or update or delete on public.transactions
for each row execute function private.audit_transaction_changes();
