-- Worker-only server gates for confirmation verification and idempotent sandbox receipts.
-- This migration does not enable production filing or persist certificate material.

create unique index if not exists ux_insurance_filing_jobs_adapter_run_id
on public.insurance_filing_jobs(adapter_run_id)
where adapter_run_id is not null;

create unique index if not exists ux_insurance_filing_jobs_provider_receipt
on public.insurance_filing_jobs(provider, external_receipt_no)
where external_receipt_no is not null;

create or replace function public.verify_filing_confirmation_worker(
  p_job_id uuid,
  p_payload_hash text
)
returns table (
  confirmed boolean,
  job_id uuid,
  payload_hash text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'service role required';
  end if;
  if p_payload_hash !~ '^[a-f0-9]{64}$' then raise exception 'invalid payload hash'; end if;

  return query
  select true, j.id, j.preview_hash, j.confirmation_expires_at
  from public.insurance_filing_jobs j
  where j.id = p_job_id
    and j.status = 'awaiting_human_confirmation'
    and j.human_confirmed_by is not null
    and j.human_confirmed_at is not null
    and j.confirmation_expires_at > now()
    and j.credential_expires_at > now()
    and j.preview_hash = p_payload_hash;
end;
$$;

create or replace function public.record_filing_receipt_worker(
  p_job_id uuid,
  p_adapter_run_id text,
  p_receipt_no text,
  p_external_status text,
  p_payload_hash text,
  p_is_sandbox boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_job public.insurance_filing_jobs;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'service role required';
  end if;
  if p_is_sandbox is distinct from true then raise exception 'production receipt disabled'; end if;
  if p_external_status <> 'ACCEPTED' then raise exception 'accepted sandbox receipt required'; end if;
  if nullif(btrim(p_adapter_run_id), '') is null or nullif(btrim(p_receipt_no), '') is null then
    raise exception 'complete receipt required';
  end if;
  if p_payload_hash !~ '^[a-f0-9]{64}$' then raise exception 'invalid payload hash'; end if;

  select * into v_job
  from public.insurance_filing_jobs
  where id = p_job_id
  for update;

  if v_job.id is null then raise exception 'filing job not found'; end if;

  if v_job.status = 'accepted' then
    if v_job.adapter_run_id = p_adapter_run_id
       and v_job.external_receipt_no = p_receipt_no
       and v_job.receipt_payload_hash = p_payload_hash
       and v_job.receipt_is_sandbox is true then
      return jsonb_build_object('accepted', false, 'duplicate', true);
    end if;
    raise exception 'accepted filing job is immutable';
  end if;

  if v_job.status <> 'submitting' then raise exception 'submitting filing job required'; end if;
  if v_job.preview_hash is distinct from p_payload_hash then raise exception 'receipt payload hash mismatch'; end if;
  if v_job.confirmation_expires_at is null or v_job.confirmation_expires_at <= now() then
    raise exception 'human confirmation expired';
  end if;

  if exists (
    select 1 from public.insurance_filing_jobs
    where adapter_run_id = p_adapter_run_id
       or (provider = v_job.provider and external_receipt_no = p_receipt_no)
  ) then
    raise exception 'receipt already belongs to another filing job';
  end if;

  update public.insurance_filing_jobs
  set status = 'accepted',
      adapter_run_id = p_adapter_run_id,
      external_receipt_no = p_receipt_no,
      external_status = p_external_status,
      receipt_payload_hash = p_payload_hash,
      receipt_is_sandbox = true,
      credential_session_ref = null,
      credential_expires_at = null,
      updated_at = now()
  where id = p_job_id;

  return jsonb_build_object('accepted', true, 'duplicate', false);
end;
$$;

revoke all on function public.verify_filing_confirmation_worker(uuid,text) from public, anon, authenticated;
revoke all on function public.record_filing_receipt_worker(uuid,text,text,text,text,boolean) from public, anon, authenticated;
grant execute on function public.verify_filing_confirmation_worker(uuid,text) to service_role;
grant execute on function public.record_filing_receipt_worker(uuid,text,text,text,text,boolean) to service_role;

comment on function public.verify_filing_confirmation_worker(uuid,text) is
'Worker gateway only: verifies a fresh server-side human confirmation without exposing role claims.';
comment on function public.record_filing_receipt_worker(uuid,text,text,text,text,boolean) is
'Worker gateway only: atomically records one accepted sandbox receipt and reports exact replays as duplicates.';
