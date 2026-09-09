# Security baseline — Donghaeng Tax AX

## Data policy
- Do not store 공동인증서 원본 or passwords in the application database.
- Do not put service-role keys in browser JavaScript.
- Bank, payroll and employee data must be organization/company scoped.
- Final accounting classification and filing preparation require a human approval step.

## Access model
Roles: owner / admin / reviewer / staff.

RLS is mandatory on organization, company, transaction, evidence and audit data.
Audit-log writes should be performed by trusted server/edge code, not arbitrary browser clients.

## Before real client data
1. Supabase Auth enabled.
2. RLS policies tested with at least two separate organizations.
3. Private Storage bucket for evidence files.
4. Vercel environment variables configured.
5. Server-side audit write function deployed.
6. Backup/restore procedure tested.
7. Privacy/retention policy documented.
8. No real bank credentials or certificate passwords stored.
