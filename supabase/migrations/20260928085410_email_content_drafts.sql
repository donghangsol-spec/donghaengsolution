-- Bounded preview of mailbox content. Only organization reviewers can read it.
create table public.email_content_drafts (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete cascade,
 message_id uuid not null unique references public.email_intake_messages(id) on delete cascade,
 status text not null check (status in ('review_required','size_limit','parse_failed')),
 text_preview text not null default '' check (length(text_preview) <= 4000),
 attachment_previews jsonb not null default '[]'::jsonb,
 truncated boolean not null default false,
 expires_at timestamptz not null default (now() + interval '30 days'),
 created_at timestamptz not null default now()
);
create index email_content_drafts_expiry_idx on public.email_content_drafts(expires_at);
create index email_content_drafts_org_idx on public.email_content_drafts(organization_id, created_at desc);
alter table public.email_content_drafts enable row level security;
revoke all on public.email_content_drafts from anon, authenticated;
grant select on public.email_content_drafts to authenticated;
create policy "reviewer reads content draft" on public.email_content_drafts for select to authenticated
 using (expires_at > now() and private.has_org_role(organization_id,array['owner','admin','reviewer']));
