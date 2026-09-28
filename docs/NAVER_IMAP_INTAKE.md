# Naver IMAP intake

The accounting review queue can collect from the signed-in organization's Naver inbox. `지금 수집` runs an authenticated owner/admin/reviewer request, and the Vercel cron calls the same collector once daily (00:00 UTC). The first 20 most recent INBOX messages dated within 30 days are examined each run. More history requires a separate bounded backfill.

The collector requires an exact sender allowlist and reads IMAP envelope plus MIME structure. It uses subject and attachment filenames for classification. It stores only sender, subject, received time, classification and review status in `email_intake_messages`; it does not persist body or attachment bytes and never creates transactions, payroll, insurance requests or official filings. A sender address in a message remains unverified despite IMAP mailbox authentication; a reviewer must verify evidence before approval.

Production server-only variables: `NAVER_IMAP_ENABLED=true`, `NAVER_IMAP_USER=donghangsol@naver.com`, `NAVER_IMAP_APP_PASSWORD` (Naver app password, not account password), `EMAIL_INTAKE_ORGANIZATION_ID`, `EMAIL_INTAKE_ALLOWED_SENDERS`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`. Set these on the Vercel project serving the accounting app; never place secrets in browser config or repository. Leave the feature off until all are present. Naver requires 2FA and a separate application password. Test an allowed business message and an unrelated message, inspect the queue, then turn on the feature.

The `provider='other'` ID contains organization ID, mailbox UIDVALIDITY and UID, allowing repeat runs to ignore duplicates. A cron failure is logged with a generic public error. The Resend webhook remains separate and disabled unless configured independently.
