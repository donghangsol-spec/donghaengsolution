# Email Intake Foundation

## Goal

Turn inbound business documents into **reviewable drafts**, never automatic production filings.

```
Email -> attachment fingerprint -> document classification -> extraction draft
      -> company/employee match -> payroll/insurance draft -> human review -> commit
```

## Supported first-wave documents

- 사업자등록증 PDF/image
- 급여대장 XLS/XLSX/CSV
- 4대보험 취득·상실·보수월액변경 요청서 XLS/XLSX/PDF
- structured instructions in email body

## Security boundary (P0)

1. Attachments live in a private bucket only.
2. Access requires organization membership and server-side authorization.
3. Store source metadata and SHA-256 fingerprint; reject duplicate ingestion.
4. Apply MIME, extension and size allowlists before extraction.
5. Raw 주민/외국인등록번호 must not be copied into general tables or browser logs.
6. 공동인증서 private keys/passwords are never ingested or stored.
7. Extraction output is a draft until an authorized human approves it.
8. Every source -> extraction -> reviewer -> committed entity transition is auditable.
9. Retention/deletion policy must be approved before real customer data is enabled.

## Proposed data model

### email_intake_messages
- id, organization_id, provider, provider_message_id
- sender, subject, received_at
- processing_status
- created_at

Unique: provider + provider_message_id.

### email_intake_attachments
- id, message_id, organization_id
- original_filename, mime_type, byte_size
- sha256, storage_path
- classification
- processing_status
- created_at

Unique within organization: sha256.

### document_extraction_drafts
- id, attachment_id, organization_id
- document_type
- extracted_payload jsonb
- confidence_payload jsonb
- validation_errors jsonb
- validation_warnings jsonb
- review_status
- reviewed_by, reviewed_at
- created_at, updated_at

### intake_entity_matches
- draft_id
- company_id nullable
- employee_id nullable
- match_method
- confidence
- requires_review

## Commit rules

- 사업자등록증: propose company creation/update only.
- 급여자료: propose employee matches and a payroll import batch.
- 취득/상실 자료: propose insurance requests/details only.
- No draft may directly call an external filing adapter.
- Insurance approval and external submission remain behind the existing human-confirmation and PR #4 gates.

## First acceptance test

Using synthetic/non-customer fixtures:

1. ingest one business-registration PDF;
2. ingest one payroll workbook;
3. ingest one insurance acquisition/loss workbook;
4. classify all three;
5. group them to one synthetic company;
6. produce a review screen summary such as:
   - 사업장 1
   - 직원 12
   - 급여 12
   - 취득 2
   - 상실 1
7. approval commits only the selected drafts;
8. re-ingesting the same attachment is rejected as duplicate;
9. staff cannot approve; owner/admin/reviewer can;
10. no external filing job is created.

## Production gate

Real mailbox/customer-data ingestion remains OFF until private Storage/RLS, retention/deletion policy, cross-organization tests, audit logging, and CI security checks pass.

## Implemented review-only webhook

The Vercel POST route `/api/email-intake-webhook` verifies the raw Resend/Svix signature
and a five-minute timestamp, then retrieves the message from Resend. It accepts
only explicitly configured senders and recipients with a passing DKIM or DMARC
result. A unique provider message ID makes retries idempotent. It classifies the
subject and plain-text body as transaction, payroll, insurance, or unknown, and
stores only sender, subject, time, category and review-required state in the
organization's existing RLS-protected intake table. The accounting review tab
shows those items. Email body instructions are never executed; no ledger,
payroll, insurance, or filing row is written by this route.

`EMAIL_INTAKE_ENABLED` defaults to false. Before enabling it, configure the
Vercel server-only `RESEND_WEBHOOK_SECRET`, `RESEND_API_KEY`,
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
`EMAIL_INTAKE_ORGANIZATION_ID`, `EMAIL_INTAKE_ALLOWED_SENDERS`, and
`EMAIL_INTAKE_RECIPIENTS`; apply the classification migration; confirm
retention/deletion and mailbox authorization; then register a Resend
`email.received` webhook at the production route. Avoid changing the MX
records of an existing Naver mailbox. A deliberate forwarding rule to a
dedicated receiving address is required if Naver is the source.

Attachment parsing, employee/company matching, row-by-row preview, selective
commit and audit trail remain separate gates. Do not claim imported email
amounts or acquisition/loss requests are in the business tables until these
gates pass with synthetic fixtures and an authorized review.

## Manual collection

The accounting review tab has a separate `지금 수집` button. An authenticated
owner, admin, or reviewer can use it to inspect up to 20 messages from the
first page of the configured Resend receiving inbox. It uses the same sender,
recipient, authentication and duplicate checks as the webhook and writes only
review metadata. The count of review candidates includes already seen mail;
it is not a count of newly imported transactions. `목록 새로고침` only reloads
existing review rows. Both automatic and manual collection stay disabled until
the production gate and required server environment are configured. This
button cannot directly access the Naver mailbox or older Resend pages.
