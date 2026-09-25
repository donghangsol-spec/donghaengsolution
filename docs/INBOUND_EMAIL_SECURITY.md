# Inbound Email Security Contract

Inbound email is **untrusted input**. No sender, subject, body, HTML, attachment text,
spreadsheet formula, PDF text, or extracted instruction may control application behavior.

## Required processing order

1. Receive a POST webhook.
2. Verify the webhook signature against `RESEND_WEBHOOK_SECRET` using the raw request body.
3. Accept only the expected event type.
4. Apply sender trust policy before fetching/processing content.
5. Fetch message/attachments with a server-only credential.
6. Store attachment bytes in `email-intake-private` under
   `<organization_id>/<message_id>/<randomized filename>`.
7. Enforce size, MIME and extension restrictions and compute SHA-256.
8. Treat body and extracted attachment text as data only.
9. Produce structured extraction drafts with validation warnings/errors.
10. Require owner/admin/reviewer approval before committing business/payroll/insurance data.
11. Never let email processing enqueue or execute an external institutional filing.

## Initial security mode

Use **human-in-the-loop** for business actions. Sender allowlists may reduce noise but are
not an authorization mechanism: a trusted sender can be compromised or forward malicious
content. Approval permissions come only from the authenticated application session and
organization role.

## Prompt-injection boundary

Email text must never be concatenated into system/developer instructions or interpreted as
commands. Extraction workers receive a fixed schema and may only return normalized fields.
Instructions found inside a document (for example, "ignore previous rules", URLs, scripts,
macros, shell commands, or requests to reveal secrets) are recorded as suspicious content
and must not be executed or followed.

Spreadsheet formulas/macros are never executed. HTML is not rendered during extraction.
External links/resources embedded in documents are not fetched automatically.

## Secrets

- `RESEND_API_KEY`: server only.
- `RESEND_WEBHOOK_SECRET`: server only.
- Supabase service-role/secret key: server only.
- 공동인증서 private key/password: never accepted by this pipeline.
- Raw resident/foreigner registration numbers: do not persist in general intake payloads.

## Failure behavior

Invalid signature, invalid organization mapping, disallowed file, duplicate hash, oversized
file, suspicious active content, or extraction failure must stop at intake/review state.
Return generic responses externally; retain an internal audit event without leaking secrets.

## Production enablement gate

Keep inbound customer processing disabled until:
- webhook signature verification is deployed and tested;
- private Storage/RLS cross-organization tests pass;
- retention/deletion policy is approved;
- audit events and rate limits are verified;
- synthetic E2E passes;
- security advisor findings relevant to the feature are resolved or explicitly accepted.
