-- Keep the private identifier boundary deny-by-default even if table grants change.
-- Existing SECURITY DEFINER writer is owned by postgres and only executable by service_role.
alter table private.employee_identity_secrets enable row level security;
