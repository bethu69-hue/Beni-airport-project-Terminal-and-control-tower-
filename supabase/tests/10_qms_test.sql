\set ON_ERROR_STOP off
create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise notice 'FAIL (should have been blocked): %', label;
exception when others then raise notice 'PASS blocked: % -> %', label, sqlerrm; end $$;
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','pm@x'),('22222222-2222-2222-2222-222222222222','site@x'),('33333333-3333-3333-3333-333333333333','out@x');
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
select public.create_project('Test','Beni') as pid \gset
reset role;
insert into project_members values (:'pid','22222222-2222-2222-2222-222222222222','site_engineer');
insert into project_members values (:'pid','11111111-1111-1111-1111-111111111111','project_manager');
set role authenticated;
select count(*) as kpis_seeded, count(target) as targets_set from quality_kpis;
insert into employer_requirements(project_id,title,requirement_text,priority,verification_methods) values (:'pid','Terminal roof','Roof shall resist X','critical','{test}');
select ref,status from employer_requirements;
select pg_temp.expect_fail($q$update employer_requirements set status='active' where true$q$ ,'x') ; -- may pass for PM
select status from employer_requirements;
select pg_temp.expect_fail($q$update employer_requirements set requirement_text='changed'$q$,'edit active ER');
select public.supersede_requirement((select id from employer_requirements where status='active'),'Roof shall resist Y','Variation 3 changes load');
select ref,version,status from employer_requirements order by version;
select pg_temp.expect_fail($q$insert into er_verifications(requirement_id,result) select id,'compliant' from employer_requirements where status='active'$q$,'compliant without evidence');
insert into er_verifications(requirement_id,result,waiver_reference) select id,'non_compliant',null from employer_requirements where status='active';
select compliance_status from v_er_compliance;
select code,value,status from quality_scorecard(:'pid') where code in ('Q01','Q04','Q08');
select pg_temp.expect_fail($q$update inspections set result='accepted'$q$,'noop');
insert into ncrs(project_id,title,description,severity) values (:'pid','Crack','Crack in slab','major');
select pg_temp.expect_fail($q$update ncrs set status='closed'$q$,'close NCR without steps');
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select pg_temp.expect_fail($q$insert into er_verifications(requirement_id,result,waiver_reference) select id,'waived','W1' from employer_requirements where status='active'$q$,'site engineer waiver');
select pg_temp.expect_fail($q$update employer_requirements set status='superseded'$q$,'site engineer edits ER');
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select count(*) as outsider_sees_ers from employer_requirements;
select pg_temp.expect_fail($q$select public.qms_dashboard((select project_id from quality_kpis limit 1))$q$,'outsider dashboard');
