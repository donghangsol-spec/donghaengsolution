create unique index if not exists uq_companies_id_org on public.companies(id,organization_id);
create unique index if not exists uq_employees_id_company on public.employees(id,company_id);

alter table public.intake_work_drafts
  drop constraint if exists intake_work_drafts_company_org_fkey,
  add constraint intake_work_drafts_company_org_fkey
    foreign key (company_id,organization_id)
    references public.companies(id,organization_id);

alter table public.intake_work_drafts
  drop constraint if exists intake_work_drafts_employee_company_fkey,
  add constraint intake_work_drafts_employee_company_fkey
    foreign key (employee_id,company_id)
    references public.employees(id,company_id);

alter table public.intake_work_drafts
  drop constraint if exists intake_work_drafts_employee_requires_company,
  add constraint intake_work_drafts_employee_requires_company
    check (employee_id is null or company_id is not null);
