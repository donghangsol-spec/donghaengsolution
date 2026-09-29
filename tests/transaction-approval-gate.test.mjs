import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../accounting.html', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/20260929095405_harden_transaction_approval.sql', import.meta.url), 'utf8');
const invokerMigration = readFileSync(new URL('../supabase/migrations/20260929095714_make_transaction_approval_invoker.sql', import.meta.url), 'utf8');
const compatibilityMigration = readFileSync(new URL('../supabase/migrations/20260929100728_support_authorized_legacy_transaction_approval.sql', import.meta.url), 'utf8');

assert.match(html, /sb\.rpc\('approve_transaction',\{transaction_id:x\.dbid\}\)/);
assert.doesNotMatch(html, /from\('transactions'\)\.update\(\{status:'승인완료'/);
assert.match(html, /if\(!canApproveWorkflow\(\)\)return alert\('거래 승인 권한이 없습니다\.'/);

assert.match(migration, /create or replace function public\.approve_transaction/);
assert.match(migration, /private\.has_org_role\(v_org, array\['owner','admin','reviewer'\]\)/);
assert.match(migration, /transaction approval must use approve_transaction/);
assert.match(migration, /approved transaction is locked/);
assert.match(migration, /create trigger trg_audit_transactions/);
assert.match(migration, /grant execute on function public\.approve_transaction\(uuid\) to authenticated/);
assert.match(invokerMigration, /security invoker/);
assert.match(invokerMigration, /m\.role in \('owner','admin','reviewer'\)/);
assert.doesNotMatch(invokerMigration, /security definer/);
assert.match(compatibilityMigration, /m\.role in \('owner','admin','reviewer'\)/);
assert.match(compatibilityMigration, /invalid transaction approval metadata/);
assert.match(compatibilityMigration, /approved transaction is locked/);

console.log('Transaction approval is RPC-only, role-gated, immutable, and audited.');
