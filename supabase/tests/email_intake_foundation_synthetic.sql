-- Synthetic verification for email intake foundation.
-- Run only in a disposable/test transaction after the migration is applied.
-- This script does not use real customer data and rolls back all fixtures.

begin;

do $$
declare
  v_org uuid := gen_random_uuid();
  v_msg uuid;
  v_att uuid;
  v_draft uuid;
begin
  -- Schema constraints: provider/message id uniqueness and attachment hash uniqueness.
  insert into public.organizations(id,name)
  values(v_org,'SYNTHETIC EMAIL INTAKE TEST');

  insert into public.email_intake_messages(organization_id,provider,provider_message_id,sender,subject)
  values(v_org,'manual','synthetic-message-001','fixture@example.invalid','synthetic fixture')
  returning id into v_msg;

  insert into public.email_intake_attachments(
    message_id,organization_id,original_filename,mime_type,byte_size,sha256,storage_path
  ) values (
    v_msg,v_org,'fixture.xlsx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    1024,repeat('a',64),v_org::text||'/'||v_msg::text||'/fixture.xlsx'
  ) returning id into v_att;

  insert into public.document_extraction_drafts(
    attachment_id,organization_id,document_type,extracted_payload,review_status
  ) values (
    v_att,v_org,'insurance_acquisition',
    '{"synthetic":true,"employees":12,"acquisition":2,"loss":1}'::jsonb,
    'review_required'
  ) returning id into v_draft;

  if not exists (
    select 1 from public.document_extraction_drafts
    where id=v_draft and extracted_payload->>'synthetic'='true'
  ) then
    raise exception 'synthetic draft creation failed';
  end if;

  begin
    insert into public.email_intake_attachments(
      message_id,organization_id,original_filename,mime_type,byte_size,sha256,storage_path
    ) values (
      v_msg,v_org,'duplicate.xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      1024,repeat('a',64),v_org::text||'/'||v_msg::text||'/duplicate.xlsx'
    );
    raise exception 'duplicate SHA-256 was not rejected';
  exception when unique_violation then
    null;
  end;

  begin
    insert into public.email_intake_attachments(
      message_id,organization_id,original_filename,mime_type,byte_size,sha256,storage_path
    ) values (
      v_msg,v_org,'oversize.xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      20971521,repeat('b',64),v_org::text||'/'||v_msg::text||'/oversize.xlsx'
    );
    raise exception 'oversize attachment was not rejected';
  exception when check_violation then
    null;
  end;
end $$;

rollback;

-- RLS verification is performed separately with authenticated test identities because
-- private.is_org_member/private.has_org_role depend on auth.uid(). Required assertions:
-- 1) member can SELECT own-org intake rows;
-- 2) member cannot SELECT another org's rows;
-- 3) staff can INSERT intake/draft rows but cannot UPDATE review state;
-- 4) owner/admin/reviewer can UPDATE review state;
-- 5) only owner/admin can DELETE Storage objects;
-- 6) no role can UPDATE/overwrite Storage objects because no UPDATE policy exists.
