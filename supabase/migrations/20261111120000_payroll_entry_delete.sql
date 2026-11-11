-- 급여대장 항목(직원별 한 줄) 삭제 허용.
-- 기존에는 select/insert/update 정책만 있어 삭제가 막혀 있었다.
-- 확정·신고반영된 급여대장은 기존 trg_guard_confirmed_payroll_entries 트리거가
-- 삭제까지 차단하므로 여기서는 수정 권한과 같은 역할에만 허용한다.
drop policy if exists "payroll entries delete" on public.payroll_entries;
create policy "payroll entries delete" on public.payroll_entries for delete
using (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));
