-- Donghaeng Solution Tax AX v0.5
-- Supabase/PostgreSQL baseline schema

create extension if not exists pgcrypto;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','reviewer','staff')),
  created_at timestamptz not null default now(),
  primary key (organization_id,user_id)
);

create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  account_type text not null default '비영리',
  company_type text not null default '장기요양기관',
  institution_code text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  external_id text,
  transaction_date date not null,
  description text not null,
  amount_in numeric(15,2) not null default 0,
  amount_out numeric(15,2) not null default 0,
  account_code text,
  account_name text,
  confidence numeric(5,4),
  status text not null default '보완요청'
    check (status in ('AI초안','검토필요','보완요청','승인완료')),
  evidence_status text not null default '미확인'
    check (evidence_status in ('미확인','증빙있음','대체확인','보완필요')),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.evidence_files (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.transactions(id) on delete cascade,
  storage_path text not null,
  original_name text not null,
  mime_type text,
  uploaded_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  company_id uuid references public.companies(id) on delete cascade,
  actor_user_id uuid references auth.users(id),
  action text not null,
  target_type text not null,
  target_id text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_companies_org on public.companies(organization_id);
create index if not exists idx_transactions_company_date on public.transactions(company_id, transaction_date desc);
create index if not exists idx_transactions_status on public.transactions(company_id, status);
create index if not exists idx_audit_org_created on public.audit_logs(organization_id, created_at desc);

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.companies enable row level security;
alter table public.transactions enable row level security;
alter table public.evidence_files enable row level security;
alter table public.audit_logs enable row level security;

create or replace function public.is_org_member(org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1
    from public.organization_members m
    where m.organization_id = org_id
      and m.user_id = auth.uid()
  );
$$;

drop policy if exists "org members read organizations" on public.organizations;
create policy "org members read organizations"
on public.organizations for select
using (public.is_org_member(id));

drop policy if exists "members read memberships" on public.organization_members;
create policy "members read memberships"
on public.organization_members for select
using (user_id = auth.uid() or public.is_org_member(organization_id));

drop policy if exists "org members manage companies" on public.companies;
create policy "org members manage companies"
on public.companies for all
using (public.is_org_member(organization_id))
with check (public.is_org_member(organization_id));

drop policy if exists "org members manage transactions" on public.transactions;
create policy "org members manage transactions"
on public.transactions for all
using (
  exists (
    select 1 from public.companies c
    where c.id = company_id and public.is_org_member(c.organization_id)
  )
)
with check (
  exists (
    select 1 from public.companies c
    where c.id = company_id and public.is_org_member(c.organization_id)
  )
);

drop policy if exists "org members manage evidence" on public.evidence_files;
create policy "org members manage evidence"
on public.evidence_files for all
using (
  exists (
    select 1
    from public.transactions t
    join public.companies c on c.id=t.company_id
    where t.id=transaction_id and public.is_org_member(c.organization_id)
  )
)
with check (
  exists (
    select 1
    from public.transactions t
    join public.companies c on c.id=t.company_id
    where t.id=transaction_id and public.is_org_member(c.organization_id)
  )
);

drop policy if exists "org members read audit" on public.audit_logs;
create policy "org members read audit"
on public.audit_logs for select
using (public.is_org_member(organization_id));

-- Intentionally no generic client INSERT/UPDATE policy on audit_logs.
-- Production writes should go through a trusted server/edge function.
