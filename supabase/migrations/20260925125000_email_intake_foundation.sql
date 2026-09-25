-- Email intake foundation: review-first ingestion with organization isolation.
-- Real mailbox ingestion stays disabled until Storage/RLS and retention gates pass.

create table if not exists public.email_intake_messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  provider text not null check (provider in ('gmail','resend','manual','other')),
  provider_message_id text not null,
  sender text,
  subject text,
  received_at timestamptz,
  processing_status text not null default 'received'
    check (processing_status in ('received','classified','drafted','review_required','approved','rejected','failed')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider, provider_message_id)
);

create table if not exists public.email_intake_attachments (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.email_intake_messages(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  original_filename text not null,
  mime_type text not null,
  byte_size bigint not null check (byte_size > 0 and byte_size <= 20971520),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path text not null,
  classification text,
  processing_status text not null default 'received'
    check (processing_status in ('received','classified','extracted','review_required','approved','rejected','failed')),
  created_at timestamptz not null default now(),
  unique(organization_id, sha256),
  unique(storage_path)
);

create table if not exists public.document_extraction_drafts (
  id uuid primary key default gen_random_uuid(),
  attachment_id uuid not null references public.email_intake_attachments(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  document_type text not null
    check (document_type in ('business_registration','payroll','insurance_acquisition','insurance_loss','insurance_change','unknown')),
  extracted_payload jsonb not null default '{}'::jsonb,
  confidence_payload jsonb not null default '{}'::jsonb,
  validation_errors jsonb not null default '[]'::jsonb,
  validation_warnings jsonb not null default '[]'::jsonb,
  review_status text not null default 'draft'
    check (review_status in ('draft','review_required','approved','rejected','committed')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(attachment_id)
);

create table if not exists public.intake_entity_matches (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.document_extraction_drafts(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  company_id uuid references public.companies(id) on delete set null,
  employee_id uuid references public.employees(id) on delete set null,
  match_method text not null default 'unmatched',
  confidence numeric(5,4) check (confidence is null or (confidence >= 0 and confidence <= 1)),
  requires_review boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists idx_email_intake_messages_org_status
  on public.email_intake_messages(organization_id, processing_status, received_at desc);
create index if not exists idx_email_intake_attachments_message
  on public.email_intake_attachments(message_id);
create index if not exists idx_document_extraction_drafts_org_review
  on public.document_extraction_drafts(organization_id, review_status, created_at desc);
create index if not exists idx_intake_entity_matches_draft
  on public.intake_entity_matches(draft_id);

alter table public.email_intake_messages enable row level security;
alter table public.email_intake_attachments enable row level security;
alter table public.document_extraction_drafts enable row level security;
alter table public.intake_entity_matches enable row level security;

revoke all on public.email_intake_messages from anon;
revoke all on public.email_intake_attachments from anon;
revoke all on public.document_extraction_drafts from anon;
revoke all on public.intake_entity_matches from anon;

grant select, insert on public.email_intake_messages to authenticated;
grant select, insert on public.email_intake_attachments to authenticated;
grant select, insert, update on public.document_extraction_drafts to authenticated;
grant select, insert, update, delete on public.intake_entity_matches to authenticated;

create policy "email intake messages select" on public.email_intake_messages
for select to authenticated
using (private.is_org_member(organization_id));

create policy "email intake messages insert" on public.email_intake_messages
for insert to authenticated
with check (private.has_org_role(organization_id,array['owner','admin','reviewer','staff']));

create policy "email intake attachments select" on public.email_intake_attachments
for select to authenticated
using (private.is_org_member(organization_id));

create policy "email intake attachments insert" on public.email_intake_attachments
for insert to authenticated
with check (
  private.has_org_role(organization_id,array['owner','admin','reviewer','staff'])
  and exists (
    select 1 from public.email_intake_messages m
    where m.id=message_id and m.organization_id=email_intake_attachments.organization_id
  )
);

create policy "document extraction drafts select" on public.document_extraction_drafts
for select to authenticated
using (private.is_org_member(organization_id));

create policy "document extraction drafts insert" on public.document_extraction_drafts
for insert to authenticated
with check (
  private.has_org_role(organization_id,array['owner','admin','reviewer','staff'])
  and exists (
    select 1 from public.email_intake_attachments a
    where a.id=attachment_id and a.organization_id=document_extraction_drafts.organization_id
  )
);

create policy "document extraction drafts review" on public.document_extraction_drafts
for update to authenticated
using (private.has_org_role(organization_id,array['owner','admin','reviewer']))
with check (private.has_org_role(organization_id,array['owner','admin','reviewer']));

create policy "intake entity matches select" on public.intake_entity_matches
for select to authenticated
using (private.is_org_member(organization_id));

create policy "intake entity matches insert" on public.intake_entity_matches
for insert to authenticated
with check (
  private.has_org_role(organization_id,array['owner','admin','reviewer','staff'])
  and exists (
    select 1 from public.document_extraction_drafts d
    where d.id=draft_id and d.organization_id=intake_entity_matches.organization_id
  )
);

create policy "intake entity matches update" on public.intake_entity_matches
for update to authenticated
using (private.has_org_role(organization_id,array['owner','admin','reviewer']))
with check (private.has_org_role(organization_id,array['owner','admin','reviewer']));

create policy "intake entity matches delete" on public.intake_entity_matches
for delete to authenticated
using (private.has_org_role(organization_id,array['owner','admin','reviewer']));

-- Storage object names must begin with the organization UUID:
-- <organization_id>/<message_id>/<randomized-filename>
-- The bucket itself is provisioned separately as private with MIME/size restrictions.
create policy "email intake storage read" on storage.objects
for select to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}
);

create policy "email intake storage insert" on storage.objects
for insert to authenticated
with check (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);

create policy "email intake storage delete" on storage.objects
for delete to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.

  and private.is_org_member(((storage.foldername(name))[1])::uuid)
);

create policy "email intake storage insert" on storage.objects
for insert to authenticated
with check (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin','reviewer','staff'])
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);

create policy "email intake storage delete" on storage.objects
for delete to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin'])
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.

  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin','reviewer','staff'])
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);

create policy "email intake storage delete" on storage.objects
for delete to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin'])
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.

  and private.is_org_member(((storage.foldername(name))[1])::uuid)
);

create policy "email intake storage insert" on storage.objects
for insert to authenticated
with check (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin','reviewer','staff'])
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);

create policy "email intake storage delete" on storage.objects
for delete to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin'])
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.

  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin'])
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.

  and private.is_org_member(((storage.foldername(name))[1])::uuid)
);

create policy "email intake storage insert" on storage.objects
for insert to authenticated
with check (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin','reviewer','staff'])
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);

create policy "email intake storage delete" on storage.objects
for delete to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin'])
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.

  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin','reviewer','staff'])
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);

create policy "email intake storage delete" on storage.objects
for delete to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin'])
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.

  and private.is_org_member(((storage.foldername(name))[1])::uuid)
);

create policy "email intake storage insert" on storage.objects
for insert to authenticated
with check (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin','reviewer','staff'])
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);

create policy "email intake storage delete" on storage.objects
for delete to authenticated
using (
  bucket_id='email-intake-private'
  and (storage.foldername(name))[1] is not null
  and private.has_org_role(((storage.foldername(name))[1])::uuid,array['owner','admin'])
);


-- Provision the intake bucket as private. This is idempotent and does not make existing
-- objects public. Per-bucket limits are defense in depth; application-side validation
-- remains required before extraction.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'email-intake-private',
  'email-intake-private',
  false,
  20971520,
  array[
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Explicitly deny browser-side object mutation beyond INSERT/owner-admin DELETE.
-- No UPDATE policy is created: attachment replacement/upsert is intentionally blocked.
