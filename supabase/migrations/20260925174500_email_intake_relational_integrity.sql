alter table public.email_intake_messages
  add constraint email_intake_messages_id_org_unique unique(id,organization_id);
alter table public.email_intake_attachments
  add constraint email_intake_attachments_id_org_unique unique(id,organization_id);
alter table public.document_extraction_drafts
  add constraint document_extraction_drafts_id_org_unique unique(id,organization_id);

alter table public.email_intake_attachments
  drop constraint if exists email_intake_attachments_message_id_fkey;
alter table public.email_intake_attachments
  add constraint email_intake_attachments_message_org_fkey
  foreign key(message_id,organization_id)
  references public.email_intake_messages(id,organization_id) on delete cascade;

alter table public.document_extraction_drafts
  drop constraint if exists document_extraction_drafts_attachment_id_fkey;
alter table public.document_extraction_drafts
  add constraint document_extraction_drafts_attachment_org_fkey
  foreign key(attachment_id,organization_id)
  references public.email_intake_attachments(id,organization_id) on delete cascade;

alter table public.intake_entity_matches
  drop constraint if exists intake_entity_matches_draft_id_fkey;
alter table public.intake_entity_matches
  add constraint intake_entity_matches_draft_org_fkey
  foreign key(draft_id,organization_id)
  references public.document_extraction_drafts(id,organization_id) on delete cascade;
