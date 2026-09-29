-- The transaction table RLS already permits member updates. Keep the approval
-- RPC as invoker and use the trigger as the only status-transition gate.
create or replace function public.approve_transaction(transaction_id uuid)
returns public.transactions
language plpgsql
security invoker
set search_path = pg_catalog, public
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
  if not exists (
    select 1 from public.organization_members m
    where m.organization_id = v_org
      and m.user_id = auth.uid()
      and m.role in ('owner','admin','reviewer')
  ) then
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
