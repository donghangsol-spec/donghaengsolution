create table if not exists public.inbound_email_senders (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete cascade,
 sender_pattern text not null,
 pattern_type text not null check(pattern_type in ('email','domain')),
 trust_status text not null default 'quarantine' check(trust_status in ('trusted','quarantine','blocked')),
 is_active boolean not null default true,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(sender_pattern=lower(trim(sender_pattern))),
 unique(organization_id,pattern_type,sender_pattern)
);
alter table public.inbound_email_senders enable row level security;
revoke all on public.inbound_email_senders from anon;
grant select,insert,update,delete on public.inbound_email_senders to authenticated;
drop policy if exists "inbound sender select" on public.inbound_email_senders;
create policy "inbound sender select" on public.inbound_email_senders for select to authenticated using(private.is_org_member(organization_id));
drop policy if exists "inbound sender manage" on public.inbound_email_senders;
create policy "inbound sender manage" on public.inbound_email_senders for all to authenticated using(private.has_org_role(organization_id,array['owner','admin'])) with check(private.has_org_role(organization_id,array['owner','admin']));

create or replace function public.get_inbound_sender_trust(p_organization_id uuid,p_sender text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare a text:=lower(trim(p_sender)); d text; s text;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 a=regexp_replace(a,'^.*<([^>]+)>.*$','\1');
 d=split_part(a,'@',2);
 select trust_status into s from public.inbound_email_senders
 where organization_id=p_organization_id and is_active and
 ((pattern_type='email' and sender_pattern=a) or (pattern_type='domain' and sender_pattern=d))
 order by case pattern_type when 'email' then 0 else 1 end limit 1;
 return coalesce(s,'quarantine');
end $$;
revoke all on function public.get_inbound_sender_trust(uuid,text) from public,anon,authenticated;
grant execute on function public.get_inbound_sender_trust(uuid,text) to service_role;
