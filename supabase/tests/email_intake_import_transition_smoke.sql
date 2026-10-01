begin;

do $$
begin
  if has_function_privilege('anon','public.mark_email_intake_imported(uuid)','EXECUTE') then
    raise exception 'anon can call mark_email_intake_imported';
  end if;
  if not has_function_privilege('authenticated','public.mark_email_intake_imported(uuid)','EXECUTE') then
    raise exception 'authenticated role cannot call mark_email_intake_imported';
  end if;
end $$;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_org uuid;
  v_msg uuid;
begin
  insert into auth.users(id,aud,role,email) values
    (v_owner,'authenticated','authenticated','owner@example.invalid'),
    (v_staff,'authenticated','authenticated','staff@example.invalid'),
    (v_outsider,'authenticated','authenticated','outsider@example.invalid');

  insert into public.organizations(name) values ('IMPORT TEST ORG') returning id into v_org;
  insert into public.organization_members(organization_id,user_id,role) values
    (v_org,v_owner,'owner'),
    (v_org,v_staff,'staff');

  insert into public.email_intake_messages(organization_id,provider,provider_message_id,sender,subject,processing_status,classification)
  values (v_org,'manual','msg-1','sender@example.invalid','Test','review_required','transaction')
  returning id into v_msg;

  -- outsider (not an org member) cannot import
  set local role authenticated;
  perform set_config('app.current_uid', v_outsider::text, true);
  begin
    perform public.mark_email_intake_imported(v_msg);
    raise exception 'outsider was able to mark message imported';
  exception when others then
    if sqlerrm not like '%import role required%' then raise; end if;
  end;

  -- staff (allowed role) succeeds and transitions review_required -> drafted
  perform set_config('app.current_uid', v_staff::text, true);
  perform public.mark_email_intake_imported(v_msg);
  reset role;

  if (select processing_status from public.email_intake_messages where id=v_msg) <> 'drafted' then
    raise exception 'processing_status did not transition to drafted';
  end if;

  -- second call on an already-imported message must fail (no re-import of drafted/approved state)
  set local role authenticated;
  perform set_config('app.current_uid', v_staff::text, true);
  begin
    perform public.mark_email_intake_imported(v_msg);
    raise exception 'message was imported twice';
  exception when others then
    if sqlerrm not like '%not awaiting import%' then raise; end if;
  end;
  reset role;

  raise notice 'mark_email_intake_imported smoke test passed';
end $$;

rollback;
