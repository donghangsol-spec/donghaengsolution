-- Keep validation RPCs from changing finalized workflows.  The existing
-- table triggers remain a second line of defense for payroll and details.
do $migration$
declare
  v_definition text;
  v_before text;
  v_after text;
begin
  select pg_get_functiondef('public.validate_insurance_request(uuid)'::regprocedure)
    into v_definition;
  v_before := 'if r.id is null then return jsonb_build_array(''요청을 찾을 수 없습니다.''); end if;';
  if strpos(v_definition, v_before) = 0 then
    raise exception 'unexpected validate_insurance_request definition';
  end if;
  v_after := v_before || E'\n  if r.status in (''승인완료'',''제출대기'',''접수완료'',''처리완료'',''반려'',''취소'') then\n    raise exception ''finalized insurance request cannot be revalidated'';\n  end if;';
  execute replace(v_definition, v_before, v_after);

  select pg_get_functiondef('public.validate_payroll_period(uuid)'::regprocedure)
    into v_definition;
  v_before := 'if v_period.id is null then return jsonb_build_array(''급여대장을 찾을 수 없습니다.''); end if;';
  if strpos(v_definition, v_before) = 0 then
    raise exception 'unexpected validate_payroll_period definition';
  end if;
  v_after := v_before || E'\n  if v_period.status in (''확정'',''신고반영'') then\n    raise exception ''confirmed payroll period cannot be revalidated'';\n  end if;';
  execute replace(v_definition, v_before, v_after);
end;
$migration$;
