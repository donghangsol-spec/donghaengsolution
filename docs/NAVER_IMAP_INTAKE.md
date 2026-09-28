# Naver IMAP intake

The accounting review queue can collect from the signed-in organization's Naver inbox. `지금 수집` runs an authenticated owner/admin/reviewer request, and the Vercel cron calls the same collector once daily (00:00 UTC). The first 20 most recent INBOX messages dated within 30 days are examined each run. More history requires a separate bounded backfill.

The collector requires an exact sender allowlist and reads IMAP envelope plus MIME structure. It uses subject and attachment filenames for classification. It stores sender, subject, received time, classification and review status in `email_intake_messages`. It also stores bounded body and tabular previews in `email_content_drafts`; it never stores raw MIME or attachment bytes, and never creates transactions, payroll, insurance requests or official filings. A sender address in a message remains unverified despite IMAP mailbox authentication; a reviewer must verify evidence before approval.

Production server-only variables: `NAVER_IMAP_ENABLED=true`, `NAVER_IMAP_USER=donghangsol@naver.com`, `NAVER_IMAP_APP_PASSWORD` (Naver app password, not account password), `EMAIL_INTAKE_ORGANIZATION_ID`, `EMAIL_INTAKE_ALLOWED_SENDERS`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`. Set these on the Vercel project serving the accounting app; never place secrets in browser config or repository. Leave the feature off until all are present. Naver requires 2FA and a separate application password. Test an allowed business message and an unrelated message, inspect the queue, then turn on the feature.

The `provider='other'` ID contains organization ID, mailbox UIDVALIDITY and UID, allowing repeat runs to ignore duplicates. A cron failure is logged with a generic public error. The Resend webhook remains separate and disabled unless configured independently.

## Content preview

For allowlisted senders, messages up to 6 MiB are parsed after the metadata save. The preview stores at most 4,000 body characters and five attachment previews. CSV/XLSX previews are limited to 100 rows, 20 cells per row, and 200 characters per cell; each attachment must be 3 MiB or less. Legacy `.xls`, PDF and images remain marked unsupported for tabular extraction. Parsing failures and size limits are shown explicitly. Raw MIME and attachment bytes are not stored. Reviewers should compare the preview with the original email before any business action.

`email_content_drafts` has organization-scoped read access only for owner/admin/reviewer. Previews expire after 30 days and the daily cron deletes expired rows. A paused collector will not perform cleanup; an operator should run retention maintenance if disabled for more than 30 days. The migration must be applied before enabling `NAVER_IMAP_ENABLED`; otherwise collection fails rather than silently discarding content.
