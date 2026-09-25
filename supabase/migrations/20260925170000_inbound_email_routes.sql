create table if not exists public.inbound_email_routes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  local_part text not null,
  domain text not null default 'donghangsolution.co.kr',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint inbound_email_routes_local_part_check check (local_part ~ '^[a-z0-9][a-z0-9._+-]{0,63}$'),
  constraint inbound_email_routes_domain_check check (domain = lower(domain))
);
create unique index if not exists inbound_email_routes_address_uidx
  on public.inbound_email_routes (lower(local_part), lower(domain))
  where is_active;
alter table public.inbound_email_routes enable row level security;
revoke all on public.inbound_email_routes from anon;
grant select, insert, update, delete on public.inbound_email_routes to authenticated;
drop policy if exists "inbound routes select" on public.inbound_email_routes;
create policy "inbound routes select" on public.inbound_email_routes for select to authenticated
using (private.is_org_member(organization_id));
drop policy if exists "inbound routes manage" on public.inbound_email_routes;
create policy "inbound routes manage" on public.inbound_email_routes for all to authenticated
using (private.has_org_role(organization_id, array['owner','admin']))
with check (private.has_org_role(organization_id, array['owner','admin']));
