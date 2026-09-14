-- Certificate-backed insurance filing queue.
-- Certificate bytes and passwords MUST NOT be stored in Supabase.
-- A separately operated trusted worker receives one-time, client-encrypted credentials.

create table if not exists public.insurance_filing_jobs (
  id uuid primary key default gen_random_uuid(),
  insurance_request_id uuid not null references public.insurance_requests(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete restrict,
  provider text not null check (provider in ('4INSURE','EDI','OTHER_APPROVED_CHANNEL')),
  status text not null default 'queued'
    check (status in ('queued','claimed','awaiting_human_confirmation','submitting','accepted','rejected','failed','cancelled')),
  idempotency_key uuid not null default gen_random_uuid() unique,
  credential_session_ref text,
  credential_expires_at timestamptz,
  claimed_by text,
  claimed_at timestamptz,
  human_confirmed_by uuid references auth.users(id),
  human_confirmed_at timestamptz,
  external_receipt_no text,
  external_status text,
  error_code text,
  error_message text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (credential_session_ref is null and credential_expires_at is null)
    or (credential_session_ref is not null and credential_expires_at is not null)
  )
);

create unique index if not exists ux_insurance_filing_jobs_active_request
on public.insurance_filing_jobs(insurance_request_id)
where status in ('queued','claimed','awaiting_human_confirmation','submitting');

create index if not exists ix_insurance_filing_jobs_company_created
on public.insurance_filing_jobs(company_id, created_at desc);

alter table public.insurance_filing_jobs enable row level security;

drop policy if exists "insurance filing jobs select" on public.insurance_filing_jobs;
create policy "insurance filing jobs select"
on public.insurance_filing_jobs for select
to authenticated
using (
  exists (
    select 1 from public.companies c
    where c.id = company_id
      and private.is_org_member(c.organization_id)
  )
);

-- No direct INSERT/UPDATE/DELETE policy is intentional.
-- Users queue work through a guarded RPC; only service_role workers mutate execution state.
revoke insert, update, delete on public.insurance_filing_jobs from anon, authenticated;
grant select on public.insurance_filing_jobs to authenticated;

create or replace function public.queue_certificate_filing(
  p_request_id uuid,
  p_provider text default '4INSURE'
)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_request public.insurance_requests;
  v_org_id uuid;
  v_job_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if p_provider not in ('4INSURE','EDI','OTHER_APPROVED_CHANNEL') then
    raise exception 'unsupported filing provider';
  end if;

  select * into v_request
  from public.insurance_requests
  where id = p_request_id
  for update;

  if v_request.id is null then raise exception 'insurance request not found'; end if;

  select organization_id into v_org_id
  from public.companies
  where id = v_request.company_id;

  if not private.has_org_role(v_org_id, array['owner','admin','reviewer']) then
    raise exception 'forbidden';
  end if;

  if v_request.status <> '승인완료' or v_request.approved_by is null or v_request.approved_at is null then
    raise exception 'approved request required';
  end if;

  if exists (
    select 1 from public.insurance_filing_jobs
    where insurance_request_id = p_request_id
      and status in ('queued','claimed','awaiting_human_confirmation','submitting')
  ) then
    raise exception 'active filing job already exists';
  end if;

  insert into public.insurance_filing_jobs(
    insurance_request_id, company_id, provider, created_by
  )
  values (p_request_id, v_request.company_id, p_provider, auth.uid())
  returning id into v_job_id;

  update public.insurance_requests
  set status = '제출대기', updated_at = now()
  where id = p_request_id;

  return v_job_id;
end;
$$;

revoke all on function public.queue_certificate_filing(uuid,text) from public, anon;
grant execute on function public.queue_certificate_filing(uuid,text) to authenticated;

comment on table public.insurance_filing_jobs is
'Approved insurance filing jobs only. Never store certificate bytes, private keys, or passwords here.';
comment on column public.insurance_filing_jobs.credential_session_ref is
'Opaque, one-time reference issued by the trusted worker; never a secret or retrievable object path.';
