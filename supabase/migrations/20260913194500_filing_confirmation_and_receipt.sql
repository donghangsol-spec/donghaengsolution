-- Server-enforced human confirmation and receipt validation for certificate-- certificate trusted-worker filing filing filing filing jobsying.
-- Certificate/private-key/password material must never be persisted in Supabase.

alter table public.insurance_filing_jobs
  add column if not exists preview_hash text,
  add column if not exists preview_created_at timestamptz,
  add column if not exists confirmation_expires_at timestamptz,
  add column if not exists adapter_run_id text,
  add column if not exists receipt_payload_hash text,
  add column if not exists receipt_is_sandbox boolean;

alter table public.insurance_filing_jobs
  drop constraint if exists insurance_filing_jobs_preview_hash_format;
alter table public.insurance_filing_jobs
  add constraint insurance_filing_jobs_preview_hash_format
  check (preview_hash is null or preview_hash ~ '^[a-f0-9]{64}$');

create or replace function private.guard_insurance_filing_job_transition()
returns trigger
language plpgsql
security invoker
set search_path = public, private
as $$
begin
  if new.status in ('submitting','accepted') then
    if new.human_confirmed_by is null or new.human_confirmed_at is null then
      raise exception 'human confirmation required';
    end if;
    if new.confirmation_expires_at is null or new.confirmation_expires_at <= now() then
      raise exception 'human confirmation expired';
    end if;
    if new.preview_hash is null then
      raise exception 'validated preview required';
    end if;
  end if;

  if new.status = 'accepted' then
    if nullif(btrim(new.external_receipt_no),'') is null then
      raise exception 'validated receipt number required';
    end if;
    if nullif(btrim(new.adapter_run_id),'') is null then
      raise exception 'adapter run id required';
    end if;
    if new.receipt_payload_hash is distinct from new.preview_hash then
      raise exception 'receipt payload hash mismatch';
    end if;
    if new.receipt_is_sandbox is null then
      raise exception 'receipt environment required';
    end if;
  end if;

  if old.status in ('accepted','rejected','cancelled')
     and new.status is distinct from old.status then
    raise exception 'terminal filing job is immutable';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_insurance_filing_job_transition
on public.insurance_filing_jobs;
create trigger trg_guard_insurance_filing_job_transition
before update on public.insurance_filing_jobs
for each row execute function private.guard_insurance_filing_job_transition();

create or replace function public.confirm_certificate_filing(
  p_job_id uuid,
  p_preview_hash text
)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_job public.insurance_filing_jobs;
  v_org_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if p_preview_hash !~ '^[a-f0-9]{64}$' then raise exception 'invalid preview hash'; end if;

  select * into v_job
  from public.insurance_filing_jobs
  where id = p_job_id
  for update;

  if v_job.id is null then raise exception 'filing job not found'; end if;

  select organization_id into v_org_id
  from public.companies
  where id = v_job.company_id;

  if not private.has_org_role(v_org_id, array['owner','admin','reviewer']) then
    raise exception 'confirmation role required';
  end if;
  if v_job.status <> 'awaiting_human_confirmation' then
    raise exception 'job is not awaiting human confirmation';
  end if;
  if v_job.preview_hash is distinct from p_preview_hash then
    raise exception 'preview changed; review again';
  end if;
  if v_job.credential_expires_at is null or v_job.credential_expires_at <= now() then
    raise exception 'credential session expired';
  end if;

  update public.insurance_filing_jobs
  set human_confirmed_by = auth.uid(),
      human_confirmed_at = now(),
      confirmation_expires_at = least(v_job.credential_expires_at, now() + interval '5 minutes'),
      updated_at = now()
  where id = p_job_id;
end;
$$;

revoke all on function public.confirm_certificate_filing(uuid,text) from public, anon;
grant execute on function public.confirm_certificate_filing(uuid,text) to authenticated;

create or replace function private.record_filing_receipt(
  p_job_id uuid,
  p_adapter_run_id text,
  p_receipt_no text,
  p_external_status text,
  p_payload_hash text,
  p_is_sandbox boolean
)
returns void
language plpgsql
security invoker
set search_path = public, private
as $$
begin
  if current_user <> 'service_role' then
    raise exception 'service role required';
  end if;

  update public.insurance_filing_jobs
  set status = 'accepted',
      adapter_run_id = nullif(btrim(p_adapter_run_id),''),
      external_receipt_no = nullif(btrim(p_receipt_no),''),
      external_status = nullif(btrim(p_external_status),''),
      receipt_payload_hash = p_payload_hash,
      receipt_is_sandbox = p_is_sandbox,
      credential_session_ref = null,
      credential_expires_at = null,
      updated_at = now()
  where id = p_job_id
    and status = 'submitting';

  if not found then raise exception 'submitting filing job not found'; end if;
end;
$$;

revoke all on function private.record_filing_receipt(uuid,text,text,text,text,boolean)
from public, anon, authenticated;
grant execute on function private.record_filing_receipt(uuid,text,text,text,text,boolean)
to service_role;

comment on function public.confirm_certificate_filing(uuid,text) is
'Records a short-lived owner/admin/reviewer confirmation bound to one immutable preview hash.';
comment on function private.record_filing_receipt(uuid,text,text,text,text,boolean) is
'Trusted-worker-only receipt transition. Receipt payload hash must match the confirmed preview.';
