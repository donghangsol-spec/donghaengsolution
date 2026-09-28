create table if not exists public.intake_work_drafts(
 id uuid primary key default gen_random_uuid(),
 extraction_draft_id uuid not null,
 organization_id uuid not null,
 company_id uuid,
 employee_id uuid,
 work_type text not null check(work_type in ('payroll','insurance_acquisition','insurance_loss','insurance_change')),
 proposed_payload jsonb not null default '{}'::jsonb,
 status text not null default 'review_required' check(status in ('review_required','approved','rejected','committed')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(extraction_draft_id,work_type),
 foreign key(extraction_draft_id,organization_id) references public.document_extraction_drafts(id,organization_id) on delete cascade
);
alter table public.intake_work_drafts enable row level security;
create policy "intake work draft select" on public.intake_work_drafts for select to authenticated using(private.is_org_member(organization_id));
create policy "intake work draft review update" on public.intake_work_drafts for update to authenticated using(private.has_org_role(organization_id,array['owner','admin','reviewer'])) with check(private.has_org_role(organization_id,array['owner','admin','reviewer']));
revoke insert,delete on public.intake_work_drafts from anon,authenticated;

create or replace function public.create_intake_work_draft(p_draft_id uuid,p_organization_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.document_extraction_drafts; m public.intake_entity_matches; v_type text; v_id uuid;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 select * into d from public.document_extraction_drafts where id=p_draft_id and organization_id=p_organization_id;
 if d.id is null then raise exception 'draft organization mismatch'; end if;
 select * into m from public.intake_entity_matches where draft_id=d.id and organization_id=p_organization_id;
 if m.id is null or m.company_id is null then raise exception 'reviewable company match required'; end if;
 v_type=case d.document_type when 'payroll' then 'payroll' when 'insurance_acquisition' then 'insurance_acquisition' when 'insurance_loss' then 'insurance_loss' when 'insurance_change' then 'insurance_change' else null end;
 if v_type is null then raise exception 'document type does not create work draft'; end if;
 insert into public.intake_work_drafts(extraction_draft_id,organization_id,company_id,employee_id,work_type,proposed_payload,status)
 values(d.id,p_organization_id,m.company_id,m.employee_id,v_type,d.extracted_payload,'review_required')
 on conflict(extraction_draft_id,work_type) do update set company_id=excluded.company_id,employee_id=excluded.employee_id,proposed_payload=excluded.proposed_payload,status='review_required',updated_at=now()
 returning id into v_id;
 return v_id;
end $$;
revoke all on function public.create_intake_work_draft(uuid,uuid) from public,anon,authenticated;
grant execute on function public.create_intake_work_draft(uuid,uuid) to service_role;
