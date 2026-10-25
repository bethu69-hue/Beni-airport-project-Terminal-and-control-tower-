\set ON_ERROR_STOP on
do $$ declare pid uuid; n int; c int; bad int; begin
  insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000a1','pm@x') on conflict do nothing;
  insert into public.profiles(id,full_name,active,can_create_projects) values ('00000000-0000-0000-0000-0000000000a1','PM',true,true) on conflict (id) do update set can_create_projects=true, active=true;
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',false);
  perform set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-0000000000a1"}',false);
  pid := public.create_project('T','Goma');
  update public.project_members set role='project_manager' where project_id=pid;
  select count(*) into c from public.report_sections where project_id=pid and clause_ref like '4.20%';
  if c <> 9 then raise exception 'FAIL sections not 4.20: %', c; end if; raise notice 'PASS 9 report sections reference 4.20';
  n := public.load_fidic_2017_rule_proposals(pid);
  if n <> 17 then raise exception 'FAIL loaded %', n; end if; raise notice 'PASS 17 rules proposed';
  select count(*) into bad from public.deadline_rules where project_id=pid and status in ('verified','approved');
  if bad <> 0 then raise exception 'FAIL approved'; end if; raise notice 'PASS none verified/approved';
  if (select period_value from public.deadline_rules where project_id=pid and rule_code='R-004') <> 84 then raise exception 'FAIL R-004'; end if; raise notice 'PASS R-004 = 84 days';
  if public.load_fidic_2017_rule_proposals(pid) <> 0 then raise exception 'FAIL rerun overwrote'; end if; raise notice 'PASS rerun changes nothing';
  select count(*) into bad from public.deadline_rules where project_id=pid and status='not_configured';
  raise notice 'INFO % rules still not configured (need contract data)', bad;
end $$;
