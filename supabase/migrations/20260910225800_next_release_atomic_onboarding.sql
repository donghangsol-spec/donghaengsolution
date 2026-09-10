create or replace function public.onboard_owner_internal(p_user_id uuid,p_org_name text)
returns jsonb
language plpgsql
security definer
set search_path=public,private
as $$
declare v_org uuid; v_role text; v_name text;
begin
  if p_user_id is null then raise exception 'user id required'; end if;
  if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'user not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
  select organization_id,role into v_org,v_role from public.organization_members where user_id=p_user_id order by organization_id limit 1;
  if v_org is not null then return jsonb_build_object('organization_id',v_org,'role',v_role,'created',false); end if;
  v_name:=left(coalesce(nullif(btrim(p_org_name),''),'동행솔루션'),80);
  insert into public.organizations(name) values(v_name) returning id into v_org;
  insert into public.organization_members(organization_id,user_id,role) values(v_org,p_user_id,'owner');
  insert into public.audit_logs(organization_id,actor_user_id,action,target_type,target_id,detail)
  values(v_org,p_user_id,'ORGANIZATION_CREATED','organization',v_org::text,jsonb_build_object('source','atomic-onboarding'));
  return jsonb_build_object('organization_id',v_org,'role','owner','created',true);
end $$;
revoke all on function public.onboard_owner_internal(uuid,text) from public,anon,authenticated;
grant execute on function public.onboard_owner_internal(uuid,text) to service_role;