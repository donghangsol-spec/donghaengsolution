-- Review-only classification for signed inbound email events.
alter table public.email_intake_messages
  add column if not exists classification text not null default 'unknown'
  check (classification in ('transaction','payroll','insurance','unknown'));
