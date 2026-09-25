alter table public.intake_work_drafts add column if not exists committed_by uuid references auth.users(id);

create or replace function public.authorize_intake_work_commit(p_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = public, private, pg_temp
as $fn$
declare v_org uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select organization_id into v_org from public.intake_work_drafts
   where id=p_id and status='approved' and reviewed_by is not null and reviewed_at is not null;
  if v_org is null then return false; end if;
  if not private.has_org_role(v_org,array['owner','admin','reviewer']) then raise exception 'forbidden'; end if;
  return true;
end
$fn$;
revoke all on function public.authorize_intake_work_commit(uuid) from public, anon;
grant execute on function public.authorize_intake_work_commit(uuid) to authenticated;

create or replace function public.commit_intake_work_draft(p_id uuid, p_actor_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, private, pg_temp
as $fn$
declare w public.intake_work_drafts%rowtype; v_entity uuid;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 select * into w from public.intake_work_drafts where id=p_id for update;
 if not found or w.status<>'approved' or w.reviewed_by is null or w.reviewed_at is null then raise exception 'approval required'; end if;
 if w.committed_entity_id is not null then return w.committed_entity_id; end if;
 if p_actor_id is null or not private.has_org_role_for_user(w.organization_id,p_actor_id,array['owner','admin','reviewer']) then raise exception 'actor forbidden'; end if;
 raise exception 'replacement requires existing commit body migration before activation';
end
$fn$;
revoke all on function public.commit_intake_work_draft(uuid,uuid) from public,anon,authenticated;
grant execute on function public.commit_intake_work_draft(uuid,uuid) to service_role;